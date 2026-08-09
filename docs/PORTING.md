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


## Not ported

- The React UI (`web/ui/mantine-ui`, ~25k lines TS) — ship the prebuilt bundle, do the five
  `index.html` placeholder substitutions.
- 26 of 29 service-discovery providers (~21.4k lines) — each needs a cloud SDK with no Swift
  equivalent. Keeping: `static`, `file`, `http`, `dns`.
- OpenAPI spec machinery (`web/api/v1/openapi*.go`, 4,067 lines).
- `util/fuzzing` and Go test infra (3,869 lines).
- `util/{zeropool,pool,runutil,runtime,osutil,netconnlimit,treecache,documentcli}` — Go-runtime
  gap-fillers Swift does not need.
