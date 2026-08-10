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

9. **Three latent `sampleRing` bugs are guarded rather than reproduced.** Each is unreachable from an
   upstream production caller, and none can be differentially tested — Go's behaviour is a crash or a
   silent corruption, so generating a fixture for it would take the oracle process down. Each is
   pinned by a Swift-side invariant test instead.

   - `nthLast(n)`/`PeekBack(n)` (`buffer.go:787`) tests `n > r.l`, which lets `n == 0` through; it
     then reads index `l`, one slot *past* the newest, and reports success. On an empty reset ring
     `bufInUse` is `noBuf`, so it routes to `at(0)` and divides by zero. Guarded with
     `precondition(n >= 1)`. Only `PeekBack(1)` is reachable upstream (`web/federate.go:126`).
   - `sampleRing.add` (`buffer.go:470`) type-switches on the three concrete sample types with no
     `default`, then returns unconditionally — so a `chunks.Sample` from another package is **silently
     dropped**, on the first add only. Later adds fall through to the migration path and are handled.
     Guarded with a trap naming the type. Unreachable through `BufferedSeriesIterator`, which re-wraps
     whatever the wrapped iterator yields into its own `fSample`/`hSample`/`fhSample` before adding.
   - `reduceDelta` (`buffer.go:754`) rejects a delta larger than the current one but not a negative
     one, which makes `tmin > newestT` and breaks the eviction loop's termination proof — it walks
     past the newest into stale slots and can drive `l` negative. Guarded with
     `precondition(delta >= 0)`. The engine only ever passes a step range (`engine.go:2372`).

   Also guarded, but *not* a divergence: `listSeriesIterator`'s `At`/`AtT`/`AtST`/`AtHistogram` index
   `samples[-1]` before the first `Next()` (`series.go:122`). That traps in Swift either way; the
   precondition only supplies a message.

10. **`MemoizedSeriesIterator.PeekPrev` returns an Optional, not Go's sentinel.** Go signals "nothing
    memoized" with `prevTime == math.MinInt64` (`memoized_iterator.go:68`), which would make a genuine
    sample at `Int64.min` invisible. No observable difference for any reachable input, and the
    Optional has no blind spot.

11. **`MemQuerier.select(sortSeries: false)` returns insertion order, and upstream has no order to
    match.** With every sample in the Head and no persisted block, `tsdb.DB.Querier` yields a single
    querier, so `NewMergeQuerier`'s "we need to sort for merge to work" (`merge.go:302`) never fires
    and postings come back in series-ref order — which is append order. And `promqltest` appends by
    ranging a **Go map**:

    ```go
    func (cmd *loadCmd) append(a storage.AppenderV2) error {
        for h, smpls := range cmd.defs {          // test.go:918
    ```

    So upstream's own unsorted order is randomised per run, and any `.test` assertion depending on it
    would already be flaky in upstream's CI. This port returns insertion order because it is
    reproducible; `sortSeries: true` delivers label order either way, and that half *is* pinned
    (`storage/mem-select` selects sorted in every case). The choice is asserted Swift-side so it
    cannot drift silently.

    Consequence to remember when the evaluator lands: an inner expression's series order becomes
    `aggregation`'s Kahan summation order, so upstream is nondeterministic there too. Drive
    `aggregation` fixtures with an explicitly ordered input matrix, never through `rangeEval`.

12. **Series visibility is modelled as one chunk per series, which makes the port a superset by empty
    series.** Upstream decides whether a series appears in a `SeriesSet` at **chunk** granularity —
    `blockBaseSeriesSet.Next` skips a series only when no chunk overlaps the querier's range
    (`querier.go:503`) — and this port has no chunks until Phases 6-7, so it tests the span from a
    series' first sample to its last.

    The *samples* returned are identical whenever the hints' range is contained in the querier's,
    which it always is for this engine (`execEvalStmt` derives the querier's bounds from
    `FindMinMaxTime` over the same selectors the hints come from, `engine.go:788`). The difference is
    only this: upstream's chunks tile a series' span with gaps between them, so a query landing
    entirely inside a gap matches no chunk and drops the series, whereas one big chunk still overlaps
    and the series is returned with an **empty** sample list. The evaluator builds output from points,
    so a series with no points contributes nothing and the difference is unobservable through PromQL.

    Not to be confused with the genuine behaviour in quirk 34, which this port *does* reproduce.


13. **`funcHistogramQuantile` and its siblings range a Go map, so their
    classic-histogram output order is upstream's coin flip.**
    `for _, mb := range enh.signatureToMetricWithBuckets` iterates a
    `map[string]*metricWithBuckets`, so the order of classic-histogram results is
    randomised per run in Go — the same situation as `Annotations` (exception 7).

    The port keeps **first-insertion order** so its own output is reproducible, and
    `Fixtures/promql/functions-histogram.jsonl` sorts the samples (and the
    annotations, for the same reason) before comparing.

    What *is* deterministic and *is* pinned Swift-side: native-histogram results
    always come before classic ones, because the natives are a slice, and the order
    within the natives is the input vector's. The evaluator sorts the final result
    anyway, so none of this is observable from a query.

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

   - **`math.Exp2` is itself assembly on arm64, and fused.** `haveArchExp2` is true for
     `arm64 || loong64` (`math/exp2_asm.go`), and `exp_arm64.s`'s `archExp2` evaluates its
     polynomial with `FMADDD`/`FMSUBD`/`FNMULD` where the portable `exp2`/`expmulti` pair does not.
     Swift's libm `exp2` therefore disagrees with Go's on 19 of 93 probe values, always by one ULP —
     including `2**0.5`, where **libm is the more accurate of the two** and Go is one ULP low.
     `GoMath.exp2` ports the assembly's algorithm; `Fixtures/gocompat/exp2.jsonl` pins it over 1,333
     cases. Every `histogram_quantile` over exponential buckets goes through it.
   - **`promql/quantile.go` fuses six operations, and which ones is not guessable.**
     `BucketQuantile` fuses the final interpolation *and* recomputes `rank` as a single
     `q*observations - previousCount` (quantile.go:165 is one `FNMSUBD`, so the binary search above
     still sees the unfused product). `HistogramQuantile` fuses its linear interpolation and both
     exponential ones. `HistogramFraction` fuses only `interpolateExponentially`'s tail — its
     `interpolateLinearly` sibling is not fused, because a divide sits between the multiply and the
     add. **`BucketFraction` fuses nothing at all.** Unfusing all six breaks 23 committed cases.
     Determined per function with `go tool objdump`, not by reading the source.
   - **`math.Exp` is the same story as `Exp2`, and `math.Log` is a third instance** — see quirks 30
     and the `Exp` note below. `Exp`'s sibling routine in the same `exp_arm64.s` shares the
     polynomial and the inlined `Ldexp`; `Log` is pure Go on arm64 but its *compiled* form fuses
     seven expressions, two of them structurally (a temporary that never exists as a rounded value).
     `Fixtures/gocompat/exp.jsonl` (5,571 cases) and `gocompat/log.jsonl` (13,335) pin them.
   - **Not every fusion is observable, and it is worth knowing which.** Unfusing one expression at a
     time and diffing against Go over tens of millions of inputs separates three groups: *provably
     unobservable* (`k*Ln2Hi` in both `Log` and `Exp` — `Ln2Hi` carries 32 significant bits and
     |k| ≤ 1075, so the product is exact; that is the entire purpose of the hi/lo argument-reduction
     split), *unobservable in search* (polynomial terms whose difference is diluted below the final
     rounding), and *rare but real* (`Log`'s `R` at ~3 per million and `inner` at ~12 per million).
     For the last group a randomly generated corpus will miss the case by chance, so `gocompat/log`
     commits **harvested witnesses**. Prefer measuring this to asserting it: the claim "this is
     fused" is only tested if some committed case fails when it is not.

   Caveat worth knowing: `math.Log` has an assembly implementation on amd64 and a pure-Go one on
   arm64, so Go's own answers can differ between architectures. `math.Exp2` is the mirror image —
   assembly on arm64, portable elsewhere. Our fixtures are generated on arm64 and CI runs arm64, so
   the contract is well defined today; if that ever changes, this is the first thing to re-check.

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

15. **The look-back ring's window is closed at both ends.** `sampleRing` evicts with
    `tmin := newest.T() - r.delta` and a **strict** `<` (`buffer.go:608`), so a sample landing exactly
    on `newest - delta` is retained. Pinned directly by `Fixtures/storage/buffer.jsonl`'s
    `evict/boundary-kept` and `evict/boundary-dropped`, and stated again as an invariant test because
    a fixture diff would not say *why* the boundary moved. Relaxing the comparison to `<=` does not
    merely shift the window by one sample — it makes the loop non-terminating, since the newest sample
    is what stops the walk.

16. **The element the buffered iterator is positioned on is never in its buffer.**
    `BufferedSeriesIterator.Next()` pushes the *current* element into the ring and only then advances
    (`buffer.go:116`). `engine.go:2977` depends on it: "Values in the buffer are guaranteed to be
    smaller than maxt."

17. **Both look-back wrappers are already positioned after construction.** `Reset` ends with
    `valueType = it.Next()` (`buffer.go:64`, `memoized_iterator.go:62`), so `At()`/`AtT()` report the
    *first* sample before the caller advances, while `lastTime` is still `math.MinInt64`. The state is
    internally inconsistent, and the consequence is that the first `Seek` almost always takes the
    hard-seek branch and discards the fact that the iterator was already positioned. Replicated
    exactly; the engine's lookback depends on it.

    Corollary the corpus had to learn the hard way: because `At*` are raw pass-throughs onto the
    wrapped iterator, they are only legal *while it is positioned*. Reading one after the `Next` that
    exhausts indexes past the end of the sample list and Go panics.

18. **`sampleRing` has two deltas and only one of them can shrink.** `BufferedSeriesIterator.delta`
    is the construction value and is immutable; `ReduceDelta` moves the ring's copy, `Seek` reads the
    ring's (`buffer.go:86`), and `Reset` restores it from the original (`:63`). `ReduceDelta` returns
    false and does nothing when asked to *raise* it. `MemoizedSeriesIterator` by contrast has a single
    immutable delta.

19. **`MemoizedSeriesIterator.Seek` discards the memo before it knows the seek will succeed.**
    `memoized_iterator.go:81` clears `prevTime`, and only `:83` attempts the seek — so a seek that
    returns `ValNone` has destroyed the previous element with nothing to show for it, permanently.
    `BufferedSeriesIterator.Seek` does the same to its ring (`buffer.go:91` before `:93`).

20. **`MemoizedSeriesIterator` folds integer histograms only on the way out.** `Seek`/`Next` convert
    `ValHistogram` to `ValFloatHistogram` (`:88`, `:124`), but `At()`/`AtT()` are raw pass-throughs, so
    a caller that inspects those can still observe an integer histogram. Its `delta` is also never
    enforced on the memo (`:104-105` says so) — it only computes the hard-seek target, and the
    staleness check lives in the engine (`engine.go:2729`), which is what makes the lookback window
    half-open, `(refTime - lookbackDelta, refTime]`.

21. **`promql.Vector.TotalSamples` and `HPoint.size` disagree about histogram weight.** `HPoint.size`
    is `(H.Size() + 8) / 16`, counting the timestamp (value.go:180); `Vector.TotalSamples` uses
    `H.Size() / 16` and omits the `+ 8` (value.go:282), while `Matrix.TotalSamples` goes through
    `HPoint.size` and includes it. Both feed sample-count limits, so neither can be reconciled to the
    other. Pinned by `Fixtures/promql/value.jsonl`.

22. **`promql.Series.String()` renders floats then histograms, not merged by timestamp**, and an empty
    series still emits the trailing newline after `=>`. Upstream's own TODO (value.go:78) wonders
    whether primary sorting by timestamp would be better; it is not what the code does.

23. **`storageSeriesIterator.Seek(math.MinInt64)` reports a float it never read.** The loop is
    `for currT < t` and `currT` starts at `math.MinInt64`, so that target never advances; the tail
    then returns `ValFloat` because `currH` is nil. The caller gets `ValFloat` with the sentinel
    timestamp and a zero value. Pinned by `promql/storageseries`'s `seek/negative`.

24. **`promql.Vector`/`Matrix.ContainsSameLabelset` compare label-set hashes, not labels.** A
    collision therefore reports a duplicate that is not one (value.go:296, :349). `Labels.Hash` is
    the stringlabels one per exception 2, and the `len == 2` case short-circuits to a direct hash
    comparison rather than building a set.

25. **Go's `math.NaN()` is not Swift's `Double.nan`.** Go builds its NaN from
    `uvnan = 0x7FF8000000000001` (`math/bits.go`); `Double.nan` has a zero payload. Observable
    bit-for-bit wherever a NaN is returned rather than tested, which in `quantile.go` is six exits.
    `PromModel.PromValue.normalNaN` is Go's constant and every `math.NaN()` return goes through it.

26. **`BucketQuantile`'s monotonicity outputs are Go named returns, so they start at zero.** Only
    `ensureMonotonicAndIgnoreSmallDeltas` sets the inverted `+Inf`/`-Inf` range, at its own start
    (quantile.go:678). So the NaN-`q`, `q < 0`, `q > 1` and no-`+Inf`-bucket exits all report
    `0/0/0`, while an exit *after* the pass reports the inverted range. Initialising the struct to
    the inverted range would be wrong on exactly those four paths.

    Related, and not obvious: a NaN quantile and a reported monotonicity fix are **mutually
    exclusive**. Forcing monotonicity carries the highest accepted count forward through every later
    bucket including the `+Inf` one, so a trailing zero count is rewritten and the
    zero-observations exit is never reached; and the `len < 2` exit means the pass's loop never ran.
    Verified across the whole `promql/bucketquantile` corpus.

27. **`SampleRingIterator` leaves a stale histogram behind in the mixed case.** The homogeneous
    branches cross-nil `h`/`fh`, but the interface buffer's float branch (`buffer.go:403`) sets only
    `f` — so `AtFloatHistogram()` after a float sample in a mixed ring returns the *previous*
    histogram rather than nil. Callers must switch on the returned `ValueType`; the engine does. Not
    reachable from the corpus for that reason, and noted rather than left looking covered.

28. **`math.Min`/`math.Max` are arm64 assembly whose ±Inf check runs *before* NaN handling.**
    `haveArchMax`/`haveArchMin` are true for `amd64 || arm64 || loong64 || riscv64 || s390x`
    (`math/dim_asm.go`). `dim_arm64.s` compares each operand's **raw 64-bit pattern** against `+Inf`
    (for `archMax`) or `-Inf` (for `archMin`) and returns early on a hit — so

    ```
    math.Max(+Inf, NaN) == +Inf      // the portable math.max returns NaN
    math.Min(-Inf, NaN) == -Inf      // likewise
    math.Max(-Inf, NaN) == NaN       // the check is one-sided per function
    ```

    Below that, `FMAXD` is ARM's `FMAX`, which **propagates** a NaN operand — not `FMAXNM`, and not
    libm's `fmax`/`fmin` or `Swift.max`/`Double.maximum`, all of which return the non-NaN operand.
    Two further details are observable and pinned: the Go instruction is `FMAXD F0, F1, F0`, i.e.
    `FMAX(operand1: y, operand2: x)`, so between two differing quiet NaNs **`y`'s payload wins** and
    swapping the arguments swaps the answer; and a signalling NaN outranks a quiet one and comes back
    quietened, which is live rather than theoretical because Prometheus's own stale marker
    (`0x7ff0000000000002`) has a clear quiet bit. Pinned by `gocompat/minmax`.

29. **`math.Pow(-2, 0.5)` and `math.Pow(-2, 0.25)` return NaNs with different payloads.** `pow`'s
    `y == ±0.5` shortcut to `Sqrt` is tested *before* the `yf != 0 && x < 0` guard, so the former is
    `Sqrt(-2)` — the hardware NaN, payload 0 — while the latter reaches the explicit branch and gets
    `math.NaN()`, payload 1. Same for `Pow(x, ±0.5)` generally. Related to quirk 25, and pinned by
    `gocompat/pow`.

30. **`math.Log`'s fusion is not what `gocompat/log2` was testing.** `Log2` only ever calls `Log` on
    a `Frexp` fraction in [0.5, 1), which confines the argument reduction to `k ∈ {0, -1}`. A
    literal, *unfused* transcription of Go's `log` passed all 2,350 `gocompat/log2` cases and was
    still one ULP wrong on `Log(5.2063069815873524)` — found by a `gocompat/pow` case, since `Pow`
    computes `Exp(yf * Log(x))` on the raw `x`. The fix was the seven fusions in Go's arm64 output,
    two of which are structural: `t1 = s2 * (...)` is folded into `R := t1 + t2`, and
    `hfsq = 0.5*f*f` is never materialised — only `0.5*f` is rounded, and the `* f` is fused into
    each of `hfsq`'s two readers.

    The generalisable lesson is **a corpus that reaches a function only through one caller pins only
    that caller's domain.** `gocompat/log` now covers the full domain, and because only three of the
    seven fusions are observable at all (the rest are diluted below the final rounding, and
    `k*Ln2Hi` is *provably* exact — `Ln2Hi` has 32 significant bits and |k| ≤ 1075, which is what the
    hi/lo split is for), it commits **harvested witnesses** for the two rare ones: `R` diverges on
    ~3 inputs per million and `inner` on ~12 per million, so a corpus of this size would otherwise
    miss both by chance. See `GoMath.log`'s doc comment for the per-expression table.

31. **The parser constant-folds literal duration expressions, so the same condition yields two
    different error messages.** `foo[1h % 0]` never reaches `durationVisitor`: the parser folds it and
    reports `1:8: parse error: modulo by zero`, a `ParseErr` with a **`line:col`** prefix. Give it an
    operand it cannot fold — `foo[1h % (1h - 1h)]` — and the visitor reports
    `4:17: modulo by zero`, with a **byte-offset** prefix and no `parse error:` marker. The same
    doubling hides `duration is out of range` behind `parse error: duration out of range` for
    `foo[1e308 * 1e308]`.

    Two consequences. First, `promql/durations.go`'s error strings are *not* `ParseErr`s and must not
    be rendered like them. Second, a corpus of duration-expression failures written the obvious way
    tests the parser, not the visitor: three of the five branches of `calculateDuration` were
    unreachable until the corpus switched to non-foldable operands. Pinned by `promql/preprocess`.

32. **`time.Duration(math.Round(val * 1e9))` saturates, and the printer's negation of the result
    wraps.** Two `Double`→`Int64` conversions in the parser that Go performs with hardware semantics
    and Swift traps on:

    - `foo[9223372036.8547764]` is a **legal query**. The out-of-range check at `parse.go:1208` is
      `val > 1<<63/1e9`, and that constant rounds to the `Double` 9223372036.854776 — so a literal
      equal to it *passes*, and the product `val * 1e9` is then exactly 2⁶³, one above `Int64.max`.
      Go's `int64(float64)` is a bare `FCVTZS` on arm64, which clamps: the answer is
      `foo[106751d23h47m16s854ms]`, i.e. `Int64.max` nanoseconds. NaN maps to 0. Verified against Go.
    - Printing a negative offset writes the sign itself and formats the **negated** magnitude
      (`printer.go:266`). For an offset of `Int64.min`, `-Int64.min` wraps back to `Int64.min` —
      still negative — so `model.Duration.String()` prepends a second sign and Go prints
      `foo offset --106751d23h47m16s854ms`. The double minus is real.

    Both were latent: the 6,154-case `promql/parse` corpus has no duration literal near the `Int64`
    boundary, because upstream's `parse_test.go` has none. `promql/preprocess` added one to pin
    `calculateDuration`'s bound and crashed the parser instead. The general lesson matches quirk 30 —
    **a corpus inherits its blind spots from the test suite it was extracted from.**

33. **`Select`'s two ranges are different ranges, and only one of them is the hints'.** `SelectHints`
    `Start`/`End` **override** the querier's `mint`/`maxt` (`querier.go:205-207`) — they do not narrow
    them — but they override only the *trimming*. Which series are visible at all is decided by the
    index reader, which was opened with the **querier's** range, so a chunk outside it is never seen
    rather than merely trimmed.

    So widening the hints past the querier's range widens the samples returned from an
    already-visible series but cannot make an invisible series appear. `storage/mem-select`'s
    `hints/two-stage` pins it: a querier over `[500,600]` with hints over `[0,1000]` returns exactly
    the one series that spans `[500,600]`, untrimmed, and none of the four that do not.

    Easy to get backwards in either direction, and both were, before the fixture said otherwise.

34. **A series whose samples are all trimmed away is returned *empty*, not dropped.** The skip in
    `blockBaseSeriesSet.Next` is `if len(chks) == 0`, counted over chunks that overlap the range, and
    trimming happens afterwards by adding synthetic tombstone intervals. So querying the instant
    `t=250` between samples at 200 and 300 yields three series with **zero** samples each, where
    querying `t=500` past every sample yields an empty set. `nohints/instant-miss` and
    `nohints/after-all` are the two cases.

    Reproduced, subject to the chunk-granularity caveat in exception 12.

35. **`LabelValues` truncates before sorting; `LabelNames` truncates after.** The `LabelQuerier` doc
    comment says "Results are returned in natural (alphabetical) order regardless", and the final
    results are indeed sorted — but the limit is not applied to the sorted list.

    `MemPostings.LabelValues` slices `p.lvs[name]`, an **append-only** slice in first-seen order, and
    only then does `SortedLabelValues` sort what survived (`postings.go`, under
    `blockBaseQuerier.LabelValues`). So a label first seen as `"1"` and then `"0"`, with `Limit: 1`,
    yields **`["1"]`** and not `["0"]` — `values/limit-unsorted` pins exactly that.
    `blockBaseQuerier.LabelNames` is the other way round: the index sorts first and the querier
    truncates the sorted result, so its limit does keep the alphabetically first names.

    The consequence for Phase 9's HTTP API: *which* values a `limit` keeps depends on ingest order, so
    it is not a stable API result — and for a Head loaded by `promqltest` it is randomised, for the
    same map-iteration reason as exception 11.

36. **Start timestamps survive only through the XOR2 chunk encoding.** `tsdb.Options.EnableSTStorage`
    reads like the switch for it and is not: `db.go:247` says "TODO(bwplotka): Implement this option
    as per PROM-60, currently it's noop". What actually carries a per-sample ST is
    `FloatChunkEncoding = chunkenc.EncXOR2`, which is why `promqltest`'s own `init()` sets **both**
    (`promqltest/test_test.go:33`).

    With the default `EncXOR`, every sample appended with a non-zero `st` reads back with
    `AtST() == 0`. The `storage/mem-select` oracle hit this first-hand — it was written without the
    options and produced a fixture asserting that ST is *lost*, which is the opposite of what the port
    needs. Two consequences worth carrying forward:

    - **Phases 6-7 must implement XOR2, not just XOR**, or `start_timestamps.test` cannot pass; its
      `st_resets` series expects `increase()` results that differ from the ST-less ones (420 vs 300).
    - Any future oracle suite standing up a `tsdb.DB` must set the same two options, or it pins the
      wrong behaviour silently.

37. **A stale marker does not become the counter-reset baseline, so the sample after one is compared
    against the sample *before* it.** `HistogramStatsIterator.AtFloatHistogram` returns early on
    `value.IsStaleNaN(hsi.current.Sum)` (`histogram_stats_iterator.go:124`), and that early return is
    *above* `setLastFromCurrent`. So `hsi.last` is untouched by a stale sample — as is
    `hsi.lastIsCurrent`, which `Next` had already cleared.

    Upstream's own table names this ("detect real counter reset after stale NaN") but only for a single
    stale sample. Two in a row behave the same way, and the baseline survives both:
    `stale/consecutive` walks `n=3, stale, stale, n=1` and gets `CounterReset` on the last, because the
    comparison is still against `n=3`. A float sample in the gap has the same non-effect — nothing on
    the float path touches any of the three state fields.

    Note also that the stale branch passes the sample's own hint through **unchanged**, so an explicit
    `CounterReset` on a stale sample survives rather than being recomputed
    (`stale/with-explicit-hint`).

38. **`HistogramStatsIterator.Seek` reads the *wrapped* iterator's `AtT()`, before seeking it.** The
    guard at `histogram_stats_iterator.go:69` is `if t > hsi.AtT()`, and `AtT` is the promoted embedded
    method — so it reports where the underlying iterator is *now*. Two consequences:

    - A seek that does not move (`t <= AtT()`) leaves `last` and `lastIsCurrent` alone, so the
      following read answers from the memo rather than re-detecting. `>=` instead of `>` breaks
      `seek/no-op-keeps-last`.
    - A `Seek` before the first `Next` panics over any iterator whose `AtT` is not valid until then —
      `listSeriesIterator` reads `samples[-1]`. This is the same family of trap as the look-back
      wrappers' raw pass-throughs (quirks 15–21), and it is why no case in
      `Fixtures/promql/histogram-stats.jsonl` seeks before advancing.

39. **Go's trigonometry is not libm's, and the gap is not a corner case.** `haveArchSin`, `haveArchCos`,
    `haveArchTan`, `haveArchAsin`, `haveArchAcos`, `haveArchAtan` and `haveArchLog10` are true only on
    **s390x** (`math/arith_s390x.go` against `math/stubs.go`), so on arm64 and amd64 Go runs its own
    Cephes-derived code. Measured against Swift's libm over 2,000,052 inputs each:

    | | | | |
    |---|---|---|---|
    | `Atan` 296,632 (15%) | `Sin` 466,199 (23%) | `Cos` 573,768 (29%) | `Tan` 817,377 (41%) |
    | `Acos` 1,258,393 (63%) | `Log10` 1,294,745 (65%) | `Asin` 1,338,076 (67%) | `Round` 81 |

    `Abs`, `Ceil`, `Floor` and `Sqrt` differ on **none** — the same hardware instruction either side —
    so the port keeps Swift's for those. That asymmetry is the point: `Sqrt` agreeing is no evidence
    about `Sin`.

    Two sub-quirks that a port will get wrong by default:

    - **NaN payloads differ, and they are observable.** Go's `math.NaN()` is `0x7FF8000000000001`;
      Swift's `Double.nan` is `0x7FF8000000000000`. Worse, the functions disagree with *each other*:
      `Sin`, `Tan` and `Atan` `return x` for a NaN argument, so the **argument's** payload survives,
      while `Cos` and out-of-domain `Asin` return `NaN()` and replace it.
    - **`1/Ln10` must be hard-coded.** Go folds it in arbitrary precision to `0x3FDBCB7B1526E50E`; the
      naive Swift `1.0 / 2.302585092994046` is `0x3FDBCB7B1526E50D`, one ULP low, which shifts every
      `log10` result. `1/Ln2` happens to be identical either way, so `log2` did not expose this.

40. **Where a Go polynomial's leading term is `z + const` and `z` is itself a product, the compiler
    fuses the product into that add — recomputing it *unrounded*.** Same phenomenon as quirk 29's
    `rank`, but easier to miss, because the rounded value is sitting in a register and every *other*
    term of the same expression uses it.

    Five sites, all in this pin's `math`:

    - `xatan` (atan.go:69) writes `(((((z+Q0)*z+Q1)...` with `z := x*x`, and Go emits `fma(x, x, Q0)`.
      **Observable**: `0xbfe1383384b20da8` distinguishes it both from reusing the rounded `z` and from
      an unfused `x*x + Q0`, and is committed as a witness.
    - `tan` (tan.go:129) writes `(((( zz +_tanQ[1])*zz+...` and Go emits `fma(z, z, _tanQ[1])`. Not
      observable in a 12,000,000-input search.
    - `sinh` (sinh.go:63) writes `(((sq+Q2)*sq+Q1)*sq + Q0` with `sq := x*x`, and Go emits
      `fma(x, x, Q2)`. Not observable in 34,000,052 inputs.
    - `tanh` (tanh.go:102) writes `((s+tanhQ[0])*s+tanhQ[1])*s+tanhQ[2]` with `s := x*x`, and Go emits
      `fma(x, x, tanhQ[0])`. Not observable in 34,000,052 inputs.
    - `log1p` (log1p.go:200, :202) writes `s*(hfsq+R)` with `hfsq := 0.5*f*f`, and Go emits
      `fma(f, 0.5*f, R)`. **Loudly observable** — see quirk 42.

    The port spells all five the way the disassembly does, because being unobservable *by search* is
    not the same as being equivalent.

    **Why three of the five are silent and two are not** is the transferable part, and it took the
    hyperbolics to see it: observability tracks *position in the Horner chain*, not the fusion itself.
    Unfusing each term of a chain one at a time and counting differences over 34,000,052 inputs gives
    a monotone gradient — `sinh`'s numerator 0 → 122 → 25,280, its denominator 0 → 5 → 4,426; `tanh`'s
    0 → 2 → 1,545 and 0 → 122 → 10,513; and the six adds of `log1p`'s seven-term `Lp` chain 0, 0, 0, 0, 8, 315. The leading
    term is always the most diluted, because everything downstream multiplies its error by a value
    below 1 and then adds a constant orders of magnitude larger. `sinh`'s and `tanh`'s unrounded
    recomputations happen to *be* the leading term; `xatan`'s and `log1p`'s are not. So a search that
    finds nothing at a chain's head has said nothing about the fusion — only about where it sits.

    The general lesson for the evaluator work ahead: an FMA count that exceeds the number of `a*b + c`
    patterns in the source means a product has been fused into an add that does not look like one.
    Count the ops before mapping them.

41. **The hyperbolics are portable Go on arm64 too, and every one of them diverges from libm.**
    `haveArchSinh`, `haveArchCosh`, `haveArchTanh`, `haveArchAsinh`, `haveArchAcosh`, `haveArchAtanh`
    and `haveArchLog1p` are all true only on **s390x**, exactly as the trig block (quirk 39) — so
    `promql`'s `sinh`/`cosh`/`tanh`/`asinh`/`acosh`/`atanh` run Go's own Hart & Cheney, Cephes and
    FDLIBM code. Measured against Swift's libm over 1,921,867 inputs each:

    | | | |
    |---|---|---|
    | `Tanh` 103,074 (5.4%) | `Asinh` 166,942 (8.7%) | `Cosh` 260,500 (13.6%) |
    | `Log1p` 346,161 (18.0%) | `Sinh` 472,471 (24.6%) | `Atanh` 968,192 (50.4%) |
    | `Acosh` 1,334,959 (69.5%) | | |

    `Acosh`'s and `Atanh`'s figures are 98% and 93% NaN payload — their out-of-domain branch is shared
    with their NaN branch, so both return Go's `NaN()` and *replace* the argument's payload, where
    `Sinh`, `Tanh` and `Asinh` let it through. Strip that out and 27,509 and 64,610 genuine one-ULP
    disagreements remain.

    `Cosh` is the instructive one: it fuses nothing, and its whole body is
    `x = Abs(x); return (Exp(x) + 1/Exp(x)) * 0.5`. It still differs on one input in seven, entirely
    inherited from `Exp`. **A routine with no arithmetic of its own still cannot be delegated.**

    `math.Log1p` is ported even though PromQL has no `log1p` function, because `Asinh`, `Acosh` and
    `Atanh` are all built on it.

42. **The same Go expression can compile to two different roundings two lines apart, decided by
    register pressure.** `log1p` writes `hfsq := 0.5 * f * f` once and then reads it in two returns:

    - log1p.go:200, `f - (hfsq - s*(hfsq+R))` — the **inner** `hfsq` is `fma(f, 0.5*f, R)`, unrounded
      (quirk 40); the **outer** one is the rounded value from log1p.go:180, still live in `F4`.
    - log1p.go:202, `k*Ln2Hi - ((hfsq - (s*(hfsq+R) + …)) - f)` — **both** are unrounded, because
      `SCVTFD R1, F4` has put `float64(k)` in `F4` and the rounded `hfsq` no longer exists to be read.

    So the port needs `hfsq`, `0.5*f` and two different spellings of "hfsq minus something", and which
    one goes where cannot be derived from the Go text at all. Unfusing the outer one at :202 moves
    188,208 of 20,000,000 results, so it is not a subtlety that stays hidden either.

    The same file has a smaller instance on one line: `asinh`'s
    `Log1p(x + x*x/(1+Sqrt(1+x*x)))` contains `x*x` twice, and the compiler fuses the one under the
    `Sqrt` into its `+ 1` while leaving the numerator's as a plain rounded `FMULD`.

    **Read the disassembly per *use*, not per expression.** A `hfsq :=` in the source is a hint about
    intent, not a statement about how many roundings there will be.

43. **Two of upstream's own hex annotations are wrong, and one of Go's constant pairs is deliberately
    redundant.** Three transcription traps in one file:

    - `log1p.go` annotates `Sqrt2M1 = 4.142135623730950488017e-01` as `0x3fda827999fcef34` and
      `Sqrt2HalfM1 = -2.928932188134524755992e-01` as `0xbfd2bec333018866`. Go compiles the
      **decimals**, which round to `0x3FDA827999FCEF32` and `0xBFD2BEC333018867` — two ULP and one ULP
      away. Trusting the comment moves a branch boundary.
    - Only the `Sqrt2M1` error is *observable*, and the asymmetry is worth understanding rather than
      shrugging at: a one-ULP change to a boundary alters behaviour for exactly the inputs in the
      ULP-wide gap it opens, which here is a single value. For `Sqrt2HalfM1` the `k = 0` shortcut and
      the full reduction agree to the last bit at that value, so no corpus can catch it; for
      `Sqrt2M1` they do not, and the negative control breaks. **A wrong branch constant is only
      testable if the two branches disagree in the gap.**
    - `sinh.go`'s `P0` and `Q0` are *different* decimals — `…9911847872 51e+6` and `…9912120772 77e+6`
      — that round to the same `float64`, `0xC1233FDEBA64BB4F`. Go's compiler notices and loads one
      constant for both. Neither is a typo and the port keeps both names.

    Corollary, and it applies to every remaining `math` port: **round-trip each constant through Go,
    never read the hex out of the comment.**


44. **An unexported field decides the result of every function in `promql/functions.go`, and both of
    its settings are live.** `EvalNodeHelper.enableDelayedNameRemoval` is unexported. When it is
    **false**, each function body strips the three schema metadata labels itself with
    `Metric.DropReserved(schema.IsMetadataLabel)`; when **true**, the labels are left alone and the
    `DropName` flag alone records the intent, for the last step of the query to act on.

    Both are reachable, and they are not the same default:

    | caller | setting |
    |---|---|
    | `cmd/prometheus` | **false** — a feature flag (`--enable-feature=promql-delayed-name-removal`) turns it on |
    | `promql/promqltest` | **true**, unconditionally (test.go:111) |

    So the exit gate — all 2,201 `eval` assertions — runs the setting an *external* caller cannot
    construct, because the field is unexported. Pinning only the zero value would leave the port's
    exit-gate behaviour untested, so `oracle/suites_promql_functions_elementwise.go` writes the field
    with `reflect` + `unsafe`, contained to one function, and the corpus is doubled over the axis.

    The consequence for the port: **`DropName` is set either way** — it is the intent, not the action.
    A port that sets it only when it also strips the labels will pass every eager case and fail the
    whole exit gate.

45. **Two behaviours in `functions.go` are pinned only by inputs chosen to distinguish them**, and
    both were found by a negative control passing when it should not have. Recorded because the shape
    recurs everywhere the port has a *plumbing* layer over an already-pinned one.

    - Every one of the 16 transcendental wrappers (`funcSin`, `funcExp`, …) can be rewired to Swift's
      **libm** without the first corpus noticing. Its values were 0, ±1, ±0.5, ±2, 21.5, NaN and ±Inf,
      and libm agrees with Go on all of them; the per-value arithmetic is pinned by `gocompat/*`, so
      nothing was missing there. `Fixtures/promql/functions-elementwise.jsonl` now carries a harvested
      witness per wrapper — a value where libm and Go differ. `0x3ffa6d48991d5506` covers nine.
    - `clamp`'s `math.Max(minVal, math.Min(maxVal, f))` can have its operands swapped without the
      first corpus noticing, because the order only decides whose **NaN payload** survives
      (quirk 28) and the corpus used `math.NaN()` for both the samples and the bounds. Bounds carrying
      distinct payloads fix it.

    The general rule: a corpus for a plumbing layer needs values that make the layer *below*
    distinguishable, which is not the same as values that are interesting to the layer below.

46. **Go does not compute the calendar from the Unix second count, and the difference is reachable
    from a PromQL query.** `Time.absSec()` (time.go:784) is
    `absSeconds(sec + (unixToInternal + internalToAbsolute))` — an `int64` addition, **then a
    reinterpretation as `uint64`**. Both halves matter, in opposite directions:

    | second range | what happens |
    |---|---|
    | `sec > 8113015807` (from about year 2227) | the `int64` addition **overflows**, and the `uint64` reinterpretation puts it back exactly — the true sum is below 2**64, so nothing is lost |
    | `sec < -9223372028741760000` | the sum is genuinely negative, and the reinterpretation lands near 2**64 — a nonsense date, deterministically. The band is **8,113,015,808 seconds wide**, about 257 years |

    So `year(vector(-Inf))` in Go is **+292277026596** — the *same* as `year(vector(+Inf))`, because
    `int64(-Inf)` saturates to `Int64.min`, which is inside the band. And it is not an
    infinities-only curiosity: one ULP of a `Double` near -9.2e18 is 2048, so ordinary sample data
    lands either side of the boundary, and the wrapped year *varies with the input* (only `Int64.min`
    itself gives 292277026596).

    An earlier version of `GoTime` computed the calendar straight from `unixSeconds` and carried a
    comment saying the wrap "would hide a bug rather than match anything observable". It differed from
    Go on exactly four of 400,201 probe seconds — all four at the extreme negative end — which is how
    that comment got retired. The port now models `abs` with a wrapping `&+` and a
    `UInt64(bitPattern:)`.

    A pleasant side effect worth keeping: going through the **unsigned** absolute count removes every
    floor-versus-truncate question. `abs / secondsPerDay` and `abs % secondsPerDay` need no sign
    correction, where dividing a negative Unix second count does.

47. **`days_in_month` cannot be a month-length table, because `time.Date` wraps too.** Upstream
    computes it as `32 - time.Date(t.Year(), t.Month(), 32, …).Day()`, leaning on `time.Date`
    normalising an out-of-range day: day 32 of a 31-day month is day 1 of the next.

    The obvious port — a `[31, 28, 31, …]` table plus a leap-year test — agreed with Go on 4,659 of
    4,664 corpus seconds and disagreed on the five extreme ones. At year 292277026854, January, Go
    returns **7**, not 31: `Date`'s own `int64(dateToAbsDays(…)) * secondsPerDay` (time.go's `Date`)
    overflows, and the `Day()` read on the far side lands somewhere else entirely.

    So the port reproduces the round trip — `dateToAbsDays`, the wrapping multiply and offset `Date`
    applies, then an ordinary calendar read — including both Neri–Schneider strength reductions,
    because they are what the wrapping arithmetic has to agree with.

    Two consequences worth stating:

    - The leap-year helper the table version needed is now **dead code**, and deleting it was the
      result of a negative control rather than a tidy-up: perturbing its 100- and 400-year exceptions
      changed nothing, because nothing called it. Dead code that no control can break is worse than
      no code.
    - `dateToAbsDays`'s `(979*amonth - 2919) >> 5` has slack: changing the constant to 2918 is
      invisible, because the shift absorbs it for every `amonth` in [3, 14]. Recorded so the next
      reader does not mistake a surviving perturbation there for a corpus gap.

48. **`simpleFloatFunc` and `simpleHistogramFunc` do not drop the same labels, and
    it is upstream's asymmetry rather than a slip.** `simpleFloatFunc` passes
    `schema.IsMetadataLabel`, so `abs(x)` loses `__name__`, `__type__` *and*
    `__unit__`. `simpleHistogramFunc` (functions.go:1946) passes an inline
    `func(n string) bool { return n == labels.MetricName }`, so
    `histogram_count(x)` loses **only `__name__`** and keeps the type and unit.

    The port originally used `IsMetadataLabel` in both by symmetry and failed 5 of
    599 fixture cases. `histogram_quantile` and `histogram_fraction` then go back to
    `IsMetadataLabel`, so all three spellings are live in one file. Read the
    predicate at each call site; do not infer it from the neighbour.

49. **Go reassigns the loop variable's `Metric` and then reads the name out of it,
    so eager name removal makes the annotation nameless.** In
    `funcHistogramQuantile`, `funcHistogramQuantiles` and `funcHistogramFraction`:

    ```go
    if !enh.enableDelayedNameRemoval {
        sample.Metric = sample.Metric.DropReserved(schema.IsMetadataLabel)
    }
    hq, hqAnnos := HistogramQuantile(q, sample.H, getMetricName(sample.Metric), …)
    ```

    The `getMetricName` reads the **already-dropped** labels, so with the server's
    default settings a native-histogram annotation carries no metric name, and with
    `promqltest`'s it does. A port that keeps the original sample around and passes
    *its* name gets the opposite answer in the common case — 30 fixture cases, all
    of them annotation text.

    The related trap in the same functions: `histogram_quantile` reports
    `validateQuantile` and `HistogramQuantile` against **`args[0]`** but
    `resetHistograms` and the forced-monotonicity info against **`args[1]`**, while
    `histogram_quantiles` reports `resetHistograms` and `HistogramQuantile` against
    `args[0]` and the monotonicity info against `args[1]` — *the string literal*.
    Positions appear in the annotation text, so these are contract, and pinning them
    needs the fixture to pass the query to `AsStrings`: with an empty query Go emits
    the bare message and every one of these becomes invisible. Four negative controls
    found that gap.

50. **The range functions read `matrixVal[0]` and nothing else, and three guards that
    look alike are three different behaviours.** `rangeEval` calls a range function
    once per input series, so the matrix it receives has exactly one entry — a port
    that loops over it produces one sample per series and is wrong nowhere a query can
    reach. The oracle *can* construct a multi-series matrix, so the corpus pins it.

    The guards, in the order they appear in `compareOverTime`/`varianceOverTime`:

    | condition | behaviour |
    |---|---|
    | `len(matrixVal) == 0` | return `enh.Out` — no series, no output |
    | `len(samples.Floats) == 0` | return `enh.Out` **with no annotation** — a histogram-only range yields silence from `max_over_time` |
    | `len(samples.Histograms) > 0` | *add* `HistogramIgnoredInMixedRangeInfo` and carry on with the floats |

    And two asymmetries in the same family that read like slips:

    - `ts_of_first_over_time` defaults both timestamp lists to `math.MaxInt64` and
      takes the **min**; `ts_of_last_over_time` defaults them to **0** and takes the
      **max**. So a series with neither floats nor histograms reports
      `MaxInt64 / 1000` from one and `0` from the other.
    - `first_over_time` and `last_over_time` both pick the **histogram** when a float
      and a histogram share a timestamp, because the comparison is strict (`f.T < h.T`
      and `h.T < f.T` respectively) and the histogram branch is the fall-through.

    `ts_of_max_over_time` uses `>=` where `max_over_time` uses `>`, so on a plateau the
    former reports the **last** maximum and the latter the first. They cannot share a
    comparator.

51. **`varianceOverTime`'s Welford is not the textbook one, and its Kahan
    compensation is only pinnable by long runs at a large offset.** The shape is

    ```go
    delta := f.F - (mean + cMean)
    mean, cMean = kahansum.Inc(delta/count, mean, cMean)
    aux, cAux = kahansum.Inc(delta*(f.F-(mean+cMean)), aux, cAux)
    ```

    Three things are load-bearing: `delta` is against the **compensated** mean; the
    second term re-reads `mean + cMean` **after** the update, so it uses the new mean;
    and the divisor is `count`, so `stdvar_over_time` is the **population** variance.

    All three, plus dropping the `aux` compensation entirely, survived a corpus of
    three- and four-sample series — the compensation terms were simply too small to
    see. What made them observable was a 50-sample run at `1e16`, a 101-sample run at
    `1e10`, and an alternating `1e17`/`1` series. **A Kahan accumulator needs enough
    samples at enough magnitude for the compensation to be non-negligible; a short
    series pins the algebra and not the compensation.**

    Still unwitnessed and recorded as such: rewriting `delta/count` as
    `delta*(1/count)`. The two differ only when both roundings compound, and nothing in
    822 cases distinguishes them.

52. **`promql.quantile` has two fused sites, and both were wrong until
    `quantile_over_time` reached it.** The function is unexported, so the oracle cannot
    call it — it was ported with a comment saying so and pinned by hand-written
    invariants instead. Adding `quantile_over_time` and `mad_over_time` made it
    reachable, and 12 of 1,480 cases failed immediately. Both sites are the patterns
    this document already records elsewhere:

    - `weight := rank - math.Floor(rank)` compiles to one `FNMSUBD`
      (quantile.go:743) that recomputes `q*(n-1)` **unrounded**, while the rounded
      `rank` is still what `Floor` reads. Quirk 40's family.
    - `values[lower].F*(1-weight) + values[upper].F*weight` fuses the **second**
      product into the add and leaves the first a plain `FMULD` (quantile.go:744).

    The lesson is the one HANDOFF §3 already states in the other direction: a corpus
    written for one layer finds bugs in the layer beneath it. Here the layer beneath
    had a comment explicitly saying it could not be differentially tested — and that
    was true only until a *caller* was ported. **"Unreachable by the oracle" is a
    statement about today's callers.**

53. **Two of `linearRegression`'s three unfusable groupings need *catastrophic
    cancellation* to be visible, and only one caller can produce it.**
    `covXY := sumXY - sumX*sumY/n` and `varX := sumX2 - sumX*sumX/n` have the same
    shape, and hoisting `1/n` out of either both fuses and reassociates. Yet with an
    ordinary corpus the `covXY` change breaks and the `varX` one does not.

    The reason is `interceptTime`. `deriv` passes `samples.Floats[0].T`, so `x` starts
    at 0 and `sumX2` is comfortably larger than `sumX*sumX/n`. `predict_linear` passes
    **`enh.Ts`**, so a tight cluster of samples far from the evaluation time gives `x`
    values that are nearly equal and huge — and then `sumX2 - sumX*sumX/n` is a tiny
    difference of enormous numbers, which is exactly where the grouping matters.

    Five samples 1 ms apart at `t = 1.7e12` with `enh.Ts = 0` is what closed it. The
    general point: **when two expressions share a shape but only one is pinned, the
    difference is usually in the caller, not in the expression.**

54. **`calcTrendValue`'s fusion is invisible on tidy inputs.** `tf*(s1-s0) + (1-tf)*b`
    is one `FMADDD` (functions.go:900). With `tf` of 0.5 and small integer data both
    products are exact and the fusion cannot be observed at all. Values with no exact
    binary representation — `tf = 1/7`, data of `0.1`, `1/3`, `1e8 + 0.7` — are what
    make it break. Same for the operand order: fusing `(1-tf)*b` instead of
    `tf*(s1-s0)` is a different answer, and also only on such inputs.

    Two perturbations in the same file are **provably** unobservable and are recorded
    so nobody reads their silence as a gap: `double_exponential_smoothing`'s initial
    `s0` (only read when `i-1 == 0`, where `calcTrendValue` short-circuits to `b`), and
    `linearRegression`'s `i > 0` guard on the `constY` test (at `i == 0` the sample
    *is* `initY`, so the comparison is false either way).

55. **`irate` and `idelta`'s two-sample selection is a hand-written merge, not a
    sort, and its equal-timestamp case is deliberate.** `instantValue` takes the last
    two floats in order, then merges the last two histograms in with a four-way
    switch: a histogram older than `ss[0]` is **discarded**, one newer than `ss[1]`
    shifts `ss[1]` down, and everything else — *including an equal timestamp* —
    overwrites `ss[0]`. Upstream's comment calls that "a correct order, even in the
    (irregular) case of equal timestamps".

    `isRate` then flips almost every decision, and the two hint tests are **not**
    mirror images:

    | | `irate` | `idelta` |
    |---|---|---|
    | float counter reset | result stays at `ss[1]` — the raw newer value | subtracted anyway |
    | hint is `GaugeType` | warns (not a counter) | — |
    | hint is *not* `GaugeType` | — | warns (not a gauge) |
    | histogram counter reset | subtraction skipped | subtracted anyway |
    | result | divided by the interval in seconds | left as a difference |

    The float-reset case is the one to get right: the result is left at `ss[1]`, not
    zeroed and not subtracted, which is why `resultSample` is seeded from `ss[1]`.

    Every annotation here is reported against `args.PositionRange()` — the range of
    the whole `Expressions` slice, not of `args[0]`.

56. **A fixture that renders a histogram with `String()` alone cannot see the hint or
    the bucket layout.** `FloatHistogram.String()` prints the count, the sum and the
    bucket *bounds*, but not `CounterResetHint`, the schema, the zero bucket or the
    spans. So `instantValue` failing to force the result's hint to `GaugeType`, and
    skipping `Compact` entirely, were both invisible — three negative controls passed
    that should not have.

    `promql/functions-*` now emit `histHint` and a `histBuckets` rendering of the
    schema, zero bucket, custom values and both span/bucket lists alongside
    `String()`. The same gap is already recorded for `promql/histogram-stats`
    (docs/HANDOFF.md §5), which carries `CounterResetHint` as its own field for
    exactly this reason — **the lesson did not transfer automatically to the next
    corpus, and that is worth noticing.**

    Relatedly, `verify-fixtures.sh` caught this corpus being **nondeterministic**: a
    case with two annotations recorded them in Go's map order, so the file differed
    between regenerations. Annotations are now sorted unconditionally, and `Sorted`
    governs only the sample order. Exception 7's reasoning applies to every corpus
    that renders more than one annotation, not just to `promql/annotations-set`.

57. **`resets`/`changes`' merge loop does not terminate when a float and a histogram
    share a timestamp, and this was confirmed by hanging the fixture generator.** Each
    iteration picks the next sample with two cases — float strictly earlier, or
    histogram strictly earlier. An **equal** timestamp matches neither, so no index
    advances, `curSample` keeps its previous contents, and the loop condition is still
    true.

    The port reproduces the selection faithfully and raises a `precondition` on the
    unmatched case, so a corpus that reaches it fails loudly instead of hanging — the
    same treatment exception 9 gives `sampleRing`'s three latent bugs.

    Two consequences for the corpus, both discovered the hard way:

    - equal-timestamp cases cannot be pinned at all, so they are excluded;
    - a case that is *safe* under one selector is not safe under another. The
      anchor-tie matrices (a float and a histogram sharing a timestamp **before** the
      range start) are fine with `[5m] anchored`, where `pickFirstSampleIndices` starts
      the loop past the tie — but `[10m] anchored` or `[5m] anchored offset 1m` moves
      the range start earlier, finds no anchor, returns `(0, 0)`, and hangs. Those two
      matrices therefore run against exactly one selector.

    Also pinned here: the first-sample test is
    `iFloat + iHistogram == 1 + firstFloat + firstHistogram`, which works because
    exactly one index advances per iteration and their **sum** is a step counter.
    Rewriting it as `== 1` breaks every anchored case.

    And `changes` never reads `enh.StartTimestamps` while `resets` does — though with
    start timestamps nil until Phases 6-7, that difference is currently unobservable
    and is recorded rather than tested.

## Not ported

- The React UI (`web/ui/mantine-ui`, ~25k lines TS) — ship the prebuilt bundle, do the five
  `index.html` placeholder substitutions.
- 26 of 29 service-discovery providers (~21.4k lines) — each needs a cloud SDK with no Swift
  equivalent. Keeping: `static`, `file`, `http`, `dns`.
- OpenAPI spec machinery (`web/api/v1/openapi*.go`, 4,067 lines).
- `util/fuzzing` and Go test infra (3,869 lines).
- `util/{zeropool,pool,runutil,runtime,osutil,netconnlimit,treecache,documentcli}` — Go-runtime
  gap-fillers Swift does not need.
