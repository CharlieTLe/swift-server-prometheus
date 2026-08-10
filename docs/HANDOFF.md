# Handoff

Written at the end of the session that landed `promql/functions.go`'s **float-only range
aggregations** — `aggrOverTime` and the thirteen entries around it, and with them the matrix input the
rest of the range family will reuse.
Read `README.md` first for what the project is, then this for how to continue it.

---

## 1. Where things stand

| Phase | State |
|---|---|
| 0 — pin upstream | done |
| 1 — foundations + verification rig | done |
| 2 — `PromRegex` (RE2) | done |
| 3 — native histograms | done |
| 4 — `PromQLParser` | done |
| 5 — engine + storage protocols | **in progress** — protocols, sample iterators, `value.go`, `quantile.go`, the `GoMath` arithmetic *and* transcendental layers (trig, hyperbolic, `Log1p`), `durations.go`, `PreprocessExpr`, the in-memory `Queryable`, `histogram_stats_iterator.go`, `prometheus/schema`, `GoTime`'s calendar and **all 82 `FunctionCalls` entries that can have a body** are landed (seven of Go's 89 keys are `nil`), the last four being the sorts — which needed Go's pdqsort and `natsort.Compare` ported first. `engine.go` has started: the front door (`NewEngine`, `NewInstantQuery`/`NewRangeQuery`, `validateOpts`), `FindMinMaxTime` and the `limit_ratio` sampler. the error vocabulary, and `Matrix.Sort` through the ported pdqsort. `Exec`, and the instant VECTOR SELECTOR (`populateSeries`, `evalSeries`, `vectorSelectorSingle`). Next: `timestamp` over a selector, `mergeSeriesWithSameLabelset`, then `matrixSelector` — which unlocks range functions, the vector binops and the aggregations — then `promqltest` |
| 6–10 | not started |

Green as of this commit: **333,458 committed differential cases, 483 tests**, on both Swift 6.4
(Xcode 27) and the Swift 6.1 floor.

```
Sources/            src     generated
  GoCompat          4,285       193
  PromHash            216         –
  PromMath             91         –
  PromModel           357         –
  PromLabels          798         –
  PromSchema          148         –
  PromEncoding        343         –
  PromRegex         3,312     3,974
  PromHistogram     4,125       163
  PromPosRange         51         –
  PromAnnotations     623         –
  PromChunkEnc        274         –
  PromChunks          117         –
  PromStorage       1,735         –
  PromTestStorage     453         –
  PromQLParser      5,993       550
  PromQL            4,901         –
Tests              11,321
oracle (Go)        15,215
```

### Verify everything in one go

```sh
swift build && swift test          # hermetic; no Go toolchain needed
./Scripts/verify-fixtures.sh       # needs Go + the pinned worktree
```

If `Scripts/` fails, the pinned upstream worktree is probably missing:

```sh
git -C ../../prometheus/prometheus worktree add ../prometheus-v3.13.2 v3.13.2
```

---

## 2. How to work in this repo

**`main` is protected.** Direct pushes are rejected. Every change goes through a PR that passes three
checks (`Xcode 27`, `Swift 6.1 floor`, `Verify fixtures against Go`). Reviews are *not* required —
merge your own PR once checks are green. `enforce_admins` is on, so this applies to the owner too.

```sh
git checkout -b feat/whatever
# ... work ...
gh pr create --base main --head feat/whatever --title "..." --body "..."
gh pr checks <n>                                   # wait for green
gh pr merge <n> --squash --delete-branch
```

**Generated files are never hand-edited.** `Scripts/regen-tables.sh` produces
`Sources/*/Generated/*.swift` from Go's own tables. `Scripts/regen-fixtures.sh` produces `Fixtures/`.

**Never format a float with Swift's defaults.** `Double.description`, `"\(x)"` and
`String(describing:)` do not match Go. Use `GoFloat.format`. This is ADR-4 and it is the single
easiest way to introduce a silent, wide-reaching divergence.

---

## 3. The methodology — internalise this before writing code

Correctness here is **not** defined by hand-written expectations. It is defined by differential
testing against Go.

```
oracle/        a separate Go module that runs the pinned Prometheus and Go and emits JSONL
Fixtures/      the committed output; `swift test` reads it and needs no Go
Scripts/       regen-fixtures.sh · verify-fixtures.sh · regen-tables.sh · fuzz-diff.sh
```

Adding a new byte-exact surface means **adding an oracle subcommand and a fixture file**, not writing
expected values by hand.

**This has corrected me, rather than the reverse, at least six times.** Every one of these was a case
where I had written a plausible expectation and the fixture proved the implementation right:

- `(?i)abc` renders `(?i:ABC)` — folded literals store the orbit *minimum*.
- A top-level `$` prints `(?-m:$)`, not `$`.
- U+1234 is printable, so Go emits it literally rather than `\x{1234}`.
- `\p{...}` resolution excludes `Properties`, so `\p{White_Space}` is an *error*.
- Swift's `Double(String)` rejects uppercase `0X1P-2`, which Go accepts.
- `getBound` panics on an out-of-range custom index; a single-span iterator's `currIdx` *is* the span
  offset.
- `-1^2` is `UnaryExpr(BinaryExpr(1^2))`, not `NumberLiteral(-1) ^ 2` — `%prec MUL` puts POW above
  the sign, and the literal-folding special case only fires when the operand *is* a literal.
- A bare `step()` is a `Call`, not a `DurationExpr`, and it is gated behind
  `EnableExperimentalFunctions` rather than `ExperimentalDurationExpr`.
- `foo * sum` is a product of two selectors: every aggregator name is also a `metric_identifier`.
- `lastClosing` behaves as though it were updated on *consume*, not on lex, because goyacc's states
  mostly default-reduce without reading a lookahead. Three error positions pin this.
- `FloatHistogram.testExpression()` emits `+Inf`, which upstream's own histogram lexer rejects.
- `Annotations.Add` keeps the **last** of two annotations with the same message, not the first —
  `Add` calls `incoming.Merge(stored)` and `annoErr.Merge` returns its receiver. I wrote the test the
  other way round and the fixture said no.
- Hinnant's `civil_from_days` divides the *whole* numerator by 365. Splitting the division across the
  terms compiles, looks plausible, and puts 1970-01-01 in the year 1881.
- `listSeriesIterator.Seek`'s stray-looking `idx = 0` assignment before its bounds check is **not** a
  bug. I wrote it up as one, then checked Go: `Seek` positioning at element 0 and returning its type
  is correct iterator behaviour, so the following `Next()` moves to element 1 as it should. The port
  matches Go exactly rather than "fixing" it. **Not every quirk is a quirk — probe before documenting
  a divergence, not just before implementing one.**
- `storageSeriesIterator.Seek(math.MinInt64)` returns `ValFloat` **without reading anything**. The
  loop is `for currT < t` and `currT` starts at `math.MinInt64`, so seeking to exactly that never
  advances, and the tail returns `ValFloat` because `currH` is nil. I asserted the opposite ("always
  advances at least once") and the fixture said no.
- **`math.Exp2` is assembly on arm64**, the mirror image of `math.Log`, and it is fused. Swift's libm
  `exp2` is one ULP out on roughly a fifth of realistic inputs — and on `2**0.5` libm is the *correct*
  one and Go is wrong. Reaching for the platform function would have put a silent one-ULP error in
  every `histogram_quantile` over exponential buckets. **Probe the platform function against Go before
  assuming it will do; do not assume the pure-Go source is what runs.**
- **Which expressions Go fuses is not guessable.** `quantile.go` fuses six, and the surprising one is
  `BucketQuantile`'s `rank`: `rank -= previousCount` compiles to a single `FNMSUBD` that recomputes
  `q*observations - previousCount`, so the binary search above still sees the unfused product.
  `BucketFraction` fuses nothing. `go tool objdump -s '<symbol>'` per function, every time.
- **A corpus that reaches a function through only one caller pins only that caller's domain.** This
  is the most transferable thing this session produced. `GoMath.log` was a literal, *unfused*
  transcription of Go's `log`, and it passed all 2,350 `gocompat/log2` cases — because `Log2` only
  ever calls `Log` on a `Frexp` fraction in [0.5, 1), which confines `k` to {0, -1}. It was one ULP
  wrong on `Log(5.2063069815873524)`, and what found it was a `gocompat/pow` case, because `Pow`
  computes `Exp(yf * Log(x))` on the raw `x`. Ask what fraction of a dependency's input domain your
  corpus actually reaches before treating it as covered.
- **"It is fused" is a claim, and it needs a failing case to be a tested one.** Unfusing one
  expression at a time and diffing against Go over tens of millions of inputs sorts Go's fusions into
  three groups: *provably unobservable* (`k*Ln2Hi` in `Log` and `Exp`, because `Ln2Hi` carries only 32
  significant bits and |k| ≤ 1075, so the product is exact — that is what the hi/lo split is *for*),
  *unobservable in search* (polynomial terms diluted below the final rounding), and *rare but real*
  (`Log`'s `R` at ~3 per million, `inner` at ~12 per million). A randomly generated corpus misses the
  last group by chance, so `gocompat/log` commits **harvested witnesses** — inputs found by that
  search specifically because they distinguish fused from unfused. Do this rather than asserting
  fusion in a comment; PORTING.md quirk 30 has the table.
- **A corpus written to test one layer will find bugs in the layer beneath it, and that is a
  feature.** The `promql/preprocess` corpus needed a duration literal at the `Int64` boundary to pin
  `calculateDuration`'s out-of-range check. That literal *crashed the parser* twice over — once in
  `durationOf` (Go's `int64(float64)` saturates on arm64; Swift's traps) and once in the printer
  (`-Int64.min` wraps in Go, traps in Swift, and Go really does print `offset --106751d23h47m16s854ms`).
  Neither was reachable from the 6,154-case `promql/parse` corpus, because upstream's own
  `parse_test.go` has no such literal. PORTING.md quirks 31–32. When a new corpus reaches into an
  older one's blind spot, expect to fix the older layer, and add the regression test *there*.
- **`math.Min`/`math.Max` are arm64 assembly and do not agree with the portable Go.** The raw-bits
  ±Inf check runs *before* NaN handling, so `math.Max(+Inf, NaN)` is `+Inf`. `FMAXD` is `FMAX`, which
  propagates NaN — the opposite of libm's `fmax` and `Double.maximum`. The operand order in
  `FMAXD F0, F1, F0` puts **`y` first**, which decides whose NaN payload survives. Quirk 28. The
  general point: `haveArch*` is per-function *and* per-architecture, so check the build tags of the
  `_asm.go` file rather than assuming the pure-Go source is what runs — `Log` is assembly on amd64
  and portable on arm64, while `Exp`, `Exp2`, `Min` and `Max` are the other way round.
- **`-1 * 0.0` in Go is **`+0`**, not `-0`.** Untyped constants are arbitrary-precision, where `-1 * 0` is
  exactly `0` and carries no sign. A corpus that wanted negative zero got positive zero and the
  fixture showed `0` where `-0` was expected. Use `math.Copysign(0, -1)`.
- **"There is no Go counterpart" is a claim about the *file*, not about the *behaviour*.** An earlier
  version of this document said the in-memory `Queryable` "has no Go counterpart to differentially
  test against", and concluded the assertions should live in the `.test` runner above it. The first
  half is true — `util/teststorage` is a wrapper over a real `tsdb.DB`, so the stand-in is our own
  code — and the conclusion did not follow. The *contract* the stand-in has to meet is entirely
  upstream's, and the oracle can stand up a real `tsdb.DB` and pin it. Doing so **corrected four
  behaviours that had been written the other way round**, every one of them silent:

  - `Select`'s visibility filter uses the **querier's** range while its trimming filter uses the
    **hints'** range, and hints *override* rather than narrow. Two ranges, not one. Quirk 33.
  - A series whose samples are all trimmed away is returned **empty**, not dropped — the skip is at
    chunk granularity and happens before trimming. Quirk 34.
  - `LabelValues` applies its limit **before** sorting, so with `Limit: 1` a label first seen as `"1"`
    then `"0"` yields `["1"]`. `LabelNames` truncates after sorting. Quirk 35.
  - The label APIs gate on the store's **overall** range and do not filter per series, so a value
    carried only by a series with no sample in range is still returned.

  The lesson generalises past this file: before accepting that something cannot be differentially
  tested, separate "no file to port" from "no behaviour to compare".
- **Do not assume a `tsdb.DB` you stood up yourself is configured like the one under test.** The same
  suite's first run produced a fixture asserting that **start timestamps are lost**, because
  `teststorage.NewWithError()` with no options uses `EncXOR`, and ST rides on `EncXOR2`.
  `EnableSTStorage` is not the switch — `db.go:247` says "currently it's noop" — and `promqltest`
  quietly sets `FloatChunkEncoding = chunkenc.EncXOR2` alongside it in its own `init()`. Committing
  that first fixture would have pinned the opposite of what the exit gate needs. Quirk 36, which also
  records the consequence: **Phases 6-7 must implement XOR2, not just XOR**, or
  `start_timestamps.test` cannot pass.
- **Upstream being nondeterministic is a finding, not an obstacle.** `promqltest`'s loader appends by
  ranging a Go map (`test.go:918`), and with a head-only DB an unsorted `Select` returns series in
  append order — so upstream has no unsorted order to be byte-exact against. Rather than invent one,
  the `storage/mem-select` corpus selects **sorted in every case** and the port's own insertion order
  is asserted Swift-side. Exception 11. Check whether the thing you are about to pin is a contract
  before pinning it.
- **A generator-built corpus can be blind in a way a literal-built one is not, and the blindness
  follows the *dependency's* short-circuit order.** `HistogramStatsIterator.setLastFromCurrent` stores
  a copy of the **full** previous histogram, buckets included, and storing the *stripped* one it just
  returned passed all 35 cases of the first `promql/histogram-stats` corpus. Every one of those cases
  was built from `tsdbutil.GenerateTestHistogram(n)`, whose count moves with `n` — so
  `DetectReset`'s count comparison answered before it ever looked at a bucket, and a baseline with no
  buckets at all was indistinguishable. What found it was a negative control, not a case. The fix was
  a generator whose count and sum are **fixed** and where only the bucket distribution moves
  (`baseline/*`, three cases). Generalisation: when your corpus feeds a dependency that short-circuits,
  ask which of its branches your inputs can actually reach — a family parameterised on one axis pins
  one axis.
- **Probe the platform function before delegating — and do not generalise from the one that agreed.**
  Before porting any of `GoMath`'s trigonometry, Swift's libm was compared against Go over 2,000,052
  inputs per function. `Abs`, `Ceil`, `Floor` and `Sqrt` agreed on every single one; `Sin` differed on
  23%, `Tan` on 41%, `Asin` on 67%, `Log10` on 65%. Had the four cheap agreements been taken as
  evidence about the family, seven functions would have been silently one ULP out across
  `sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`log10` and everything downstream of them. The probe is
  twenty lines of Go plus twenty of Swift and it answers the question outright — write it.
- **Classify each fusion by perturbation, not by the disassembly alone.** The disassembly says *what*
  is fused; only unfusing one site at a time and diffing against Go says whether the corpus can *see*
  it. For the trig block that was 27 perturbations: 18 broke, and the 6 survivors sorted into two
  provably-exact products (`y*PI4A`, `y*PI4B` — the constants carry 22 and 21 significant bits, which
  is exactly why Pi/4 is split into three parts) and four unobservable-in-12M-inputs ones. Where a site
  is observable but rare, **harvest a witness** and commit it, as `gocompat/log` does; a corpus that
  passes with the fusion undone has not tested it. Note `xatan`'s unrounded `fma(x, x, Q0)` is
  observable while `tan`'s structurally identical site is not — so "no witness found" is a fact about
  the search, not a licence to simplify.
- **Count what *can* be ported, not what exists.** Seven of `FunctionCalls`' 89 keys map to **nil** in
  Go: `start`/`end`/`step`/`range` are folded into a `NumberLiteral` before lookup, and
  `info`/`label_replace`/`label_join` are reached by the evaluator directly. None can ever have a body.
  The test now keeps three categories — ported, deferred, nil-in-Go — because without that split the
  port reads as 77/89 when the reachable total is 82. Quirk 62.
- **A corpus built from one family of generated values pins one axis — and this is now the third
  instance.** Every histogram shape in the `functions-*` corpora came from `genTestHistogram` (hint
  `UnknownCounterReset`) or was a hand-built gauge, so `sum_over_time`'s
  `counterResetSeen && notCounterResetSeen` could never both be true: the collision warning, its `&&`,
  and its absence were all invisible. The bounds-reconciliation info needed two custom-bucket shapes
  with *different* bounds, and there was one custom shape used twice. Four new shapes turned five silent
  controls into failures. Quirk 59. Alongside quirks 51 (magnitude for Kahan) and 54 (inexactness for
  fusion, cancellation for grouping), the rule is: **ask which *field* of the input each branch reads,
  and make sure two cases differ in it.**
- **When a control cannot fail, finish the argument — sometimes the answer is "upstream's line is
  dead", and sometimes it is "the corpus needs an INVALID input".** Two survivors in the sort sweep
  were proofs: `breakPatterns`' `length >= 8` floor is unreachable because its only caller runs after
  the `length <= 12` return, and `natsort.Compare`'s two `i == nChunksB-1` exits are redundant because
  the next iteration returns the same `false`. A third was a real gap of an unusual kind:
  `partialInsertionSort`'s `j >= 1` bound only differs from `j > a` when the comparator is
  *inconsistent*, so no amount of well-behaved data could witness it — the corpus needed NaNs placed
  inside a sub-range that starts above zero. Quirk 67.
- **Two negative controls can protect each other, and then neither one failing means anything.**
  `pickOrInterpolateLeftHistogram`'s `<` versus `<=` survived every corpus shape — because
  `interpolateHistograms` short-circuits on `t == t1` and hands back `h1.Copy()`, which is exactly what
  the branch it was replacing returns. Perturb both and the arithmetic path runs, and for NHCBs with
  different bounds it reconciles the layouts and emits two extra infos. `>` / `>=` and `t == t2`
  interlock the same way on the right. So: **when a control survives, ask what would absorb it, then
  perturb that too** — the pair is the unit of evidence, not the line. Quirk 65. It also pays to finish
  the argument: four other survivors in the same sweep turned out to be provably unobservable, one of
  them settling an open control left over from the float version.
- **Go's `append(enh.Out, …)` without a write-back is load-bearing in exactly one place.**
  `aggrOverTime`/`aggrHistOverTime` return the appended slice and leave the field's length alone, so
  `funcSumOverTime`'s incompatible-schema path — which returns `enh.Out` — *discards* the sample the
  aggregation produced. A port that mutates in place returns a partial sum beside the warning where Go
  returns the warning alone. Quirk 58. Slice-value semantics are not always allocation detail.
- **A corpus case that is safe under one input is not safe under another, and "safe" can mean "does
  not hang the generator".** `resets`/`changes`' merge loop does not terminate when a float and a
  histogram share a timestamp — neither of Go's two cases matches, so no index advances. Equal-timestamp
  cases are therefore excluded outright. But the *anchor-tie* matrices, where the shared timestamp sits
  **before** the range start, are fine under `[5m] anchored` (the loop starts past the tie) and hang
  under `[10m] anchored` or `[5m] anchored offset 1m` (the range start moves earlier,
  `pickFirstSampleIndices` finds no anchor and returns `(0, 0)`). Both variants were in the corpus
  before the generator hung. Quirk 57. **When a corpus dimension changes which code path runs, the
  safety of a case is a property of the pair, not of the case.**
- **A lesson learned in one corpus does not transfer to the next one automatically.**
  `promql/histogram-stats` carries `CounterResetHint` as its own field with a comment explaining that
  `FloatHistogram.String()` does not print it. The `promql/functions-*` corpora rendered histograms with
  `String()` alone — and so could not see `instantValue` failing to force its result's hint to
  `GaugeType`, or skipping `Compact` altogether. Three controls passed that should not have. Both
  corpora now emit the hint and a full span/bucket rendering. Quirk 56. **When adding a corpus that
  renders a type an older corpus already renders, go and read what the older one had to add.**
- **`verify-fixtures.sh` earns its keep on nondeterminism, not just on drift.** A case with two
  annotations recorded them in Go's map order, so `promql/functions-overtime.jsonl` differed between
  regenerations — the exact "a fixture whose own output is nondeterministic is worse than no fixture"
  trap in §4. Annotations are now sorted unconditionally in every `functions-*` corpus, and the
  per-case `sorted` flag governs only the samples. Exception 7 applies to *any* corpus that renders
  more than one annotation.
- **When two expressions share a shape but only one is pinned, look at the caller.**
  `linearRegression`'s `covXY := sumXY - sumX*sumY/n` and `varX := sumX2 - sumX*sumX/n` are the same
  grouping, and hoisting `1/n` out of `covXY` broke the corpus while the identical change to `varX` did
  not. The difference is `interceptTime`: `deriv` passes the first sample's timestamp so `x` starts at
  0, while `predict_linear` passes `enh.Ts` — and a tight cluster of samples far from the evaluation
  time makes `x` nearly constant and huge, which is the only way `sumX2 - sumX*sumX/n` becomes a tiny
  difference of enormous numbers. Five samples 1 ms apart at `t = 1.7e12` closed it. Quirk 53.
- **A fusion on tidy inputs is not a fusion you can test.** `calcTrendValue`'s
  `tf*(s1-s0) + (1-tf)*b` is one `FMADDD`, and with `tf = 0.5` and small integer data both products are
  *exact*, so unfusing it changes nothing. `tf = 1/7` and data of `0.1`, `1/3`, `1e8 + 0.7` made it
  break. Worth pairing with the Kahan lesson above: **the corpus has to be hostile in the specific way
  the arithmetic is fragile** — magnitude for compensation, inexactness for fusion, cancellation for
  grouping. Quirk 54.
- **"Unreachable by the oracle" is a statement about today's callers, not about the function.**
  `promql.quantile` is unexported, so it was ported with a comment saying the oracle could not reach it
  and pinned by hand-written invariants instead. Porting `quantile_over_time` and `mad_over_time` made
  it reachable, and **12 of 1,480 cases failed at once**: both of its fused sites were wrong — `weight`
  recomputes `q*(n-1)` unrounded, and the final weighted average fuses its *second* product only. Quirk
  52. So when a file says a function cannot be differentially tested, treat that as a note to revisit
  when its first caller lands, not as a settled fact.
- **A Kahan accumulator needs enough samples at enough magnitude before its compensation is
  pinnable.** `varianceOverTime`'s three load-bearing details — `delta` against the *compensated* mean,
  the second term re-reading `mean + cMean` *after* the update, and dropping the `aux` compensation —
  all survived a corpus of three- and four-sample series. The terms were too small to see. A 50-sample
  run at `1e16`, a 101-sample run at `1e10` and an alternating `1e17`/`1` series made all three break.
  Generalises to every Kahan site the evaluator still has to bring: a short series pins the *algebra*
  and not the *compensation*, and the two fail independently. Quirk 51.
- **The range functions read `matrixVal[0]` and nothing else.** `rangeEval` hands them one series at a
  time, so a port that loops over the matrix is wrong nowhere a query can reach — but the oracle can
  build a multi-series matrix, and does. The same file has three guards that look alike and are not:
  an empty matrix, a float-less series (silence, *no* annotation) and a mixed one (the float answer
  *with* an annotation). Quirk 50, which also records the two `ts_of_*` defaults being asymmetric and
  both `first_over_time`/`last_over_time` preferring the histogram at an equal timestamp.
- **Read the label-dropping predicate at each call site, not from its neighbour.** `simpleFloatFunc`
  drops all three schema metadata labels; `simpleHistogramFunc`, eight lines away in the same file,
  drops **only `__name__`** through an inline closure. The port used the neighbour's predicate and
  failed 5 of 599 fixture cases. `histogram_quantile` then goes back to the three-label version, so
  the same file has both. Quirk 48.
- **Go reassigns a loop variable and then reads it, which inverts an annotation's metric name.**
  `funcHistogramQuantile` does `sample.Metric = sample.Metric.DropReserved(…)` and *then*
  `getMetricName(sample.Metric)`, so under the server's default settings the annotation is nameless
  and under `promqltest`'s it is not. Keeping the original sample and passing *its* name is the
  natural port and is wrong in the common case — 30 fixture cases, all annotation text. Quirk 49.
- **An annotation's position range is invisible unless the fixture passes the query.**
  `Annotations.AsStrings(query, …)` renders `(line:col)` only when `query` is non-empty, so a corpus
  that passes `""` cannot see *which argument* an annotation is reported against. Four negative
  controls survived on that alone, and `histogram_quantile`'s argument choices are genuinely strange
  — `args[0]` for the quantile checks, `args[1]` for the reset and the monotonicity info, and for
  `histogram_quantiles` the monotonicity info goes against the *string literal*. Pass the expression
  as the query.
- **A corpus needs a shape that makes the annotating branch fire, and "has a NaN" is not enough.**
  `HistogramQuantile`'s two NaN annotations test `count < rank` and `count < h.Count`, where `count`
  is the bucket total — so a histogram whose buckets sum to `Count` triggers neither, NaN sum or not.
  Only a shape where `Count` **exceeds** the bucket total (real NaN observations, counted but in no
  bucket) reaches them. Until that shape existed, every position-range control passed.
- **"Reproducing a wrap would hide a bug rather than match anything observable" was a claim about
  reachability, and it was wrong.** `GoTime` computed the calendar straight from `unixSeconds` and said
  so in a comment. But Go computes it from `absSeconds(sec + unixToAbsolute)` — an `int64` add then a
  `uint64` reinterpretation — and for `sec < -9223372028741760000` that lands near 2**64 and gives a
  nonsense date. The path in: `dateWrapper` does `int64(el.F)` on **arbitrary sample data** with no
  guard, `int64(-Inf)` saturates to `Int64.min`, and so `year(vector(-Inf))` is legal PromQL whose Go
  answer is **+292277026596** — the same as `year(vector(+Inf))`. One ULP of a `Double` near -9.2e18 is
  2048, so ordinary data lands either side of the boundary too. Four of 400,201 probe seconds
  disagreed, and all four were explicit extremes rather than random draws. Quirk 46. The
  transferable part: **a comment that says "unobservable" is asserting something about every caller,
  including the ones that do not exist yet** — and `int64(someFloat)` on user data is exactly the kind
  of caller that turns an internal wrap into a contract.
- **A helper with no caller is worse than no helper, and a negative control is how you find out.**
  Porting `days_in_month` as a month-length table plus a leap-year test agreed with Go on 4,659 of
  4,664 corpus seconds; the five failures were at extreme years, where Go's own `time.Date` wraps and
  returns **7** for a January. Fixing it meant reproducing `dateToAbsDays` and `Date`'s wrapping
  round trip — which left the leap-year helper unreferenced. Perturbing its 100- and 400-year
  exceptions then changed nothing, which read like a corpus gap and was actually dead code. Deleting
  it was the fix. Quirk 47, which also records that `dateToAbsDays`'s `(979*amonth - 2919) >> 5` has
  genuine slack — 2918 is invisible — so *that* surviving perturbation is not a gap either.
- **A `--filter` that matches nothing reports success, and a negative-control harness cannot tell the
  difference.** `swift test --filter "promql/functions"` matched no tests — Swift Testing filters on
  the *type* name, and the `/` in the suite's display string is not it — so twelve controls came back
  "still green" when they had never run. The tell was the pattern: every control touching one file
  survived while its neighbours broke. **Assert that the harness ran something**: count
  `"Test run with"` in the output, not just the exit code.
- **A behaviour is pinned only if some input can tell the two spellings apart, and "the corpus has
  interesting values" is not the same thing.** The element-wise `functions.go` slice passed its first
  corpus with *every* one of the 16 transcendental wrappers rewired to Swift's **libm** — because the
  corpus's values were 0, ±1, ±0.5, ±2, 21.5, NaN and ±Inf, and libm agrees with Go on all of them.
  The per-value arithmetic is pinned by `gocompat/*` over millions of inputs, so nothing was missing
  *there*; what was missing was any value in *this* corpus where the two disagree. The fix is a
  harvested witness per wrapper (`0x3ffa6d48991d5506` alone covers nine). Same shape, second instance
  in the same slice: `clamp`'s `Max(min, Min(max, f))` survived having its operands swapped, because
  the order only decides whose **NaN payload** survives and the corpus used `math.NaN()` for both the
  samples and the bounds — one payload, nothing to distinguish. Generalisation for the evaluator work
  ahead: when a layer's job is *plumbing*, its corpus needs values chosen to make the layer below
  distinguishable, not values that are interesting to the layer below.
- **An unexported Go field can still be a contract, and reflection is the honest way to reach it.**
  `EvalNodeHelper.enableDelayedNameRemoval` is unexported and changes the result of every function in
  `functions.go`: false makes each body strip the three schema metadata labels itself, true leaves
  them. `cmd/prometheus` defaults it to **false**; `promqltest` sets it **true** (test.go:111), so the
  exit gate runs the setting an external caller cannot construct. Pinning only the zero value would
  have left the port's exit-gate behaviour untested, so the oracle sets the field with
  `reflect` + `unsafe`, contained to one function. The alternative — pin one branch, assert the other
  Swift-side — is the "no behaviour to compare" fallacy §3 already records for the in-memory
  `Queryable`.
- **`functions.go` is differentially testable and `engine.go` is not, and that is worth re-checking
  before each slice.** `promql.FunctionCalls`, `FunctionCall` and every type in its signature are
  exported, so a body can be called with a synthetic `EvalNodeHelper` and no engine. `evaluator` is
  unexported, so nothing in `engine.go` can be. The same question — "is there an exported entry point
  to the thing I am about to port?" — is what decides the order of the remaining Phase 5 work.
- **Observability of a fusion tracks its position in the Horner chain, and that is what reconciles
  the two halves of the previous bullet.** `xatan`'s unrounded `fma(x, x, Q0)` is observable and
  `tan`'s structurally identical site is not, which read as luck until the hyperbolics gave four more
  data points. Unfusing each term of a chain one at a time over 34,000,052 inputs produces a monotone
  gradient every time: `sinh`'s numerator 0 → 122 → 25,280 witnesses head to tail, its denominator
  0 → 5 → 4,426; `tanh`'s 0 → 2 → 1,545 and 0 → 122 → 10,513; and the six adds of `log1p`'s
  seven-term `Lp` chain 0, 0, 0, 0, 8, 315. The head is always the most diluted, because everything downstream scales its error by a
  value below 1 and adds a constant orders of magnitude larger. `sinh`'s and `tanh`'s unrounded
  recomputations happen to *be* the head; `xatan`'s and `log1p`'s are not. **So a search that finds
  nothing at a chain's head has measured position, not fusion** — which also means the cheap way to
  find out whether a corpus can see a chain at all is to perturb its *last* term first.
  PORTING.md quirk 40 has the table.
- **A broad corpus and a targeted one find different fusions, and you need both.** The first
  14,000,052-input search left `log1p`'s `Lp2` term silent; a second 20,000,000-input run weighted
  toward `|x| <= 0.625` and toward `1+x` within 2**-20 of a power of two found 8 witnesses for it. The
  branch was *reached* 180,873 times in the broad pass — coverage was never the problem, density was.
  Count branch hits before concluding a site is unobservable, then re-run weighted at the thin ones.
- **Read the disassembly per *use*, not per expression.** `log1p` writes `hfsq := 0.5*f*f` once and
  reads it in two returns two lines apart: at log1p.go:200 the inner `hfsq` is `fma(f, 0.5*f, R)` and
  the outer one is the rounded value; at :202 **both** are unrounded, because `SCVTFD R1, F4` has put
  `float64(k)` in the register the rounded `hfsq` was living in. Register pressure decided the
  rounding. No amount of care with the Go text produces that, and unfusing the :202 outer one moves
  188,208 of 20,000,000 results, so it is not hiding either. Quirk 42.
- **Do not read a constant's hex out of upstream's comment.** `log1p.go` annotates `Sqrt2M1` as
  `0x3fda827999fcef34` and `Sqrt2HalfM1` as `0xbfd2bec333018866`; Go compiles the decimal literals,
  which are `0x3FDA827999FCEF32` and `0xBFD2BEC333018867` — two ULP and one ULP away. Both are branch
  boundaries. Round-trip every constant through Go. Quirk 43, which also records why only *one* of
  the two errors is testable: a wrong boundary changes behaviour only for inputs in the ULP-wide gap
  it opens, and for `Sqrt2HalfM1` the two branches agree to the last bit at that single value. **A
  wrong branch constant is only catchable if the branches disagree in the gap** — which is worth
  knowing before writing a negative control and concluding the corpus is weak.
- **"Zero differences" has three causes, and only one of them is "unobservable".** Perturbing
  `log1p`'s 21 fused sites left 14 silent, and they were not one group: four are *provably exact*
  (a `×0.5`, and three `k*Ln2Hi` products where `Ln2Hi`'s 32 significant bits make the product exact),
  one is *unreachable code* (log1p.go:192 needs `iu == 0 && k == 0`, which implies `|x| <= 2**-53`,
  which log1p.go:141 has already returned for), and nine are *diluted*. Only the last deserves the
  word "unobservable", and only the first deserves a comment saying it can never matter. Instrument
  branch coverage alongside the perturbation and the three separate immediately.
- **A routine with no arithmetic of its own still cannot be delegated to libm.** `cosh` fuses nothing
  and its whole body is `x = Abs(x); return (Exp(x) + 1/Exp(x)) * 0.5` — and it differs from Swift's
  `cosh` on 13.6% of inputs, every one of them inherited from `Exp`. The probe is what says so; "there
  is nothing here to get wrong" is not an argument.
- **21 negative controls, 2 survivors, and both survivors were the answer rather than a gap.**
  Perturbing the stats iterator one behaviour at a time broke 19 of 21 fixture runs. The two that
  stayed green — ignoring the reuse buffer entirely, and clearing `current` in `Reset` — are precisely
  the two places Go is managing allocations that a Swift `struct` does not have. That is worth knowing
  *before* writing a comment claiming something is unobservable: run the perturbation and let it tell
  you, then say so in the comment. Both are now recorded that way in
  `Sources/PromQL/HistogramStatsIterator.swift`.

When a fixture disagrees with you, **check Go before changing the implementation.** Write a five-line
Go program in `/tmp` and run it. That habit is the highest-leverage thing in this repo.

**A passing differential test proves nothing until you have seen it fail.** The look-back ring's
growth path is the clearest case: the fixtures passed first try, which is exactly when to be
suspicious. Perturbing the two-segment copy into the "obvious" logical-order copy broke 6 of 43 cases,
which is what actually established that the corpus reaches wrapped growth. Perturbing the eviction
comparison from `<` to `<=` instead **hung the test run**, because the newest sample is what terminates
that loop — a good reminder that a negative control can be worse than a failure, so kill it and
restore rather than waiting.

Fixture tests **batch-report** — collect all mismatches, show the first 20 and a count. Never stop at
the first failure; corpora run to tens of thousands of cases.

---

## 4. Traps that have already cost time

**Empty directories.** Git does not track them. A `.testTarget` whose directory exists only on your
machine builds locally and fails on a clean clone. This broke CI once (#1). The same rule bites
sooner than you expect when adding a *source* target: SwiftPM fails the manifest outright with
"target X referenced in product X is empty", so add the target and its first file together.

**A fixture whose own output is nondeterministic is worse than no fixture.** Two ways this nearly
landed in Phase 5:

- `Annotations` is a Go map, so `AsStrings` with a limit drops a *random* subset. Emitting the
  survivors would have made `Fixtures/promql/annotations-set.jsonl` differ run to run and
  `verify-fixtures.sh` flaky. The suite records the counts and the "N more … omitted" line instead.
- Encoding a float as a JSON number. `encoding/json` refuses NaN outright (the oracle panics, which is
  at least loud) and a decimal round trip is not bit-exact. Floats travel as 16-hex-digit bit
  patterns; the oracle has `fbits`/`unfbits` for it.

Also: **one fixture file holds one in/out shape.** `Fixtures.check` decodes the whole file with one
pair of types, so mixing shapes fails on decode rather than on comparison. Two suites in Phase 5's
first step were split for that reason (`promql/timestamp-floatsec`,
`chunkenc/{encoding,valuetype,compatible}`).

**Swift permits one protocol conformance per type, which forces some Go slice types to become
structs.** Go's `promql.Vector` is `[]Sample` with methods and `promql.Matrix` is `[]Series` with
methods, and both implement `parser.Value`. `Array` cannot conditionally conform to `Value` twice, so
both are structs wrapping the array, with `RandomAccessCollection` + `RangeReplaceableCollection` so
call sites still read like slices. Same forcing ADR-11 hit with `Expressions`; expect it again for any
named-slice-with-methods.

**A raw pass-through is only legal while the thing it passes through to is positioned.** Both
look-back wrappers forward `At`/`AtT`/`AtST`/`AtHistogram` straight onto the wrapped iterator, so
reading one after the `next` that exhausts indexes past the end of the sample list and Go panics —
taking the fixture generator with it. This cost three separate corpus rewrites in one sitting. An
op-script corpus must read the current sample *before* advancing, and must never read after the
advance that exhausts.

**CI runs an older Swift than you develop on, deliberately.** Wide chained shift-or/XOR expressions
compile on 6.4 and blow the Swift 6.1 type checker's budget. Write byte assembly as **loops or
stepwise statements**, never as one long chain. Phases 6–7 (`chunkenc` bstream, varbit, XOR encodings)
are almost entirely bit twiddling — this will bite again. Do not "simplify" the Swift 6.1 floor job
away; it exists because it caught a whole class of bug.

It is **not only bit twiddling**. Phase 5 tripped it twice on things that look completely innocent,
both accepted without complaint by Xcode 27:

- `(1969 * 365 + 1969 / 4 - 1969 / 100 + 1969 / 400) * 24 * 60 * 60` as an `Int64` constant — Go's
  own spelling of `unixToInternal`. Untyped integer literals are the expensive part: every one is an
  overload-resolution problem. Spell such constants as the value they denote, with the derivation in
  a comment.
- A three-way `+` of interpolated function calls building one annotation message. Build strings with
  `var s = …; s += …` in a `let x: String = { … }()`, not a concatenation chain.

Neither reproduces locally unless you install a 6.1 toolchain, so when you write either shape, assume
it is broken and restructure it before pushing.

**Corpus reproducibility.** Do not mine `$GOROOT` at fixture-generation time. The corpus would depend
on the local Go version, and CI's Go would produce a different corpus and fail `verify-fixtures.sh`
on a difference that means nothing. Copy the inputs into `Fixtures/` (as is done for Go's regexp
testdata and the PromQL `.test` files) and read them from there.

**The oracle now imports `tsdb`, and that cost 52 indirect modules.** `storage/mem-select` needs
`util/teststorage`, which needs `tsdb`, which imports `prometheus/config` → `discovery` → every
service-discovery provider — so `go mod tidy` pulled in the AWS, Azure, GCP, Hetzner and
OpenTelemetry-collector SDKs, 217 lines of `go.sum`. It is not accidental bloat and not avoidable:
Phases 6-7 differentially test the block, WAL and chunk formats against `tsdb` anyway, so the
dependency arrives regardless. Worth knowing before you go looking for what dragged them in, and
worth not "cleaning up".

**Toolchain noise in the manifest.** `verify-fixtures.sh` deliberately reports a differing Go patch
version as a *note*, not a failure, and restores the committed manifest. Keep it that way; a drift
detector that cries wolf gets ignored.

**Do not bulk-rename with regex across a large file.** I reconciled names across the 900-line parser
with `sed`-style substitution and produced duplicated attributes and broken initialisers. Targeted
edits would have been faster.

**A literal that overflows `Int` crashes the compiler, not your test.** `1 << 63` is Go's idiomatic way
to write 2^63 in `durationLiteralOutOfRange`; in Swift it overflows `Int` at compile time and the 6.4
compiler dies in its own IR verifier with no source location. Spell such constants as the `Double`
they denote. Expect more of these in Phases 6–7.

**The package enables `ExistentialAny`, so every protocol type needs `any`.** New files will not build
otherwise. `(any Expr)?` needs the parentheses; a conformance clause (`final class X: Expr`) must not
get one. Two more that only show up once you are writing protocols: `func err() -> Error?` must be
`(any Error)?`, and `InternalImportsByDefault` means a type in a **public** signature needs
`public import` of its module — `internal import` compiles until the first public method mentions it.

**Never give a type the same name as its module.** `PromQLParser` was both the module and a struct
inside it, which makes `PromQLParser.ValueType` unresolvable — Swift resolves the prefix to the struct.
That matters because `PromQLParser.ValueType` (vector, scalar, matrix, string) and
`PromChunkEnc.ValueType` (float, histogram, floatHistogram) genuinely collide in any module importing
both, exactly as `parser.ValueType` and `chunkenc.ValueType` do in Go — and Go's fix, package
qualification, is only available if the module name stays free. The struct is now `Parser` and the
internal mutable state is `ParseState`.

**`Error` refines `Sendable` in Swift 6.** So a mutable class cannot conform to `Error` without
comment. `annotations.annoErr` is exactly that (`SetQuery` mutates in place), and it must be an
`Error` because the engine returns annotations through `error`-typed results. The mutable state is
`nonisolated(unsafe)` with the ADR-3 justification written next to it; do not "fix" it with a lock,
which would put one on the evaluator's hot path for no gain.

**The parser corpus is extracted, not hand-written.** `promoracle parse-corpus` pulls every `input:`
string literal out of the pinned `parse_test.go` into `Fixtures/promql/parse-corpus.txt`, and
`regen-fixtures.sh` does that in the copy phase, before generation. Two of upstream's cases are built
with `fmt.Sprintf` and so are invisible to the extraction; they are added by hand in
`exprCorpus()`, which also reports on stderr if a new non-literal appears. If you bump the pin and
the count moves, check that first.

**ADR-9 keeps resurfacing.** A Go `string` is arbitrary bytes; a Swift `String` is valid UTF-8. Three
separate times a fixture "failure" was actually the harness decoding hex through
`String(decoding:as:)` and silently substituting U+FFFD. When a surface can carry arbitrary bytes,
the primitive must take `[UInt8]` and the `String` form must wrap it. **This is still an open
architectural question for `Labels`** — see §6.

---

## 5. What to do next: Phase 5, the engine

The **protocol substrate is done and merged**. What exists now:

| Target | Go origin | Notes |
|---|---|---|
| `PromPosRange` | `promql/parser/posrange` | split out of `PromQLParser`; see below |
| `PromAnnotations` | `util/annotations` | full port, 4,137 differential cases |
| `PromChunkEnc` | `tsdb/chunkenc/chunk.go` | **protocol surface only** |
| `PromChunks` | `tsdb/chunks/chunks.go`, `samples.go` | `Meta`, `ChunkRef`, `ChunkMetaIterator`, `Sample` |
| `PromStorage` | `storage/interface.go`, `errors.go`, `noop.go` | **query side only** |
| `PromStorage` | `storage/buffer.go`, `memoized_iterator.go` | in full |
| `PromStorage` | `storage/series.go` | **a slice** — the list iterators and `SeriesEntry` |
| `GoCompat.GoTime` | `time` | ADR-14 |
| `GoCompat.GoContext` | `context` | ADR-13 |
| `PromModel.Timestamp` | `model/timestamp` | |
| `PromQLParser.Statements` | `ast.go` | `EvalStmt`, `TestStmt` |
| `PromQLParser.Value` | `promql/parser/value.go` | the `Value` protocol |
| `PromQL` | `promql/value.go` | everything but `MarshalJSON` and `fParams` |
| `PromQL` | `promql/quantile.go` | in full |
| `GoCompat.GoMath.exp2` | `math.Exp2` | ported from the **arm64 assembly** |
| `GoCompat.GoMath` | `math.Exp`, `Min`, `Max`, `Mod`, `Pow`, `Ldexp`, `Modf`, `Trunc` | `Exp`/`Min`/`Max` from the **arm64 assembly**; `Pow`/`Mod` are Go's own algorithms, not libm's |
| `GoCompat.GoMath.log` | `math.Log` | **fusion fixed** — see §3 and PORTING.md quirk 30 |
| `GoCompat.GoDuration.seconds` | `time.Duration.Seconds` | the whole/fractional split, which is not `nanos / 1e9` |
| `PromQL` | `promql/durations.go` | in full — `DurationVisitor`, reachable only through `preprocessExpr` |
| `PromQL` | `promql/engine.go`'s `PreprocessExpr` closure | `foldQueryContextFunctions`, `preprocessExprHelper`, `newStepInvariantExpr`, `detectHistogramStatsDecoding`, `unwrapParenExpr` |
| `PromQL` | `promql/functions.go`'s two name sets | `AtModifierUnsafeFunctions`, `AnchoredSafeFunctions` — the rest of that file is the evaluator's |
| `PromStorage` | `storage/interface.go`'s `MockQueryable`/`MockQuerier` | no longer deferred; they had a caller |
| `PromTestStorage` | **not a port** — fills `util/teststorage`'s role | the in-memory `Queryable`; see below |
| `PromQL` | `promql/histogram_stats_iterator.go` | in full, plus `histogramStatsSeries` from engine.go:4785 — its only constructor. PORTING.md quirks 37-38 |
| `GoCompat.GoMath` | `math.Sin`, `Cos`, `Tan`, `Asin`, `Acos`, `Atan`, `Log10` + `trigReduce` | portable Go on arm64, not assembly and **not libm** — see below |
| `GoCompat.GoMath` | `math.Log1p`, `Sinh`, `Cosh`, `Tanh`, `Asinh`, `Acosh`, `Atanh` | portable Go on arm64. 36 fused sites, 19 witnessed. PORTING.md quirks 41-43 |
| `PromSchema` | `schema/labels.go` | new target. `isMetadataLabel` + `Metadata`; `IgnoreOverriddenMetadataLabelScratchBuilder` deferred to Phase 8 |
| `PromQL` | `promql/engine.go`'s `EvalNodeHelper`, `EvalSeriesHelper` | **three fields only** — `ts`, `out`, `enableDelayedNameRemoval`. The caches arrive with their callers; the file lists which and whose |
| `PromQL` | `promql/functions.go`'s element-wise arithmetic slice | `simpleFloatFunc` + 26 wrappers, `clamp`×3, `round`, `scalar`, `vector`, `time`, `timestamp`, `pi`, `sgn` |
| `PromQL` | `promql/functions.go`'s `dateWrapper` + the 8 date functions | |
| `PromQL` | `promql/functions.go`'s float-only range aggregations | `aggrOverTime`, `compareOverTime`, `varianceOverTime`, `quantile_over_time`, `mad_over_time` and the 13 entries around them. Quirks 50-52 |
| `PromQL` | `promql/functions.go`'s `extendedRate` | plus `interpolate`, `pickOrInterpolateLeft`/`Right`, `correctForCounterResets`. Quirk 63 |
| `PromQL` | `promql/engine.go`'s `populateSeries`, `getLastSubqueryInterval`, `extractFuncFromPath`, `extractGroupsFromPath`, `checkAndExpandSeriesSet`, `expandSeriesSet`, `evalSeries`, `vectorSelectorSingle` | the instant vector selector, over a real storage. Quirk 76 |
| `PromQL` | `promql/engine.go`'s `Exec`, `exec`, `execEvalStmt` (instant), `evaluator`, `Eval`, `rangeEval`, `gatherVector`, `scalarBinop`, `setOffsetForAtModifier` | the storage-free arms only: literals, parens, unary, step-invariant, scalar/scalar binops, calls with no matrix argument. Everything else throws by name. Quirks 74-75 |
| `PromQL` | `promql/engine.go`'s `ErrQueryTimeout`/`Canceled`/`TooManySamples`/`ErrStorage`, `errWithWarnings`, `contextErr`, `recover`'s classification | the error vocabulary of evaluation. Quirks 72-73 |
| `PromQL` | `promql/engine.go`'s `Engine`, `EngineOpts`, `NewEngine`, `QueryOpts`, `newQuery`, `validateOpts`, `NewInstantQuery`/`NewRangeQuery` | everything before `Exec`. No metrics, no `ActiveQueryTracker`, no logger — see PORTING.md. Quirks 70-71 |
| `PromQL` | `promql/engine.go`'s `FindMinMaxTime`, `getTimeRangesForSelector`, `subqueryTimes` | the query planner's time arithmetic — the first of engine.go. Quirks 68-69 |
| `PromQL` | `promql/engine.go`'s `RatioSampler`/`HashRatioSampler` | `limit_ratio`'s determinism, which rests on `Labels.Hash` (ADR-1). Quirk 68 |
| `GoCompat.GoSort` | Go's `sort.Sort` pdqsort (`src/sort/zsortinterface.go` @ go1.26.5) | one routine covers `sort.Sort`, `sort.Reverse` and `slices.SortFunc`; `sort.Stable` is not ported. Pinned to a Go TOOLCHAIN. Quirks 66-67 |
| `GoCompat.GoNatsort` | `github.com/facette/natsort`'s `Compare` + `chunkify` | the package's own `Sort` has no caller. Quirks 66-67 |
| `PromQL` | `promql/functions.go`'s four sorts | `sort`, `sort_desc`, `sort_by_label`, `sort_by_label_desc`, plus `filterFloats` and the two `vectorBy*ValueHeap` comparators. **82 of 82.** Quirks 66-67 |
| `PromQL` | `promql/functions.go`'s `extendedHistogramRate` | plus `interpolateHistograms`, both histogram interpolators, `validateHistogramRange`, `correctForCounterResetsHistogram`, the add/sub annotation wrappers and `annosFromInterpolationError`. Quirks 64-65 |
| `PromQL` | `promql/functions.go`'s `absent` | plus `createLabelsForAbsentFunction`. 78 of the 82 possible entries. Quirk 62 |
| `PromQL` | `promql/functions.go`'s `rate`/`increase`/`delta` | `extrapolatedRate` and `histogramRate`. `extendedRate` (anchored/smoothed) deferred. 77 of 89. Quirk 61 |
| `PromQL` | `promql/functions.go`'s `avg_over_time` | both paths, including the mid-range switch from a direct to an incremental mean. Quirk 60 |
| `PromQL` | `promql/functions.go`'s `sum_over_time` | `aggrHistOverTime` and the histogram Kahan path. 73 of 89 in total. Quirks 58-59 |
| `PromQL` | `promql/functions.go`'s `resets`/`changes` | `pickFirstSampleIndices` and `durationMilliseconds`; first reader of `StartTimestamps`. 72 of 89 in total. Quirk 57 |
| `PromQL` | `promql/functions.go`'s `irate`/`idelta` | `instantValue` and `isStartTimestampReset`. 70 of 89 in total. Quirks 55-56 |
| `PromQL` | `promql/functions.go`'s regression and smoothing | `linearRegression`, `calcTrendValue`, `deriv`, `predict_linear`, `double_exponential_smoothing`. 68 of 89 in total. Quirks 53-54 |
| `PromQL` | `promql/functions.go`'s histogram family | `simpleHistogramFunc` + the 5 readers, `histogram_fraction`/`quantile`/`quantiles`, `resetHistograms`, `metricWithBuckets`. 50 of `FunctionCalls`' 89 entries in total. Quirks 48-49, exception 13 |
| `GoCompat.GoTime` | the calendar half of `time.Time` | `utcDate`/`utcClock` rebuilt on Go's **absolute** second count, plus `utcWeekday`, `utcYearDay`, `dateToAbsDays`, `daysInMonth`. Quirks 46-47 |
| `GoCompat.GoConv.int64` | Go's `int64(float64)` | the saturating `FCVTZS`. `PromQLParser`'s `clampToInt64` now delegates to it |

`VectorSelector` now has its `unexpandedSeriesSet` and `series` fields, so ADR-11's mutate-in-place
design is finally exercisable.

**`posrange` had to become its own target.** Go's chain is
`promql/parser -> storage -> util/annotations -> promql/parser/posrange`, and upstream keeps
`posrange` a separate package precisely to break that cycle. Phase 4 folded it into `PromQLParser`,
which made the module graph circular the moment `storage` appeared. If you add a target under
`PromStorage`, check the direction of this edge first.

**`generic.go` and `lazy.go` are out of Phase 5 entirely** — an earlier version of this document
listed them for the iterator step, wrongly. Only ~145 of `generic.go`'s 822 lines are the merge
boilerplate its own header claims; upstream commit `e1f4380b2` parked a `web/api/v1` label-search
subsystem (top-K heaps, streaming merges, relevance scoring) in the other 677 without updating that
header. Neither half has a PromQL consumer: Part A is referenced only by
`merge.go`/`secondary.go`/`lazy.go`, Part B only by `web/` and `tsdb/querier.go`. Part A is also a
pre-generics type-erasure workaround whose adapters downcast with unchecked assertions, so a Swift
generic makes it vanish rather than needing a port. `lazy.go` is written against it. Both belong to
Phase 6, when there is more than one querier to merge.

**`storage.NewConcreteSeriesSet` does not exist at this pin.** The only `concreteSeriesSet` is
unexported in `storage/remote`. If you find a reference to it, it came from an older Prometheus or
from Cortex/Thanos.

### What Phase 5 still has to bring, in order

**The ordering below is not the one an earlier version of this document gave, and the reason is worth
knowing: `promql.FunctionCalls` and `promql.EvalNodeHelper` are both *exported*.** `FunctionCall` is
`func([]Vector, Matrix, parser.Expressions, *EvalNodeHelper) (Vector, annotations.Annotations)` and
every type in it is exported too, so the oracle can call any of `functions.go`'s ~100 bodies
**directly** — no running engine needed. Nothing in `engine.go` is reachable that way: `evaluator` is
unexported, so `scalarBinop`, `vectorElemBinop`, `aggregation` and the rest can only be pinned through
`Engine.NewInstantQuery`, which needs the Swift evaluator to exist first. So `functions.go` is
differentially testable *now* and `engine.go` is not, which inverts the obvious order.

1. **`promql/functions.go`'s bodies**, driven through `FunctionCalls` from the oracle. The
   element-wise arithmetic slice and the eight date functions are **done** — `EvalNodeHelper` (three
   fields), `EvalSeriesHelper`, `simpleFloatFunc` + the 26 math wrappers, `clamp`×3, `round`,
   `scalar`, `vector`, `time`, `timestamp`, `pi`, `sgn`, `dateWrapper` + `days_in_month`/`day_of_*`/
   `hour`/`minute`/`month`/`year`. `Tests/PromQLTests/FunctionsTests.swift` asserts the table is a subset of
   Go's whose complement is **exactly** the named deferred set, so the next slice is a matter of
   deleting names from that list. What is left, and what each needs:
   - the range ones — `extrapolatedRate`/`extendedRate`/`histogramRate` and the `*_over_time` family,
     which need `interpolate`, `correctForCounterResets` and the load-bearing groupings below;
   - the sorts, which need **Go's pdqsort ported** — see the note further down, and note that
     `funcSort` and `funcSortByLabel` go through *different* unstable sorts.
2. **`promql/engine.go`** — the evaluator, ~4,875 lines, pinned end-to-end through query results once
   it runs. `fParams`/`newFParams` from value.go belong here (they take an `*evaluator`), as does
   `vectorByValueHeap`. `quantile.go`, the `GoMath` layers and `HistogramStatsIterator` are already in
   place beneath it — the last of those means engine.go:4795's `histogramStatsSeries` is already done.
3. **`promql/promqltest`** — the `.test` file runner, which is what turns the committed testdata into
   the exit gate. Its patterns are already reproduced in `oracle/corpus.go`. Give it a **storage
   factory** parameter rather than hard-wiring `MemStorage`: that is what
   `RunBuiltinTestsWithStorage(t, engine, newStorage func(testing.TB) storage.Storage)` is for
   upstream, and it is how Phases 6-7 re-run the same 2,201 evals against the real Head.

The exit gate is unchanged and is the one that matters most in the whole project: **all 2,201 `eval`
assertions in `Fixtures/promql/testdata/` green**. That is the shippable-library milestone.

### The in-memory `Queryable`, and what is now known about it

`Sources/PromTestStorage` is **not a port** — it fills `util/teststorage`'s role in the module graph,
but upstream's is a thin wrapper over a real `tsdb.DB`, which Phases 6-7 own. It is a separate target
for the same reason upstream keeps `teststorage` out of `storage`, and so the real Head can be swapped
in behind the same protocol later.

`MemStorage` holds insertion-ordered series and a bespoke `append`/`load`/`clear` API — deliberately
**not** `storage.Appender`, which stays deferred to Phases 6-7 where `AppenderV2`'s commit/rollback
and ref caching mean something. The load path does enforce `memSeries.appendable`'s ordering rules for
`oooTimeWindow == 0` (`head_append.go:652`), duplicate-error messages included.

`MemQuerier`'s `select` is where the subtlety is, and all of it is pinned by
`Fixtures/storage/mem-select.jsonl` against a real `tsdb.DB` — see the four corrections in §3 and
quirks 33-36. The short version, because it is easy to get backwards:

- **stage 1, visibility, uses the querier's range**; a series with no chunk in it is never seen;
- **stage 2, trimming, uses the hints' range**, which *overrides* the querier's rather than narrowing
  it, and cannot resurrect an invisible series;
- both ranges are **closed** at both ends;
- a series admitted by stage 1 and emptied by stage 2 is **returned empty**.

Two documented divergences, both in PORTING.md: unsorted select order is insertion order because
upstream has none (exception 11), and visibility is modelled as one chunk per series, which can return
extra **empty** series that the evaluator cannot observe (exception 12).

Eight negative controls were run against the fixtures — perturbing each range, the sort, the
empty-series retention, the closed bounds, the matcher's empty-string handling and the label-limit
order — and every one of them broke the suite. The corpus is float-only on purpose: a histogram
appended to a real `tsdb.DB` returns through the chunk encoding, which re-derives `CounterResetHint`,
so pinning it would pin Phases 6-7's subject. Histogram carriage is a Swift-side test.

### The evaluator's fusion map — read this before porting `engine.go` or `functions.go`

Produced by disassembling all 239 functions of `engine.go` and `functions.go` out of a
`go test -c` binary and scanning for `FMADDD`/`FMSUBD`/`FNMADDD`/`FNMSUBD`/`FNMULD`. Recorded here
because it is expensive to derive and cheap to consult. Rebuild the binary with

```sh
cd ../../prometheus/prometheus-v3.13.2 && go test -c -o /tmp/promql.test ./promql
go tool objdump -s 'promql\.funcRate$' /tmp/promql.test          # a free function
go tool objdump -s 'promql\.\(\*evaluator\)\.aggregation$' /tmp/promql.test   # a method
```

and note the trap: **objdump attributes inlined callees to their own file's line numbers**, so
`extrapolatedRate`'s disassembly contains `time.go` and `float_histogram.go` lines. Attribute by the
file prefix, not by position.

**There are exactly five fused sites in the two files.** Everything else is unfused; plain Swift
operators are correct.

| site | expression | Swift |
|---|---|---|
| `engine.go:3838` | `aggregation`, STDVAR/STDDEV Welford | `group.floatValue.addingProduct(f - group.floatMean, delta)` — the subtraction rounds first; only the product and the add share a rounding |
| `functions.go:900` | `calcTrendValue` | `((1 - tf) * b).addingProduct(tf, s1 - s0)` — `tf*(s1-s0)` is never materialised |
| `functions.go:956` | `funcDoubleExponentialSmoothing` | `y.addingProduct(sf, floats[i].f)` where `y = (1 - sf) * (s1 + b)` |
| `functions.go:1099` | `funcRound`'s closure | `Double(0.5).addingProduct(toNearestInverse, f).rounded(.down) / toNearestInverse`, with `toNearestInverse = 1.0 / toNearest` hoisted out of the loop |
| `functions.go:1938`, `:1940` | `funcPredictLinear`, both returns | `intercept.addingProduct(slope, duration)` — there is no `FMULD` in the function at all |

Plus, already ported: `quantile.go`'s eight, and `float_histogram.go`'s `TrimBuckets` family.

**Kahan summation must NOT be fused, and that is guaranteed by upstream's source rather than by the
build.** `util/kahansum/kahansum.go` casts all three arguments *and* both results through
`float64(...)` — "The following casts are not no-ops!" — expressly to forbid fusing across the `Inc`
boundary, citing prometheus/prometheus#16895. So **any product handed to a Kahan step must be rounded
with a plain `*` first**. Three call sites make that easy to get wrong because they are FMA-shaped:
`aggregation:3804` (`q*floatMean`), `functions.go:1291` (`q*mean`), `functions.go:2006`
(`bucket.Count*delta*delta`, left-associative). Its `isInf` is hand-rolled as
`t > MaxFloat64 || t < -MaxFloat64`; keep that spelling.

**Four groupings are load-bearing even though nothing fuses**, because a rewrite changes the rounding:

- `interpolate` (functions.go:100) — `y1 + (y2-y1)*Δt/ΔT`, left-associated. Not `(y2-y1)*(Δt/ΔT)`.
- `extrapolatedRate:564`/`:569` — `sampledInterval * (a / b)`. Not `si * a / b`.
- `linearRegression:1883`/`:1884`/`:1887` — `sumXY - sumX*sumY/n`, `sumX2 - sumX*sumX/n`,
  `sumY/n - slope*sumX/n`. The division between the product and the subtraction is what prevents
  fusion; hoisting it would both fuse and reassociate.
- `aggregation:3897` — `v/n + c/n`, **two divisions then one add**. Not `(v + c) / n`.

**`Int64(Double)` traps in Swift where Go saturates.** Three sites, one of which is user-reachable and
now handled; `GoCompat.GoConv.int64` is the shared implementation:

- `functions.go:2487`, `dateWrapper` — **done**, via `GoCompat.GoConv.int64`. `int64(el.F)` is on
  **arbitrary sample data** and unguarded, so `year(vector(NaN))` is legal PromQL and would be a Swift
  crash. Go's `FCVTZS` gives NaN → 0 and ±Inf → the `Int64` extremes; the answers are 1970 for NaN and
  292277026596 for **both** infinities — the negative one because `Int64.min` lands in the band where
  Go's calendar wraps (quirk 46).
- `engine.go:3986`, `aggregationK` — `int64(fParam)`, guarded *upstream* by `rangeEvalAgg:1637-1645`
  using the hand-written float constants at `engine.go:67/69` (`maxInt64 = 9223372036854774784`, the
  largest `Int64` exactly representable as a `Double`). Port the guard and the constants together, or
  the port accepts inputs Go rejects with `Scalar value %v overflows int64`.
- `sin.go`'s `trigReduce`, reached from `sin`/`cos`/`tan` for `|x| >= 2**29` — `uint64(x * (4/Pi))`,
  a saturating `FCVTZUD`.

**`sort` and `sort_by_label` use two different unstable sorts, and both comparators are invalid.**
`funcSort`/`funcSortDesc` go through `sort.Sort` (`sort.pdqsort`); `funcSortByLabel*` through
`slices.SortFunc` (`slices.pdqsortCmpFunc`). Which one runs is observable, so they cannot share an
implementation. Worse, neither predicate is a strict weak ordering: `vectorByValueHeap.Less` returns
true for *both* orders of two NaNs, and `natsort.Compare` returns true both ways for `"a01"` vs
`"a1"`. Passing such a predicate to Swift's `sort(by:)` is undefined behaviour, not merely
order-unstable — so output fidelity here needs Go's pdqsort ported, including its insertion-sort
threshold of 12 and its `breakPatterns` xorshift.

**Go map iteration order feeds Kahan accumulation order, so upstream is itself nondeterministic.**
`rangeEval:1581`, `rangeEvalAgg:1710`, `aggregationCountValues:4215` and
`mergeSeriesWithSameLabelset:4274` all build their result by ranging a map. The final result is
sorted, but an *inner* expression's matrix order becomes `aggregation`'s `for si` order, which is the
order Kahan sums in. Consequences: do not try to reproduce Go's map order; drive `aggregation`
fixtures with an explicitly ordered input matrix rather than through `rangeEval`; and if the port
picks a deterministic order, record it as a divergence rather than discovering it later.

**Two smaller ones worth not rediscovering.** `1/Ln10` is a Go untyped constant folded in arbitrary
precision to `0x3FDBCB7B1526E50E`; the naive Swift `1.0 / 2.302585092994046` is
`0x3FDBCB7B1526E50D`, one ULP out — hard-code it when `GoMath.log10` lands. (`1/Ln2`, already
hard-coded, is identical either way; only `Ln10` bites.) And `ts_of_max_over_time` uses `>=` where
`max_over_time` uses `>`, so the former reports the **last** occurrence of the maximum and the latter
keeps the **first**.

### Deliberately not ported yet, so you do not go looking for them

Each is deferred to the phase that first has a caller, and each is noted in the file that would hold
it:

- `storage`'s **append side** — `Appender`, `AppendableV2`, and the exemplar/metadata/start-timestamp
  appenders (`interface_append.go`) → Phases 6–7, with the Head.
- `Storage`, `ExemplarStorage`, `SampleAndChunkQueryable` → Phase 6.
- `Searcher`, `SearchResultSet`, `SearchHints`, `Filter`, `Ordering` → Phase 9. Nothing in the engine
  or TSDB reads them. Note when you do port them: `noopQuerier`'s search methods return a **nil**
  `SearchResultSet`, so any caller reaching them panics.
- `merge.go`, `fanout.go`, `secondary.go`, `generic.go`, `lazy.go` → Phase 6.
- The rest of `series.go` — the chunk encoders, `chunkSetToSeriesSet`, `seriesSetToChunkSet`,
  `ExpandSamples*`, `ExpandChunks` → Phase 6, or Phase 10 for the remote-read path.
- `chunkenc`'s concrete encodings (XOR, XOR2, histogram, float histogram) and the bstream/varbit
  machinery → Phases 6–7. `PromChunkEnc` currently has no conforming `Chunk` at all.
- `schema.IgnoreOverriddenMetadataLabelScratchBuilder` → Phase 8. Its only callers are the three
  `model/textparse` parsers; the rest of `schema/labels.go` is ported.
- `context.WithValue` → Phase 9, for the query logger's `QueryOrigin`.
- **`MarshalJSON` on every `promql` value type** → Phase 9, with the HTTP API. This needs three
  byte-exact surfaces `strconv` does not give you: Go's `encoding/json` float encoder (an `'f'`/`'e'`
  switch at 1e-6 and 1e21, plus exponent cleanup), its HTML escaping of `<`, `>` and `&`, and its
  sorted map keys. Upstream's own comments say the `FPoint`/`HPoint` ones are unused inside
  Prometheus, so nothing before Phase 9 wants them.

### What is already worked out for you

**The parser gives the engine everything it needs.** In particular `preprocessExpr`'s mutations are
plain field assignments, which is the whole reason ADR-11 chose classes. Do not "modernise" the AST
into an enum without reading that ADR first.

**`checkAST` already runs at parse time**, so the engine can assume types are correct.

**Annotation messages are already byte-exact and pinned** — 4,118 per-annotation cases plus 19
collection cases. This matters because `promqltest` asserts them verbatim, so it removes a whole
class of exit-gate failure from the evaluator work.

**The look-back iterators are pinned by op-script fixtures with nested window drains** — 43 buffer
cases, 17 memoized, 14 list-series. Six behaviours that the engine depends on and that are easy to
get subtly wrong are documented as PORTING.md quirks 15–21: the closed retention window, the
current-element exclusion, already-positioned-after-construction, the two deltas, the
memo-cleared-before-a-failed-seek ordering, and the stale histogram in a mixed ring.

**`HistogramStatsIterator` is pinned the same way** — 38 op-script cases in
`Fixtures/promql/histogram-stats.jsonl`, six of them upstream's own `TestHistogramStatsDecoding`
tables reproduced in shape (whose expected hints are re-asserted directly in
`Tests/PromQLTests/HistogramStatsTests.swift`, since those numbers are upstream's rather than ours).
The corpus names its histograms by **generator** rather than by catalogue index, because counter reset
detection needs a family ordered by magnitude — `n` ascending is no reset, `n` descending is one — and
a catalogue of literals would hide that relationship. Two behaviours the evaluator will lean on are
PORTING.md quirks 37–38: a stale marker does not become the comparison baseline, and `Seek`'s guard
reads the *wrapped* iterator's `AtT()` before seeking it. The reason the fixture records the
`CounterResetHint` as its own field: `FloatHistogram.String()` does not print it, so the histogram
rendering alone would have pinned everything except the point of the type.

**`GoMath`'s transcendentals are done, and the measurement that forced them is worth keeping.** Before
porting anything, Swift's libm was compared against Go over 2,000,052 inputs per function. `Abs`,
`Ceil`, `Floor` and `Sqrt` agreed on **all** of them — they are the same hardware instruction either
side, so the port keeps using Swift's and there is deliberately no `GoMath.sqrt`. Every transcendental
disagreed, and not marginally:

| | | | |
|---|---|---|---|
| `Atan` 15% | `Sin` 23% | `Cos` 29% | `Tan` 41% |
| `Acos` 63% | `Log10` 65% | `Asin` 67% | `Round` 81 cases |

Part of that is the NaN payload — Go's `math.NaN()` is `0x7FF8000000000001`, Swift's `Double.nan` is
`0x7FF8000000000000` — but most is genuine one-ULP disagreement on ordinary arguments: `Asin(0.5)`,
`Atan(0.5)`, `Sin(2)`, `Cos(Pi/2)` and `Tan(Pi)` all differ. **Probe before delegating**, every time;
`Sqrt` agreeing is not evidence that `Sin` will.

`haveArchSin` and its siblings are true only on **s390x**, so these are portable Go on arm64 — the
opposite of `Exp`/`Exp2`/`Min`/`Max`. Fusion was resolved by disassembly and then *classified by
perturbation*: 18 of 27 unfusings break the corpus, and the 6 that survive are each explained in the
file (two provably exact, four unobservable in a 12,000,000-input search). Observable ones carry
harvested witnesses, as `gocompat/log` does. See `Sources/GoCompat/GoMath+Trig.swift` and PORTING.md
quirks 39-40.

**The `FunctionCalls` table is deliberately partial, and safely so.** `functionCalls` holds 34 of Go's
89 entries, and `Fixtures/promql/functioncallnames.jsonl` carries the full key set from Go so the test
can assert that the difference is **exactly** the named deferred set. That is what makes a partial
table safe rather than a trap: a body that goes missing fails the test instead of looking like one
that has not landed yet. Add the implementation and delete the name from the list in the same commit.

**The `enh.Out` reuse buffer is kept, not dropped.** PORTING.md exception 4 drops `sync.Pool`, and it
would have been consistent to drop this too — engine.go:1523 resets `Out` to empty before every call,
so in a running engine `append(enh.Out, …)` just means "build a fresh vector". But `Out` is
*exported*, so it is part of the surface the oracle drives, and it is the only thing that
distinguishes `funcPi`/`funcTime` (which return a fresh vector and ignore it) from every other body
(which appends). The corpus exercises a non-empty `Out` on eleven cases for that reason, and says so.

**`GoMath` is now complete for everything `functions.go` reaches.** The hyperbolics and `Log1p`
landed with the same discipline as the trig block: libm probed first (all seven diverge — `Tanh` least
at 5.4%, `Acosh` most at 69.5%), 36 fused sites mapped by disassembly, each unfused on its own over
34,000,052 inputs, 19 observable ones given harvested witnesses, and 39 negative controls run against
the committed fixtures of which 25 break. See `Sources/GoCompat/GoMath+Hyperbolic.swift` and PORTING.md
quirks 41-43.

Three findings from that slice that the evaluator work will meet again: observability of a fusion is
decided by its **position in the Horner chain** (quirk 40's new table), the same Go expression can get
**two different roundings two lines apart** because of register pressure (quirk 42), and upstream's own
**hex comments for two constants are wrong** (quirk 43). All three are in §3.

Nothing in `GoMath` is known to be missing. `math.Sqrt`, `Abs`, `Ceil` and `Floor` are deliberately
Swift's — they are the same hardware instruction either side and agreed on every probe input. If a
later phase needs `Gamma`, `Erf` or the `Bessel` family, probe libm before porting; if it needs
`Cbrt`, note that `Sqrt` agreeing is no evidence about it.

**The numeric risk is Kahan summation.** `PromMath` has it, pinned. A wrong Kahan term is exactly the
kind of silent divergence `docs/ROADMAP.md` warns about when it argues for PromQL before TSDB, and it
will not announce itself — `sum_over_time` will just be a few ULPs out.

**`promdiff` is still a stub** (§6), and Phase 5 is where it earns its keep.



## 6. Open decisions and risks

**`Labels` may need to become byte-backed (ADR-9).** Currently `String`-backed. The deciding moment is
Phase 8 (`PromTextParse`) — the first point where arbitrary bytes can enter from a scraped target.
Decide deliberately then: byte-backed `Labels` (`ContiguousArray<UInt8>` + offsets), or validate and
reject at ingest. Do not let whichever code is written first settle it by accident.

Phase 4 moved the line a little without settling it. `StringLiteral.val` is `[UInt8]`, because
`"\xff"` is a legal PromQL string and `strconv.Quote` has to re-escape the raw byte; so is
`GoNumError.num` and `PromDuration.ParseError`'s payload, for the same reason in `%q`. **A label
*value* carrying invalid UTF-8 is still lossy**: `Matcher.value` is a `String`, so
`{a="\xff"}` round-trips through U+FFFD. Nothing in the 6,154-case parse corpus reaches it, which is
why it is still open rather than fixed.

**`promdiff` is still a stub.** `Sources/promdiff/PromDiff.swift` prints a placeholder. The fuzz differ
(live oracle, nightly, discovers cases the committed fixtures miss) was designed in the plan but never
built. Worth doing before Phase 5, where silent numeric divergence is the main risk.

**`Scripts/fuzz-diff.sh` does not exist yet** — referenced by the plan and by `promdiff`'s comment.

**No `LICENSE` copyright question remains** — resolved to `Charlie Le`; see `NOTICE`. Note this port
derives from **three** differently-licensed sources (Prometheus Apache-2.0, Go stdlib BSD-3-Clause,
cespare/xxhash MIT). If you port from a new upstream, add it to `NOTICE`.

**Phase ordering rationale, if you are tempted to change it.** PromQL comes before TSDB because
PromQL's oracle (2,201 `eval` assertions in plain text) is portable and TSDB's (68,150 lines of Go
test code) is not, and because TSDB failures are loud (CRC mismatch) while PromQL failures are silent
(a wrong Kahan term). Phases 6–7 then re-run those same 2,201 evals against the real Head for free.
`docs/ROADMAP.md` has the full argument.

---

## 7. Documents worth reading, in order

1. `README.md` — what this is, how correctness is defined
2. `docs/PORTING.md` — the fidelity contract and its **thirteen documented exceptions**, plus 76 replicated Go quirks
3. `docs/DECISIONS.md` — ADRs 1–14, including the reasoning behind every awkward-looking choice
4. `docs/ROADMAP.md` — the ten phases and their exit gates
5. `CLAUDE.md` — conventions (cite the Go source in every file header, at the pin)

The exceptions in PORTING.md matter most. Each one is a place where "byte-exact" is deliberately not
true, with the reason. Do not silently fix them, and do not silently add to them.
