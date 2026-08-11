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

## ADR-10a — ADR-10 applies to EQUALITY and HASHING, not just ordering

ADR-10 records that Go compares strings by byte and Swift by Unicode collation, and it is usually cited
when sorting. **The same divergence applies to `==` and to `Hashable`,** which is easier to miss and
quieter when wrong:

```swift
"e\u{301}" == "é"   // true in Swift; the same two byte strings are NOT equal in Go
```

So a `Set<String>` de-duplicates canonically-equivalent spellings and a `[String: T]` merges them into one
key. `index.Writer`'s `symbolCache` was `[String: UInt32]`, mapping each symbol to the ordinal a series
record stores — and with both spellings of `é` in the symbol table, one silently took the other's ordinal.
The file stayed structurally valid, its CRCs passed, and it decoded to the **wrong labels**.

**Decision.** Anywhere the port keys, de-duplicates or compares strings that originate as Go bytes, use
`[UInt8]` as the key or comparand. `symbolCache` is `[[UInt8]: UInt32]`; the test harness that rebuilds a
symbol list de-duplicates on `Array(s.utf8)`.

This was found by a differential corpus and would not have been found by review: the failing case had two
visually identical symbols, and every rendering of the input — including the fixture's own JSON, and
`print`ing it — showed them as the same character. What showed the difference was Go writing **seven**
symbols where the port wrote six.

## ADR-11 — The PromQL AST is final classes behind a protocol, not an `indirect enum`

`ast.go` uses interfaces plus pointer structs, and the **engine mutates nodes in place**.
`VectorSelector.Timestamp`, `.Offset`, `.UnexpandedSeriesSet` and `.Series` are all filled in at
query-preparation time, and `preprocessExpr` rewrites the tree. `checkAST` also mutates during
parsing: it rewrites `VectorMatching.Card` and sets `BinaryExpr.VectorMatching` to nil.

An `indirect enum` is the more idiomatic Swift and buys exhaustive switches. It also makes every one
of those mutations a tree rebuild, and turns `preprocessExpr` from a field assignment into a
recursive reconstruction of every path to every selector.

**Decision.** `Node` and `Expr` are `AnyObject`-constrained protocols; each node is a `final class`.
Reference semantics keep the engine's mutation cheap and keep Go's shape, at the cost of dispatch
being `as?` chains rather than an exhaustive `switch`. `VectorMatching` stays a struct, because
optional chaining onto a class's `var` property gives both the in-place mutation and the `= nil`.

Consequences worth knowing:

- `Expressions` (Go's `[]Expr` with methods) cannot be a class-bound `Node`, so it is a `[any Expr]`
  plus free functions in an `Expressions` namespace. Nothing is lost: `ChildrenIter` yields a
  `Call`'s arguments individually, so no `Expressions` node ever reaches `Tree()`.
- `EvalStmt`, `TestStmt` and `VectorSelector`'s two `storage` fields are deliberately absent. They
  need `time.Time` and the storage protocols, which arrive with the engine in Phase 5.

**Phase 5 update — resolved.** All three landed as written: `VectorSelector.unexpandedSeriesSet` and
`.series` are plain `var`s assigned in place, and `EvalStmt`/`TestStmt` are in
`PromQLParser/Statements.swift` on `GoTime` (ADR-14) and `GoContext` (ADR-13). Phase 5 also forced a
module split this ADR did not anticipate: `posrange` had to become its own target, because Go's
dependency chain is

```
promql/parser -> storage -> util/annotations -> promql/parser/posrange
```

Upstream keeps `posrange` a separate package precisely to break that cycle; folding it into
`PromQLParser` — which Phase 4 did — makes the Swift module graph circular the moment `storage`
exists. `TestStmt` also had to become a class wrapping a closure, since Go declares it as a named
function type with methods and Swift cannot attach protocol conformance to a function type.


## ADR-12 — goyacc is replaced by recursive descent, and LALR behaviour is reproduced deliberately

`generated_parser.y` is 1,409 lines compiled to a 2,553-line LALR automaton. Shipping a Swift yacc,
or a table generator, would be a second project.

**Decision.** Hand-written recursive descent with precedence climbing, one function per nonterminal
named after it, so the `.y` file reads side by side with `Parser.swift`.

The catch is that four LALR behaviours are **observable**, and a naive recursive-descent parser gets
all four wrong. Each was found by the `promql/parse` fixture, not by reading the grammar:

1. **Which `error` production reports.** There are 24, each with its own `(context, expected)` pair,
   plus a catch-all `start: error`. goyacc pops the stack to the *innermost* state that can shift
   `error`, so `errorContexts` is a stack of enclosing productions and a failure with no production of
   its own reports against the innermost one.
2. **Conflict resolution decides the language.** `offset_duration_expr` and `duration_expr` both
   derive `number_duration_literal`; goyacc takes the rule declared earlier, which is why
   `foo offset 1m+1m` means `(foo offset 1m) + 1m` and `foo offset -2^2` means `(foo offset -2)^2`.
   Inside `[...]` there is no competition and the full arithmetic grammar applies. Likewise a token
   is reduced to `aggregate_op` only when the lookahead is in its follow set, which is what keeps
   `foo * sum` a product of two selectors.
3. **`lastClosing` is not what Go's source suggests.** Go updates it in `Lex`, when a closing token is
   produced. But goyacc resolves conflicts at table-generation time, so almost every state has a
   single default action and reduces *without* reading a lookahead — making the value in practice the
   last **consumed** closing token. This port updates it on consume, and keeps
   `findPrevRightParen` for `aggregate_op function_call_body`, the one state where the grammar does
   force a lookahead past `)` (upstream issue 16053).
4. **Recovery continues.** An `error` production whose rule still reduces to something usable lets the
   parse carry on, and yacc's `Errflag` suppresses a second message until three tokens have been
   shifted. `errFlag` and `recoverableError` reproduce that, which is what makes `{a=b}` report once
   and `{"a"xx} 0+50x2` report three times in Go's order.

A recursive-descent parser also needs one token of extra lookahead where an LALR parser uses its
own: `peekType()` separates a function call from a metric identifier, and an aggregation from a
metric identifier.

## ADR-13 — `context.Context` is a hand-rolled `GoContext`, not `Task` cancellation

Every `storage` and `promql` entry point takes a `context.Context`. The engine uses it for exactly
three things: `ctx.Err()` polled at every evaluation step (`contextDone`), a query timeout
(`context.WithTimeout`), and one `WithValue` for the query logger's `QueryOrigin` (Phase 9).

**Decision.** `GoCompat.GoContext` — a class holding a cancellation cause, an optional absolute
deadline, and a child list. `WithValue` is not ported.

**Why not Swift structured concurrency.** ADR-3 makes the evaluator synchronous and non-`Sendable`
because Go uses no goroutines in eval. Synchronous code does not run inside a `Task`, so
`Task.isCancelled` is unavailable — and adding an `async` boundary to the hottest loop to get it
would cost exactly what ADR-3 set out to avoid. But the *cancel signal* arrives from another thread
(an HTTP handler abandoning a request), so the flag itself has to be thread-safe: `Mutex` from
`Synchronization`, one per context.

**No timer.** Go's `WithTimeout` arms a `time.Timer` that flips the context asynchronously.
`GoContext.err(now:)` compares the deadline against the clock when asked instead. This is
behaviourally equivalent for Prometheus because the evaluator *polls* — `contextDone` runs at every
step — and it avoids putting a thread or a `Task` behind every query. `now` is a parameter rather
than an internal clock read so a single evaluation step can be consistent about "now" and so the
deadline logic is testable without sleeping.

Consequences worth knowing:

- First cause wins, as in Go: a context cancelled before its deadline stays `.canceled` forever
  rather than becoming `.deadlineExceeded` when the clock passes it.
- The deadline instant itself counts as expired (`!now.before(deadline)`), matching a Go timer that
  fires *at* the deadline.
- A child of an already-cancelled parent starts cancelled and is never registered, which is what
  Go's `propagateCancel` does.

## ADR-14 — `time.Time` is an instant, not a calendar

`EvalStmt.Start`/`.End` are `time.Time`, and one annotation message formats a timestamp as RFC 3339.
Porting `time.Time` in full would mean locations, monotonic readings, and the `Format`/`Parse` layout
machinery — a large compatibility surface.

**Decision.** `GoCompat.GoTime` carries `unixSeconds: Int64` plus a normalised
`nanosecond: Int32`, and implements only the arithmetic Prometheus does plus RFC 3339 in UTC. Grow
it when a port needs more, not pre-emptively.

Two details are load-bearing rather than cosmetic:

- **Seconds plus nanoseconds, not a nanosecond count.** A single `Int64` of nanoseconds overflows at
  ±292 years, and `time.Unix(math.MaxInt64/1000, 0)` — reachable by dividing an `Int64` millisecond
  timestamp by 1000, which is exactly what the monotonicity annotation does — is 292 million years
  out.
- **The zero value is year 1, not the epoch.** Go's zero `time.Time` is 0001-01-01T00:00:00Z and
  `IsZero` is defined against it, so the memberwise default had to be suppressed. A struct whose
  zero value sat at 1970 would make `isZero` quietly wrong.

The date conversion is Howard Hinnant's `civil_from_days`, which agrees with Go's `absDate` over the
whole `Int64` range including year 0 — Go uses astronomical year numbering, so year 0 exists and is
1 BC. `Fixtures/gocompat/time-rfc3339.jsonl` pins it. **This caught a real bug immediately**: the
first attempt split the `(doe - doe/1460 + doe/36524 - doe/146096) / 365` division across the terms
instead of dividing the whole numerator, and every one of the 136 failing annotation cases reported
`1881-1051-12` where Go said `1970-01-01`.


## ADR-15 — The TSDB's filesystem is a protocol, and the port defers `mmap` rather than emulating it

Phase 6's chunk-file slice (HANDOFF §6e) stopped at the format's pure half because everything past it
touches a disk: `chunks.Writer` holds an `*os.File` for the directory *and* one per segment,
`fileutil.BufWriter` wraps the tail, `cutSegmentFile` pre-allocates with `fallocate`/`ftruncate` and
`Sync`s the directory handle, and `NewDirReader` **mmaps** every segment so a `ByteSlice` can be handed
out without copying. Phase 7's Head does the same for the WAL and the on-disk head chunks, so whatever
this port decides here it decides for the rest of the TSDB.

Three candidates were considered.

**`FileManager`/`Data` directly.** Shortest path, and wrong for the same reason `MemStorage` exists: it
would make every TSDB slice untestable without a real directory. The corpora in this project run to
hundreds of thousands of cases and `swift test` is hermetic by contract (CLAUDE.md) — a fixture that
needs a scratch directory is a fixture that fails differently on CI.

**NIO non-blocking file I/O.** The wrong shape for this workload and a dependency the package does not
otherwise need. Prometheus' TSDB writes are sequential and blocking by design; the concurrency that
matters is "an appender writes while a querier reads the same chunk", which is a *memory* ordering
question (quirk 120) rather than an I/O one.

**Decision: a narrow protocol, `PromFS`, with an in-memory implementation for tests and a
`FileManager`-backed one for real use.** Modelled on the seam `Queryable` already provides: the port
depends on the protocol, the corpora drive the in-memory implementation, and the real one is pinned
separately and thinly.

The protocol is deliberately smaller than `os`:

```
directory create/open/sync, list
file      create, open-for-read, append, sync, close, size, truncate
region    read(offset, length) -> [UInt8]
```

Three things it does **not** get, each for a reason:

- **No `mmap`.** `ByteSlice` is already an abstraction upstream (`realByteSlice` wraps a plain
  `[]byte`), so the port implements `ByteSlice` over a fully-read file and over an in-memory buffer. That
  is a real behavioural difference — upstream can read a 512 MiB index without resident memory and the
  port cannot — and it is recorded as a **documented exception**, not hidden. Revisit it when a
  benchmark, not a hunch, says to.
- **No pre-allocation.** `cutSegmentFile`'s `allocSize` affects fragmentation and nothing observable;
  `Fixtures/chunks/batch.jsonl` pins the segment *boundaries*, which is the part that shows.
- **No directory `Sync`.** Durability across a crash is untestable in this harness and unobservable in
  a corpus. The calls stay as no-ops with a comment, so the call sites match upstream's shape (PORTING.md
  §4) and a later durability slice has somewhere to put the real thing.

**What this buys immediately:** `chunks.Writer` and `NewDirReader` become portable and pinnable, because
the oracle can write real segment files while the port writes to memory and the two byte strings are
compared. That is the same trick §6e already used for the batching arithmetic, generalised — and the same
principle as §5e(c) and §6a: pin the exported behaviour, and pick the seam so the corpus can reach it.
