# Porting contract

## Upstream pin

| | |
|---|---|
| Reference | `github.com/prometheus/prometheus` **v3.13.2** |
| Commit | `bb5dff00cf8fdfbf5c65e0531aa835fa238a43a2` |
| Read-only worktree | `../../prometheus/prometheus-v3.13.2` (relative to this repo) |
| Go directive | `go 1.25.0` |
| `prometheus/common` | `v0.69.0` |
| Key deps | `cespare/xxhash/v2 v2.3.0`, `dennwc/varint v1.0.0`, `golang/snappy v1.0.0`, `klauspost/compress v1.18.6`, `oklog/ulid/v2 v2.1.1` |

**Do not port against `main`.** A plain clone of `prometheus/prometheus` tracks `main`,
417 commits past the tag (`git describe` → `v0.313.2-417-g08e3f7d0e`) even though its `VERSION` file
says `3.13.2`. Concretely, `tsdb/chunkenc/st.go` and `tsdb/chunkenc/histogram_st.go` exist on `main`
but **not** at v3.13.2; porting them would add two chunk encodings the target version does not have.

In scope at the pin: `xor2.go`, `head_append_v2.go`, `promql/info.go`, `promql/durations.go`,
`TRIM_UPPER`/`TRIM_LOWER`, fill/anchored/smoothed modifiers.
Out of scope: `st.go`, `histogram_st.go`.

Every ported Swift file carries a header comment naming its Go source path *at the pin*.

## Fidelity: what must be byte/bit-identical

| Surface | Oracle |
|---|---|
| Block `index`, `chunks/NNNNNN`, `tombstones`, `meta.json` | `tsdb/docs/format/*.md` + round-trip vs `promtool` |
| WAL / WBL segments, records, checkpoints | `tsdb/docs/format/wal.md` + round-trip |
| Chunk encodings (XOR, XOR2, histogram, float_histogram) | bit-level spec in `tsdb/docs/format/chunks.md` |
| PromQL float results | Kahan summation order + Go `strconv` shortest-repr |
| PromQL error/warning/info strings, **including `(line:col)`** | asserted verbatim by `promqltest` |
| HTTP API JSON responses | differential test vs a live Go binary |
| Config parse errors | 217 fixtures in `config/testdata/` |

## Documented exceptions

These are deliberate. Do not "fix" them silently; if one changes, update this list.

1. **`labels.Bytes()`** — Go's own doc comment says *"Encoding may change over time or between runs
   of Prometheus."* Explicitly not a compatibility surface.

2. **`labels.Hash()`** — build-tag dependent, so there is no single correct answer. `slicelabels`
   hashes `name 0xFF value 0xFF` framing; `stringlabels` (the default) hashes its packed
   length-prefixed `data` directly. **Different values for the same label set.**
   `HashForLabels`/`HashWithoutLabels` *are* `0xFF`-framed in both.
   We match `stringlabels` — see ADR-1. The only semantically observable consumer is `limit_ratio`
   (`HashRatioSampler.SampleOffset` → `metric.Hash()`, `promql/engine.go`), and `limit.test` is
   written to tolerate hashing luck.

3. **zstd WAL compression** — `klauspost/compress` SpeedFastest output ≠ libzstd level 1 output.
   Zstd is self-describing, so Go decodes ours correctly. We guarantee *semantic* equality only for
   `wal-compression: zstd`. Snappy is Prometheus's default and **is** byte-exact (ADR-5).

4. **`sync.Pool` / `util/zeropool` reuse** — dropped in v1; it is pure allocation optimization.
   ⚠️ But some engine code depends on the copy-vs-alias semantics of *reused* `FloatHistogram`
   pointers (`promql/engine.go`, the `matrixSelectorHPool` comment). Preserve every explicit
   `Copy`/`CopyTo` call site even without the pools.

5. **`Matcher.SetMatches()` ordering** — the *set* is contractual, the *order* is not. Go has two
   backing implementations: `equalMultiStringSliceMatcher` returns source order (duplicates included,
   so `a|a` yields `["a", "a"]`), while above `minEqualMultiStringMatcherMapThreshold` alternates it
   switches to `equalMultiStringMapMatcher`, which iterates a Go map and is therefore **randomized
   per run**. Both the oracle and the port sort before comparing, so fixtures stay reproducible.

   Related genuine behaviour we *do* reproduce: for the **empty** pattern,
   `optimizeAlternatingLiterals` returns a matcher but `nil` setMatches, so `foo=~""` falls back to
   matching rather than an index lookup even though the set would be `[""]`.

6. **`FastRegexMatcher.IsOptimized()` is narrower than Go's.** Go returns true when *any*
   optimisation applied — a set match, a `stringMatcher`, or a prefix/suffix/contains hint. This port
   implements only the set-match path, because the ~600-line `StringMatcher` hierarchy
   (`containsStringMatcher`, `literalPrefix*`, `zeroOrOneCharacter*`, …) exists purely to avoid
   running the regex engine: Go falls back to `m.re.MatchString` whenever those do not apply, so
   always running the engine gives exactly the semantics they preserve, just slower.

   Verified safe: `IsOptimized`/`IsRegexOptimized` is consumed **nowhere** in the Prometheus server —
   only by upstream's own `matcher_test.go`. `SetMatches`, which *is* load-bearing (TSDB turns a regex
   matcher into direct index lookups with it), matches Go exactly and is asserted.

7. **`annotations.Annotations` iteration order.** Go's is a `map[string]error`, so `AsStrings`
   returns warnings and infos in randomised order, and when `maxWarnings`/`maxInfos` truncates,
   *which* annotations survive is random too. There is no order to be byte-exact against.

   This port keeps first-insertion order, so its output is reproducible. A Swift `Dictionary` would
   have been no better than Go's map, since Swift seeds its hasher per process — the ordering is
   explicit for that reason, not by accident.

   Deduplication *is* contractual and is reproduced exactly, including the part that is easy to guess
   backwards: the key is the annotation's message with **no query set**, so two annotations differing
   only in position collapse into one, and the **last** one wins — `Add` calls
   `incoming.Merge(stored)` and `annoErr.Merge` returns its receiver (`annotations.go:49`).

   Consequence for the fixtures: `promql/annotations-set` sorts before comparing, and for the
   truncating cases it records only the counts and the "N more … omitted" line, never the surviving
   subset. Emitting the subset would have made the *fixture itself* nondeterministic and
   `verify-fixtures.sh` flaky.

8. **`annotations.HistogramOperation`'s "unknown operation" default is unreachable.** Go declares it
   as a named `string` type, so a value outside `{addition, subtraction, aggregation}` renders
   "unknown operation". The Swift port is an enum, whose raw-value initialiser simply fails instead —
   a narrowing that is safe at the call sites (the engine only ever passes the three constants) but
   genuinely cannot produce Go's string. Four cases in `promql/annotations` are skipped for this, and
   the count is asserted so the corpus cannot drift without saying so.


## Replicated Go quirks

The inverse of the list above: places where Go does something that reads like a bug, and the port
does it too. Each is pinned by a fixture, so "cleaning it up" fails the build rather than silently
changing behaviour.

0. **Go fuses multiply-adds, and so must we.** This is the one to internalise, because it will recur
   in every phase that does float arithmetic. Go's arm64 backend contracts `a + b*c` into a single
   `FMADDD`, which rounds *once* instead of twice. Where that happens, an unfused Swift `a + b*c`
   gives a different answer, and not always by an ULP:

   - `math.Log2`'s final `log(frac)*(1/Ln2) + float64(exp)` fuses. For `x` just above a power of two
     the product lands just under `-exp`, so the addition cancels ~8 significant digits and the
     unfused form comes out **61 ULP** wrong. Unfused, 33 of 2,350 `gocompat/log2` cases fail.
   - All nine `updatedSum += bucketMidpoint * count` statements in `TrimBuckets` fuse. Unfused, 574 of
     9,048 `histogram/float-trim` cases fail.

   Use `Double.addingProduct(_:_:)`, which is guaranteed fused. Confirm with
   `go tool objdump -s '<symbol>'` and grep for `FMADDD`/`FMSUBD`/`FNMSUBD` rather than guessing —
   the helper functions around `TrimBuckets` do *not* fuse, so it is not a blanket rule.

   Caveat worth knowing: `math.Log` has an assembly implementation on amd64 and a pure-Go one on
   arm64, so Go's own answers can differ between architectures. Our fixtures are generated on arm64
   and CI runs arm64, so the contract is well defined today; if that ever changes, this is the first
   thing to re-check.

1. **`Histogram.ReduceResolution` clears the side it was reducing when it fails.** `histogram.go:642`
   assigns `reduceResolution`'s result to the fields *before* testing the error, and the failing call
   returns `nil, nil`. So a rejected histogram is left with that side emptied — and if the positive
   side succeeded and the negative side then failed, it is left half-converted with the original
   schema. Observable, therefore replicated.

2. **The two spans/buckets mismatch messages are not interchangeable.** `reduceResolution` reports
   `have %d buckets but spans need more` when it runs out mid-span (`generic.go:817`), but
   `spans need %d buckets, have %d buckets` when the count is wrong after the loop
   (`generic.go:883`). Same sentinel error, different prefix, different numbers.

3. **A negative running bucket count converts to a huge `uint64`.** `generic.go:202` does `BC(currCount)`,
   Go's numeric conversion, so an invalid histogram's negative delta comes out of the iterator as
   `UInt64.max`-ish rather than clamped to 0. Clamping would hide the invalid histogram instead of
   surfacing it.

4. **`Histogram.customValues` is `[Double]?`, not `[Double]`.** Everywhere else nil and empty are
   interchangeable — `slices.Equal` and `len` cannot tell them apart, so spans and bucket slices are
   plain arrays. But `histogram.go:456` tests `CustomValues != nil` to reject custom bounds on an
   exponential schema, so an *empty non-nil* slice is an error there and nil is not. Collapsing the
   two would be a silent divergence. Same for `FloatHistogram` (`float_histogram.go:966`).

5. **`detectReset` only inspects the first previous bucket once the current one runs out.**
   `float_histogram.go:817` and `:836` both say they check whether *any* remaining bucket in the
   previous histogram is populated, but neither loop reassigns `prevBucket` — so a populated bucket
   sitting behind an empty one is never seen and no reset is reported. Verified against Go
   (`{0, 5}` vs no buckets is `false`; `{5, 0}` vs no buckets is `true`).

6. **`FloatHistogram.CopyToSchema` drops the counter reset hint** on any real reduction, because Go
   builds the result from a struct literal that omits it. Only the `targetSchema == h.Schema` fast
   path, which delegates to `Copy`, keeps it. It drops `CustomValues` the same way.

7. **`FloatHistogram.Equals` uses two comparison modes.** `Count`, `Sum`, `ZeroCount` and the bucket
   values are compared by bit pattern, but `ZeroThreshold` with `!=` — so a NaN threshold never
   equals itself while a NaN count does, and `-0` vs `+0` goes the other way round.

8. **`Div` by zero returns before the negative-scalar check**, so dividing by `-0` clears the buckets
   without setting the gauge hint.

9. **`AllBucketIterator`'s zero-threshold clamp is unconditional**, so a bucket lying entirely inside
   the threshold is reported as an inverted interval — `(0.5,0.25]`.

10. **`FloatHistogram.Validate`'s negative-count message has two spaces**: `observation count is  %v`.

11. **`reconcileZeroBuckets` loops on `!=` over the two zero thresholds**, so a NaN threshold on
    either side spins forever. Nothing upstream can produce one, and the fixture corpora deliberately
    do not either.

12. **`FloatHistogram.testExpression()` emits descriptions its own lexer cannot read.** A `+Inf`
    value renders with a leading `+`, and `lexHistogramDescriptor` rejects that: Go fails
    `metric {{sum:+Inf}}` with `histogram description incomplete unexpected: '+'`. A non-finite value
    inside a bracketed set fails too, with `bad number syntax: ""`. Verified against Go, which
    produces those messages at the same positions this port does — so `testExpression()` is only a
    fixed point of the series-description parser for the finite cases, and the round-trip test in
    `ParserInvariantTests` skips the rest rather than pretending otherwise.

13. **`histogramQuantileForcedMonotonicityErr.Merge` mutates the *other* error and returns it.**
    `annotations.go:351` does `o := &histogramQuantileForcedMonotonicityErr{}` and then
    `errors.As(other, &o)`, whose target is a `**T` — so `o` is *overwritten* with `other` rather than
    being a fresh accumulator. The widening that follows therefore mutates the already-stored
    annotation, and `o.count += e.count + 1` counts against whichever object survives. Replicated,
    because the sample count in the message depends on it.

14. **`time.Time.UnixMilli` truncation vs. the second boundary.** The monotonicity annotation formats
    `time.Unix(e.minTs/1000, 0)`, and `minTs/1000` is Go integer division — truncating toward zero,
    not flooring. So -1001 ms is second -1, rendering `1969-12-31T23:59:59Z`, and *not* second -2.
    Pinned by `Fixtures/gocompat/time-rfc3339.jsonl`; a `floorDiv` here would be wrong by a second
    for every pre-epoch timestamp.


## Not ported

- The React UI (`web/ui/mantine-ui`, ~25k lines TS) — ship the prebuilt bundle, do the five
  `index.html` placeholder substitutions.
- 26 of 29 service-discovery providers (~21.4k lines) — each needs a cloud SDK with no Swift
  equivalent. Keeping: `static`, `file`, `http`, `dns`.
- OpenAPI spec machinery (`web/api/v1/openapi*.go`, 4,067 lines).
- `util/fuzzing` and Go test infra (3,869 lines).
- `util/{zeropool,pool,runutil,runtime,osutil,netconnlimit,treecache,documentcli}` — Go-runtime
  gap-fillers Swift does not need.
