# Architecture decision record

## ADR-1 — Labels: store `[Label]`, hash like `stringlabels`

**Decision.** `Labels` wraps a sorted `[Label]` (slicelabels-shaped storage), but
`goEncodedBytes()`/`goHash()` reproduce the **stringlabels** packed encoding.

**Context.** Go has three mutually exclusive build-tag implementations of `Labels`:
`labels_stringlabels.go` (default), `labels_slicelabels.go`, `labels_dedupelabels.go`. The default
packs all names/values into one length-prefixed string and leans on `unsafe.String` zero-copy
aliasing plus word-at-a-time `uint64` comparison in `Compare`. Swift offers neither cheaply, and
paying a UTF-8 decode on every `Get` would be worse than the slice representation.

Verified encoding (`labels_stringlabels.go:29-53`): per label, name then value, each preceded by its
length — a single byte for 0…254, otherwise `0xFF` followed by 3 bytes little-endian. Max 16 MB.
Names are in sorted order.

**Why still match stringlabels' hash.** `Hash()` is not canonical across implementations, so it is
*almost* a free choice — its only semantically observable use is `limit_ratio`, and the conformance
suite tolerates hashing luck. But fixtures are compared against a **stock** Go build, and a stock
build is stringlabels. Matching it means the oracle needs no special build tags.

**Consequence.** `goHash()` encodes on demand. If profiling shows this hot (TSDB calls it per
append), cache the hash in the struct — it is derivable and immutable.

## ADR-2 — Errors: `throws` everywhere

The Go evaluator uses panic/recover as control flow (`promql/engine.go`, `(*evaluator).error()` /
`.recover()`), as does the parser (`promql/parser/parse.go`). Convert to `throws`; this mechanically
touches every eval signature.

Error *messages* are part of the contract (the conformance suite asserts them verbatim, including
`(line:col)`), so model them as enums whose `description` reproduces Go's string byte-for-byte —
not as free-form `String`s assembled at the throw site.

## ADR-3 — Concurrency

- **PromQL eval: synchronous, non-`Sendable`, single-threaded.** Go uses no goroutines in eval
  (only the query logger). Do not actor-ify it; that would add hops to the hottest loop for no gain.
- **TSDB: locks, not actors.** Go's `stripeSeries` is lock-striped with explicit cache-line padding.
  Use `Mutex` from `Synchronization` (or `NIOLockedValueBox`) per stripe. An actor per stripe would
  put an await on the append path.
- `TaskGroup` for WAL-replay fan-out (Go shards by `HeadSeriesRef % n`).
- An actor + `AsyncStream` for the chunk-write queue (Go: one background writer + bounded ring).
- ServiceLifecycle's `ServiceGroup` for `cmd/prometheus`'s 11-actor `oklog/run` group (Phase 9).

## ADR-4 — Go float formatting is a first-class compatibility surface

Swift's `Double.description` does **not** match Go's `strconv.FormatFloat(f, 'g', -1, 64)`.
Divergence shows up in PromQL output, `labels.String()`, HTTP JSON, and every error message
containing a number.

**Decision.** Hand-roll `GoFloat` in `GoCompat`. **Never call `Double.description`, string
interpolation of a `Double`, or `String(describing:)` on a float in ported code.** Use
`GoFloat.format(_:_:precision:)`. Add a lint for this.

## ADR-5 — Snappy must be a line-for-line port of `golang/snappy`'s encoder

The snappy block *format* admits many valid encodings for the same input; a conforming encoder is not
enough for byte-exact WAL output. Reproduce `golang/snappy`'s `encodeBlock` exactly: its
`maxTableSize`, its hash function, and its skip heuristic. The **decoder** may follow the spec.

## ADR-6 — Regex needs a real RE2 (Phase 2)

`labels.Matcher` semantics are Go `regexp` = RE2: linear time, no backreferences, fully anchored for
matchers. `NSRegularExpression` is backtracking ICU — divergent on pathological patterns **and** a
denial-of-service surface, since these patterns come straight from user queries.

**Decision.** Phase 1 ships a naive anchored matcher behind a `RegexMatching` protocol. Phase 2
replaces it with `PromRegex` (`regexp/syntax` parser → simplify → `Prog` → bool-only Pike VM +
bitstate), validated against Go's own corpus at `$(go env GOROOT)/src/regexp/testdata/`.

`FastRegexMatcher` (`model/labels/regexp.go`, 1,347 lines) is pure optimization **except**
`SetMatches()`, which TSDB uses for index lookups and which is therefore semantically required.

## ADR-7 — Go generics with union constraints don't translate

`model/histogram/generic.go` uses `BucketCount = float64|uint64` and
`InternalBucketCount = float64|int64`. Swift cannot express union constraints.

**Decision.** Use a protocol carrying the required arithmetic plus `init` from `Int64`, and accept
duplication for the two instantiations. Go already duplicates most of this code between
`histogram.go` and `float_histogram.go`.

## ADR-8 — `ByteSlice` is a concrete struct, not a protocol

Go defines three structurally identical `ByteSlice` interfaces (`tsdb/encoding/encoding.go`,
`tsdb/index/index.go`, `tsdb/chunks/chunks.go`) whose `Range()` is zero-cost. Index and postings
reads are the hottest path in TSDB.

- `any ByteSlice` → a retain/release plus witness-table dispatch per read. Unacceptable.
- `<B: ByteSlice>` → specializes, but virally infects ~40 types.
- **A concrete struct over `UnsafeRawPointer`** → matches Go's cost exactly. Chosen.

`RawSpan` is the *correct* answer, but non-escapable types cannot yet be stored as properties, and
`Decbuf` is retained by `index.Reader`. So: `ByteSlice` for storage, `.span` for hot inner loops.
Revisit when `~Escapable` stored properties land.

`@unchecked Sendable` is required and is justified structurally: every `ByteSlice` is derived from a
`ByteSliceOwner` (a mapped file, a retained `[UInt8]`, a `ByteBuffer`) that readers store, so the
memory outlives every derived slice.

## ADR-9 — Go `string` is arbitrary bytes; Swift `String` is not (open risk)

A Go `string` is an immutable byte sequence with **no UTF-8 validity requirement**. A Swift `String`
is always valid UTF-8. Prometheus relies on the difference in at least one observable place:
`strconv.Quote` has defined behaviour for invalid UTF-8 (emit `\xNN` per offending byte), and
`Labels.String()` quotes every label value.

**Decision for Phase 1.** GoCompat's primitives are **byte-level** (`GoStrconv.quote(bytes:)`), so
they reproduce Go for any input. `Labels` stays `String`-backed, because real label data is valid
UTF-8 and a byte-backed `Labels` would make every accessor and comparison more expensive.

**This bit during Phase 1, exactly as predicted — twice.**

1. *Fixtures cannot carry label bytes as JSON strings.* Go's `encoding/json` silently rewrites
   invalid UTF-8 to U+FFFD, so a corpus with random-byte label values produced fixtures whose
   **input** was already corrupted; 45% of label cases mismatched for a reason that had nothing to do
   with the Swift code. Label names and values now travel as **hex** in every fixture, and
   `oracle/suites_prom.go`'s `toLabelsIn` panics if a corpus label is not valid UTF-8 — so this
   cannot silently regress into a mysterious hash mismatch.
2. *The label corpus is deliberately restricted to valid UTF-8.* Invalid bytes are still covered at
   the byte level by the `gocompat/quote`, `hash/xxhash64` and `hash/crc32c` suites, which take hex
   input and never build a `String`.

**Open risk, to resolve in Phase 8 (`PromTextParse`).** That is the first point where arbitrary bytes
could actually enter the system from a scraped target. When porting it, decide whether `Labels` must
become byte-backed (`ContiguousArray<UInt8>` + offsets) or whether ingest validates and rejects
first. Do not let this decision be made implicitly by whichever code is written first.

## ADR-10 — Go compares strings by byte; Swift compares by Unicode collation

`labels.Compare` drives `sort.Sort(Matrix)` on every PromQL result, and `assertMatrixSorted` in the
conformance runner checks the ordering — so string ordering is observable.

Go's `strings.Compare` and `<` are **byte-wise**. Swift's `String: Comparable` uses Unicode canonical
ordering, which differs (canonically equivalent sequences compare equal; ordering is not byte order).

**Decision.** Never use `<` on `String` in ported comparison code. `PromLabels` provides
`String.utf8Lexicographic`, a wrapper whose `<` compares UTF-8 bytes. `Labels.compare`, `Label.<` and
the `HashForLabels`/`HashWithoutLabels` name-merge loops all go through it.

Note also that only the **sign** of `labels.Compare` is contractual: stringlabels returns a byte
length delta for the prefix case, slicelabels a label count delta. Every caller is a sort comparator.
