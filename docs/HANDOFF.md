# Handoff

Written at the end of the session that finished **Phase 5** and built **Phase 6's read path**.

Phase 5's exit gate — `promqltest` over the committed `.test` files — now passes **2,183 of 2,183
assertions, zero failures and zero skips**, so the engine has nothing left to measure. Phase 6 went
from one merged slice to nineteen: both chunk encodings, the postings algebra, the index reader *and*
writer (the writer produces **byte-identical files** to Go's), the filesystem seam, the chunk writer
and reader, `meta.json`, and the `BlockReader` that joins them — so a block the port writes reopens
and every series' labels and samples survive. **What is left in Phase 6 is the querier-shaped API**
(§6m), which is what would let that 2,183-assertion gate run against a real block instead of
`MemStorage` — the strongest single check available to the TSDB port.

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
| 5 — engine + storage protocols | **DONE. 2,183 of 2,183 assertions pass — zero failures, zero skips.** Every evaluator arm, every runner directive, and every start-timestamp assertion. The gate has nothing left to measure. Detail: — protocols, sample iterators, `value.go`, `quantile.go`, the `GoMath` arithmetic *and* transcendental layers (trig, hyperbolic, `Log1p`), `durations.go`, `PreprocessExpr`, the in-memory `Queryable`, `histogram_stats_iterator.go`, `prometheus/schema`, `GoTime`'s calendar and **all 82 `FunctionCalls` entries that can have a body** are landed (seven of Go's 89 keys are `nil`). `engine.go` has: the front door (`NewEngine`, `NewInstantQuery`/`NewRangeQuery`, `validateOpts`), `FindMinMaxTime`, the `limit_ratio` sampler, the error vocabulary, `Matrix.Sort` through the ported pdqsort, `Exec`, the instant VECTOR SELECTOR (`populateSeries`, `evalSeries`, `vectorSelectorSingle`), `timestamp` over a selector, `mergeSeriesWithSameLabelset`, **range queries in full** — `execEvalStmt`'s range branch, `rangeEval`'s multi-step assembly, `addToSeries`, `StepInvariantExpr`'s step duplication — the **matrix selector** (`matrixSelector`, `matrixIterSlice`, `extendFloats`), and the **`matrixArg` half of the `Call` arm** — so **all 82 ported `FunctionCalls` bodies are reachable from a query**, `anchored`/`smoothed` included. and the **vector binary operators** in full (`VectorAnd`/`Or`/`Unless`, `VectorBinop`, `resultMetric`, `VectorscalarBinop`, `vectorElemBinop`, and `rangeEval`'s signature-ordinal machinery). and the **aggregations** — `rangeEvalAgg`, `aggregation`, `fParams`, the grouping-key/label pair — for the nine one-row-per-group operators. **all thirteen aggregation operators** — `aggregationK` and `aggregationCountValues` included, on `GoHeap` (Go's `container/heap`, ported because `limitk` emits its heap unsorted). and **subqueries** (`runSubquery`, `evalSubquery`, the `SubqueryExpr` arm and the `Call` arm's AST replacement). and **`label_join`**. Next: **`label_replace`**, which needs `FindStringSubmatchIndex` + `ExpandString` and therefore Pike VM **capture tracking** in `PromRegex` (`RegexCompiler.swift`'s header says the VM is deliberately boolean-only) — a PromRegex slice, not an evaluator one. and the binop **fill modifiers** and **`smoothSeries`**, so every other arm of the evaluator now runs. Then `info`, and `promqltest` — the exit gate. and **`util/convertnhcb`** wired into `load_with_nhcb`, worth +170 assertions on its own (§5e(b)). and **`chunkenc`'s metadata half** — `appendable`, the chunk-cut/header rules and the position-based hint derivation, wired into `MemStorage`, which took the gate to zero failures (§5e(c)). and **`info`** — `promql/info.go` plus `regexp.QuoteMeta`, 41 of `info.test`'s 42 (§5e(d)). and **`label_replace`**, on a new capture-tracking Pike VM in `PromRegex` (§5e(e)) — the last unported arm. and the last 11 **runner directives** (§5e(f)). Nothing in Phase 5 is outstanding. Next: **Phase 6's chunk ENCODER** — `tsdb/chunkenc/xor.go` on top of `wip/phase6-bstream` — which is also what the gate's last 23 skips wait on |
| 6 — TSDB | **started, and the whole READ path now exists.** Nineteen pinned slices, ~700 differential cases: `chunkenc`'s metadata half (§5e(c)), `bstream`, `xor.go` and `xor2.go` (§6a-§6c), the postings algebra and loser tree (§6g), the index READER (§6d-§6f) and the index WRITER (§6i-§6j) — which produces **byte-identical index files** to Go's — `PromFS`, ADR-15's seam (§6h), `chunks.Writer` and `chunks.Reader` (§6h, §6l), `meta.json` and `ULID` (§6k), and the `BlockReader` that joins them (§6m). A block written by the port reopens and every series' labels and samples survive, on both the in-memory and the real filesystem. **Next:** the querier-shaped API (`blockQuerier`/`blockChunkSeriesSet`), which would let the 2,183-assertion promqltest gate run against a real block instead of `MemStorage` — see §6m. Deliberately not ported: `tombstones` (exception 16). `MemPostings` waits for the Head in Phase 7 |
| 7–10 | not started. Phase 7 is the TSDB write path, 8 ingest, 9 the server, 10 remote read/write — see `docs/ROADMAP.md` for the exit gates. Nothing in 7–10 is blocked by Phase 5; the ordering rationale is in ROADMAP §"Why PromQL before TSDB" |

Green as of this commit: **338,951 committed fixture lines, 560 tests**, on both Swift 6.4
(Xcode 27) and the Swift 6.1 floor. The case count is `wc -l` over `Fixtures/**/*.jsonl` — the
previous figure in this line was computed some other way and had drifted, so the method is stated
here to make it reproducible rather than folkloric.

```
Sources/            src     generated
  GoCompat          5,329       193
  PromHash            216         –
  PromMath             91         –
  PromModel           432         –
  PromLabels          854         –
  PromSchema          148         –
  PromEncoding        343         –
  PromRegex         3,866     3,974
  PromHistogram     4,125       163
  PromPosRange         51         –
  PromAnnotations     623         –
  PromConvertNHCB     348         –
  PromChunkEnc      2,700         –
  PromChunks          692         –
  PromIndex         1,771         –
  PromFS              505         –
  PromBlock           510         –
  PromStorage       1,740         –
  PromTestStorage     522         –
  PromQLParser      5,995       550
  PromQL           12,833         –
  PromQLTest        1,255         –
Tests             16,051
oracle (Go)       22,802
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

**Negative controls are now scripted, per slice.** `Scripts/controls-rangequery.sh` and
`Scripts/controls-matrixselector.sh`: each perturbs one behaviour of its slice at a time, builds,
runs the relevant suites and restores the file, reporting `broke` / `SURVIVED` / `COMPILE`. The
second also takes a file index, because one of its controls perturbs a *neighbouring* file (the
runtime-error text `extendFloats` reproduces). Two details they exist to get right,
both of which cost time before: it **builds first**, so a perturbation that does not compile is not
mistaken for a failing test, and it requires the `"Test run with"` line, so a `--filter` matching
nothing cannot masquerade as green (§4). Copy one for the next slice rather than perturbing by
hand; a patch string that no longer matches reports `SKIP`, which is loud. Current scores:
range queries **12 of 15**, matrix selector **24 of 25**, the Call arm's matrix half **22 of
31**, the vector binops **29 of 34**, the aggregations **27 of 39**, `aggregationK` **23 of 31**, subqueries **13 of 22**, with
every survivor's argument written into the source next to the code it concerns.

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
- **Five green controls in one slice, and every one of them a proof — because the *type* was the
  argument.** The vector binops' survivors all came down to an invariant somewhere else:
  `VectorAnd`'s empty-right short-circuit is redundant because no ordinal can be marked present;
  `resultMetric`'s two-sided cache key is redundant because two rights for one left *is* the
  many-to-many error; `bytesWithLabels`' trailing separator is redundant because `Labels` admits
  neither an empty name nor an empty value, so `v1 n2` cannot split two ways; and
  `VectorscalarBinop`'s `!errors.Is(err, PromQLWarning)` cannot fire because the only warning
  `vectorElemBinop` produces needs a right-hand histogram, which a scalar never is. The habit
  worth taking: when a control survives, the argument is often about a *neighbouring type's*
  guarantees, not about the corpus.
- **A float-only corpus leaves three quarters of a four-quadrant function untested, and the fix is
  a unit test rather than more cases.** `vectorElemBinop` dispatches on `(hlhs, hrhs)`, and
  `promql/exec` is float-only on purpose — a histogram through a real `tsdb.DB` re-derives
  `CounterResetHint`, which is Phases 6-7's subject. So three controls survived. It is a free
  function over plain values, and the arithmetic beneath it is already pinned by
  `Fixtures/histogram/*`, so `VectorElemBinopTests` asserts the **dispatch** — which operator each
  quadrant allows, and that every rejection is an *info* rather than an error. Same shape as
  `MatrixIterSliceTests`: when the corpus cannot reach a layer, drop a level rather than
  contorting the corpus.
- **"Unreachable by the oracle" cost a crash this time, not just a blind spot — and the fix
  changed a type.** `funcDoubleExponentialSmoothing` panics in Go on a smoothing or trend factor
  outside `(0, 1)`, and the port had `preconditionFailure`. That was defensible while the oracle
  was the only caller: the corpus always passes valid factors, because an invalid one panics in Go
  and would take the fixture generator with it. The moment the `matrixArg` slice made the body
  reachable from a query, `double_exponential_smoothing(foo[5m], scalar(vector(time() / 400)),
  0.5)` at `t = 0` **crashed the test run**. `FunctionCall` is now `throws` — Swift accepts a
  non-throwing closure where a throwing one is expected, so the other 81 bodies were untouched.
  Same lesson as `promql.quantile` (quirk 52), with a sharper edge: **a `precondition` justified by
  "no caller can reach this" is a time bomb, and the fuse is the next slice.**
- **And the fix was then wrong in a way only NaN could show.** Go's guard is
  `sf <= 0 || sf >= 1`; the port wrote `!(sf > 0 && sf < 1)`. Every comparison with NaN is false,
  so Go lets a NaN factor **through** and produces NaN output where the negated form raises. The
  corpus case was added for the *error message* and it caught the *comparison*. ADR-4 is usually
  quoted about float formatting; it applies to comparison spelling too. Quirk 85.
- **Three green controls in a row can mean the line cannot matter.** The `Call` arm's
  `it.ReduceDelta(min(selRange, ev.interval))` survived being changed to either operand alone and
  being deleted outright — because every one of those leaves the buffer's delta *greater than or
  equal to* the correct value, `ReduceDelta` refuses to raise a delta, and `matrixIterSlice`
  appends only `t > mintFloats`. It is a memory optimisation and nothing else. Quirk 86. The
  transferable habit: when several controls on one line all survive, look for the *filter* below
  them before looking for the gap above.
- **Six different kinds of corpus blindness, in one slice, all found by controls.** Worth reading
  as a checklist before writing the next corpus, because no two were the same shape:
  *off-grid samples* for `smoothed`'s forward widening (on-grid, the interpolated boundary is a
  real sample); *sparse* off-grid samples for `anchored`'s buffer widening (dense, the unwidened
  buffer catches a boundary sample anyway); a scalar argument that **moves with the step** for the
  per-step `Floats[step]` lookup (every constant reads the same); an at-modifier-**unsafe**
  function with an `@`-pinned range for `refetch`'s second clause (`rate(foo[2m] @ 120)` cannot do
  it — the whole Call is step-invariant, so `preprocessExpr` wraps it and the child has one step);
  a **single-sample** series for the non-counter info's `len(ss.Floats) > 0` guard (`rate` needs
  two points, so the series contributes nothing and the check still runs); and a range function
  **nested inside another** `rangeEval` for the final window release.
- **"The corpus cannot see this" is sometimes a statement about the *querier*, and then the right
  fix is a unit test at the function.** Two `matrixIterSlice` controls — the window's half-open
  `t > mint` and the sought sample's `t == maxt` — survived every query-level case, and the reason
  is that `getTimeRangesForSelector` hands the querier `start = ts - range + 1` and `end = ts`
  (quirk 68) and **both** `MemQuerier` and a real `tsdb.DB` trim to those hints. No sample at
  exactly `mint` and none past `maxt` ever reaches the function. Upstream knows: its own comment
  is "Values in the buffer are guaranteed to be smaller than maxt" — guaranteed *by the caller*.
  So the tests belong at `matrixIterSlice`, not at `Exec`, and `Tests/PromQLTests/MatrixIterSliceTests.swift`
  is where they are. Generalises: when a control survives, ask *which layer* absorbed it before
  concluding the corpus is weak — and if the answer is "a layer the corpus cannot bypass", drop a
  level.
- **A reachable upstream panic is part of the contract, and finding one is worth the probe.**
  `extendFloats` indexes `floats[len(floats)-1]` with no guard, and `matrixSelector` calls it for
  *every* series the querier returned — including one admitted at chunk granularity and then
  trimmed to nothing (quirk 34). A chunk spanning the window with no sample inside it is enough,
  and Go answers `unexpected error: runtime error: index out of range [-1]` for `anchored` and
  `... [0] with length 0` for `smoothed` — two different messages, because `smoothed` reassigns
  the index from `sort.Search(-1, …)` which is 0. The corpus case was added as a *probe*, on a
  suspicion, and Go answered. A Swift trap is not catchable, so the port raises the error with
  Go's text; contrast PORTING.md exception 9, where three *unreachable* panics are guarded
  instead. **Reachability decides which treatment a panic gets, so establish it before choosing.**
- **A control that survives can be a *proof*, and this slice produced three of them at once —
  which is worth more than the twelve that broke.** The range-query slice ran 15 negative
  controls; 12 broke, and each survivor had a different kind of argument behind it. The
  duplicate-labelset check in the multi-step assembly is **unreachable** (no ported function
  emits two samples with one label hash). The step duplication reading `floats[0]` versus
  `floats.last!` is **provably identical**, because every point the loop appends carries
  `floats[0].f`, so `last` always *is* `floats[0]`. And the assembly's output ORDER is
  **provably unobservable** because the range tail sorts and no ported consumer reads it — which
  is what licenses picking insertion order over Go's map order (exception 14) rather than merely
  excusing it. The generalisation from quirk 67 holds: finish the argument, and name which of
  the three kinds it is.
- **A gap can need a Swift-side test rather than a corpus case, and knowing which is the
  skill.** Two survivors in that sweep were real gaps and they closed differently.
  `rangeEval`'s final `currentSamples = originalNumSamples + mat.TotalSamples()` needed a
  *nested* `rangeEval` under a tight `maxSamples` — `(time() + 1) + 1`, and not `(1 + 1) + 1`,
  because a literal is step-invariant and gets a one-step child evaluator instead. That is a
  corpus case. `addToSeries` putting a histogram in the float slice could not be a corpus case
  at all: the differential corpus is float-only *on purpose*, because a histogram through a real
  `tsdb.DB` re-derives `CounterResetHint` and pinning it would pin Phases 6-7's subject. So it
  is a Swift-side assertion — and finding the query took work, because `sort_by_label` is the
  **only** ported function that passes a histogram sample *through* a `rangeEval`
  (`sort`/`sort_desc` drop them in `filterFloats`, and every histogram *reader* returns a
  float).
- **An invariant written from reading the code lost to the fixture again, and the shape is worth
  naming: `preprocessExpr` decides which evaluator sees your code.** The sort-in-range-query
  warning tests `startTimestamp != endTimestamp`, so the natural invariant is "a range query
  warns". It does not: `sort(vector(1))` is step-invariant, gets wrapped, and runs in a child
  evaluator whose start equals its end — **no warning, in a range query**.
  `sort(vector(time()))` warns, because `time` is at-modifier-unsafe. Any claim about "what a
  range query does" has to ask whether the expression survives preprocessing as part of the
  range evaluation at all. Quirk 80.
- **A comment in the right file does not stop the bug; the fixture does.** Four defects landed in one
  session and every one was caught by a corpus, none by reading the diff: `rangeEval` counting only
  results and not `gatherVector`'s inputs; `EvalStmt.description` missing Go's `"EVAL "` prefix;
  `Matrix.sort` disagreeing with `sort.Sort` on duplicate label sets; and `atan2` returning
  `Double.nan` where Go returns payload 1. The last is the sharpest: `GoMath.goNaN` already existed a
  hundred lines away **with a comment saying exactly that and why the payload is observable**, and the
  new code still reached for Swift's. So when a surface has a known trap, the answer is a corpus case
  that would fail, not a note asking the next reader to remember. Quirks 74, 79.
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
- **"I regenerated it twice and it matched" does not establish determinism for a Go map.**
  `count_values("a b", cv)` produced three rows in map order — `a b` is *valid* under UTF8
  validation, a space and all, so it does not error the way the corpus assumed — and four local
  regenerations agreed. **CI disagreed on the first try.** With three entries the number of
  orders is small enough that repeated runs coincide by chance, so the sample size that convinces
  you locally is exactly the sample size that proves nothing. The fix is structural (sort the
  result, or restrict to one row), not statistical. Note the companion trap in the same slice:
  sorting only rescues an order when the sort **key** is unambiguous — a
  `sort_by_label(count_values(…))` case still drifted, because `natsort.Compare` treats `0.1` and
  `0.000000001` as equal. Quirk 96.
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
- **A corpus AXIS that is not plumbed through the harness reports 99.8% agreement.** The
  `delayed` axis (`EnableDelayedNameRemoval`, which is what `promqltest` runs with) was added to
  the oracle and to the wire type, and the Swift harness silently never passed it to `EngineOpts` —
  a `python` replacement whose pattern did not match. **987 of 989 cases still agreed**, because
  with the flag off each function body drops the metadata labels itself and the *final answer* is
  usually the same either way; only two cases could tell. So the failure looked like two ordinary
  divergences rather than a dead axis, and half an hour went into diagnosing the implementation
  before the harness. When adding an axis, **assert that it changes something**: pick one case
  whose two settings must differ and check the pair before trusting the other 987.
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

**An UNSORTED `Select` has no contractual order, and the `promql/exec*` suites are exposed to
it.** PORTING.md exception 11 records the finding for `storage/mem-select`, whose corpus therefore
selects sorted in every case. The evaluator does not have that option: `populateSeries` calls
`Select(sortSeries: false, …)`, and `execEvalStmt`'s vector tail renders the matrix in whatever
order came back. A head-only `tsdb.DB` returns **append order**, which is not a promise.

In practice it has been stable for hundreds of regenerations — and then
`sum_over_time(sq[2m:1m])` over a two-series selector flipped, months of green notwithstanding.
It has now happened **three times in one session**, each in CI after passing locally:
`count_values("a b", …)` (a Go map in the aggregation), that `sum_over_time`, and
`sum_over_time((sq + sq)[2m:1m])` — whose subquery inner expression is a *binop*, so it goes
through `rangeEval`'s multi-step assembly and inherits that map's order.

The rule that falls out: **a subquery over a plain selector is order-safe (`evalSeries` is
ordered); one over a binop or an aggregation is not.** Every multi-series case in `promql/exec` and
`promql/exec-range` carries the risk, so when one starts flapping reach for `sort_by_label` (or a
single-series selector) rather than assuming drift. And note the companion
constraint from quirk 96: sorting only helps when the sort *key* is unambiguous.

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
| `GoCompat.GoMath.atan2` | `math.Atan2` | nine ordered special cases, then `Atan(y/x)` with a quadrant shift. Unblocks PromQL's `atan2` operator. Quirk 79 |
| `GoCompat.GoMath` | `math.Sin`, `Cos`, `Tan`, `Asin`, `Acos`, `Atan`, `Log10` + `trigReduce` | portable Go on arm64, not assembly and **not libm** — see below |
| `GoCompat.GoMath` | `math.Log1p`, `Sinh`, `Cosh`, `Tanh`, `Asinh`, `Acosh`, `Atanh` | portable Go on arm64. 36 fused sites, 19 witnessed. PORTING.md quirks 41-43 |
| `PromSchema` | `schema/labels.go` | new target. `isMetadataLabel` + `Metadata`; `IgnoreOverriddenMetadataLabelScratchBuilder` deferred to Phase 8 |
| `PromQL` | `promql/engine.go`'s `EvalNodeHelper`, `EvalSeriesHelper` | **three fields only** — `ts`, `out`, `enableDelayedNameRemoval`. The caches arrive with their callers; the file lists which and whose |
| `PromQL` | `promql/functions.go`'s element-wise arithmetic slice | `simpleFloatFunc` + 26 wrappers, `clamp`×3, `round`, `scalar`, `vector`, `time`, `timestamp`, `pi`, `sgn` |
| `PromQL` | `promql/functions.go`'s `dateWrapper` + the 8 date functions | |
| `PromQL` | `promql/functions.go`'s float-only range aggregations | `aggrOverTime`, `compareOverTime`, `varianceOverTime`, `quantile_over_time`, `mad_over_time` and the 13 entries around them. Quirks 50-52 |
| `PromQL` | `promql/functions.go`'s `extendedRate` | plus `interpolate`, `pickOrInterpolateLeft`/`Right`, `correctForCounterResets`. Quirk 63 |
| `PromQL` | `promql/engine.go`'s `smoothSeries` + `VectorBinop`'s fill modifiers | the last two arms that need nothing outside `PromQL`. Quirk 99 |
| `PromQL` | `promql/engine.go`'s `runSubquery`, `evalSubquery`, the `SubqueryExpr` arm | the subquery's own step grid, the `@` re-rewrite, the counter-reset erasure and the AST replacement. Quirks 97-98 |
| `GoCompat.GoHeap` | `container/heap` @ go1.26.5 | `Push`/`Fix`/`up`/`down`. Ported because `limitk`/`limit_ratio` emit the heap's INTERNAL order. Pinned to a Go TOOLCHAIN, like `GoSort`. Quirk 94 |
| `PromQL` | `promql/engine.go`'s `aggregationK` + `aggregationCountValues` | topk/bottomk/limitk/limit_ratio and count_values, plus the two heap comparators. **All thirteen operators.** Quirks 94-96 |
| `PromQL` | `promql/engine.go`'s aggregations | `rangeEvalAgg`, `aggregation`, `generateGroupingKey`/`Labels`, `nextValues`, `handleAggregationError`, plus `value.go`'s `fParams`/`newFParams`. Nine of thirteen operators; `aggregationK` and `count_values` deferred. Quirks 91-93 |
| `PromQL` | `promql/engine.go`'s vector binops | `VectorAnd`/`Or`/`Unless`, `VectorBinop`, `resultMetric`, `VectorscalarBinop`, `vectorElemBinop`, `changesMetricSchema`, `handleVectorBinopError`, plus `rangeEval`'s signature ordinals and `Labels.bytesWith(out)Labels`. Quirks 87-90 |
| `PromQL` | `promql/engine.go`'s `matrixArg` half of the `Call` arm | plus the `absent_over_time` tail, the extended-modifier validation and the rate/increase non-counter infos. **All 82 bodies now reachable.** Quirks 85-86 |
| `PromQL` | `promql/engine.go`'s `matrixSelector`, `matrixIterSlice`, `extendFloats` and the `MatrixSelector` arm of `eval` | the range selector as a value, `anchored` and `smoothed` included. Quirks 82-84 |
| `PromQL` | `promql/engine.go`'s `execEvalStmt` (range), `rangeEval`'s multi-step assembly, `addToSeries`, `StepInvariantExpr`'s step duplication, the sort-in-range-query warning | **range queries in full**, for every arm that was already reachable. Quirks 80-81, exception 14 |
| `PromQL` | `promql/engine.go`'s `populateSeries`, `getLastSubqueryInterval`, `extractFuncFromPath`, `extractGroupsFromPath`, `checkAndExpandSeriesSet`, `expandSeriesSet`, `evalSeries`, `vectorSelectorSingle` | the instant vector selector, over a real storage, plus `timestamp` over a selector and `mergeSeriesWithSameLabelset`. Quirks 76-78 |
| `PromQL` | `promql/engine.go`'s `Exec`, `exec`, `execEvalStmt` (instant), `evaluator`, `Eval`, `rangeEval`, `gatherVector`, `scalarBinop`, `setOffsetForAtModifier` | the storage-free arms only: literals, parens, unary, step-invariant, scalar/scalar binops, calls with no matrix argument. Everything else throws by name. Quirks 74-75 || `PromQL` | `promql/engine.go`'s `ErrQueryTimeout`/`Canceled`/`TooManySamples`/`ErrStorage`, `errWithWarnings`, `contextErr`, `recover`'s classification | the error vocabulary of evaluation. Quirks 72-73 |
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



### 5d. Where Phase 6 starts, and what already exists for it

Recorded now so "the TSDB" stops being one undifferentiated 68k-line lump. Two targets already
exist and are **protocol surface only**, which is exactly where Phase 6 begins:

* `PromChunkEnc` — `Chunk.swift` declares `Encoding` (`none`, `xor`, `xor2`, `histogram`,
  `floatHistogram`), `MaxBytesPerXORChunk` and the iterator protocol; its own header says "the
  concrete encodings — XOR, XOR2, histogram, float histogram — arrive in Phase 6". `NopIterator`
  is the only implementation.
* `PromChunks` — `Chunks.swift` and `Sample.swift`, the metadata and sample protocols the
  encodings and the block reader both need.

So the first Phase 6 slice is **`tsdb/chunkenc/xor.go`**: `xorAppender`/`xorIterator`, the
bit-level reader and writer, and the delta-of-delta plus XOR-of-value encoding. It is the right
entry point because it is self-contained (bytes in, samples out, no index and no WAL), it has an
obvious differential shape — append a sample sequence, compare the encoded BYTES and then the
decoded round trip — and everything downstream in Phase 6 reads chunks, so nothing else can be
verified end to end until it exists.

Order after that, from the phase table: XOR2, the histogram encodings, then `tsdb/index`
(postings, the symbol table, the label index), then the WAL and tombstones, then `tsdb.DB`
itself. `PromTestStorage`'s in-memory `Queryable` (#20) is already pinned against a real
`tsdb.DB`, so it can act as the differential reference for block reads as they land.

### 5e. The next two slices, scoped

Read once so the next session does not spend context re-deriving them. `docs/HANDOFF.md` §5c did
this for `matrixSelector` and the plan was executed straight out of the doc; these are written the
same way.

**Every arm of the evaluator now runs except two**, and the exit gate is measured per file so the
payoff of each remaining slice is known rather than guessed. `eval` assertions, and how many of
each file's are blocked:

```
                          eval  label_replace  info(  load_with_nhcb
aggregators.test           160        0           0        0
at_modifier.test            71        3           0        0
collision.test               2        0           0        0
duration_expression.test    59        0           0        0
extended_vectors.test      169        0           0        0
fill-modifier.test          46        0           0        0
functions.test             427       15           0        0
histograms.test            185        0           0       32
info.test                   42        0          42        0
limit.test                  37        0           0        0
literals.test               25        0           0        0
name_label_dropping.test    30        3           0        0
native_histograms.test     522        0           0        0
operators.test             213        0           0        1
range_queries.test          18        0           0        0
selectors.test              31        0           0        0
staleness.test              17        0           0        0
start_timestamps.test       18        0           0        0
subquery.test               34        0           0        0
trig_functions.test         19        0           0        0
type_and_unit.test          58        0           0        0
TOTAL                    2,183       21          42       33
```

So **2,120 of 2,183 (97%) are reachable with the evaluator as it stands** — `label_replace` blocks
21, `info` blocks 42 (all of them in `info.test`), and `load_with_nhcb` gates 33 more at the
*loader* rather than the evaluator. That inverts the order: **write `promqltest` first.** Doing
`label_replace` first buys 21 assertions and cannot run any of them until the runner exists.

Two more things the table settles. `native_histograms.test` is the single biggest file at 522, and
it needs **no** blocked feature — so histogram support in the runner's loader is worth more than
either remaining function. And `start_timestamps.test`'s 18 need `EncXOR2`, which is quirk 36's
Phases 6-7 dependency, so they cannot pass until then whatever the runner does.

#### (a) `promqltest` — LANDED, and here is what it says

**2,068 of 2,188 assertions pass (94%), 2 fail, 118 skip — and both failures are a Phase 6-7
storage dependency, so the gate can see no remaining divergence in the engine itself.** (That is
after `util/convertnhcb` landed; the figure when the runner itself landed was 1,888 of 2,221, and the
skip table below is the *pre*-convertnhcb one, kept because it is what the next slice was chosen
from.) `swift test --filter PromQLTestTests` prints the
per-file tally and itemises every skip. There is no differential corpus, by design: the `.test`
files *are* the comparison, so a failure here is an engine bug and the number is the headline
metric. The test carries a **ratchet** (`promqlTestAllowedFailures = 0`) and a **floor**
(`promqlTestMinimumPasses = 1_448`) so neither a new failure nor a pass quietly turned into a skip
can slip through.

The 321 skips, and who owns each — **and the biggest bucket is now MEASURED rather than assumed**:

```
171  may need the NHCB companion series          util/convertnhcb (unported)
 42  info(...)                                   the evaluator
 33  load_with_nhcb's own load lines             util/convertnhcb
 21  label_replace                               PromRegex (captures)
 21  histogram-valued range assertions           the RUNNER
 23  @st loads and their dependents              Phases 6-7 (EncXOR2, quirk 36)
 ~8  expect … regex: / range vector / string     the RUNNER
```

`load_with_nhcb` appends the classic `_bucket` series **and** their NHCB conversions. The conversion
is `util/convertnhcb`, which is not ported — but the classic half is an ordinary load, so the runner
now does it and lets those assertions run, counting a *failure* in such a block as a skip rather than
a bug. That converted "205 assertions we knew nothing about" into a number: **10 pass on the classic
series alone and ~195 genuinely need the conversion.**

Which makes `util/convertnhcb` the **single largest remaining item in the gate** — worth ~195
assertions, more than `info` (42) and `label_replace` (21) combined, and it is a self-contained
utility rather than TSDB work. `PromHistogram` already has `convertNHCBToClassic`; this is the
inverse direction. Do it before either function.

The 39 failures are categorised in `Tests/PromQLTestTests/ExitGateTests.swift` next to the
ratchet. Three of them are **real engine findings** and worth naming here:

* the `conflicting counter resets during histogram aggregation` warning does not fire for
  `sum_over_time`/`avg_over_time` over a mixed-hint matrix. Quirk 59 says the `functions-*` corpus
  could never make `counterResetSeen && notCounterResetSeen` both true — and `native_histograms.test`
  has the shape that can. The corpus lesson predicted its own blind spot and the gate found it.

  **Two hypotheses were formed, tested and REFUTED, and both links are now pinned** — which is why
  this entry is worth reading before touching it:

  1. *the hint is lost between `MemStorage.load` and `matrixIterSlice`* (because the
     `storage/mem-select` corpus is float-only on purpose, so hint carriage had never been pinned
     anywhere). **Refuted.** `MatrixIterSliceTests.counterResetHintCarriage` loads a two-sample
     series hinted `notCounterReset` then `counterReset` and asserts both survive the querier, the
     buffer and the slice. They do.
  2. *`parseSeriesDesc` drops `counter_reset_hint:`* (plausible because Phase 4's 1,685-case
     series-description corpus compares `String()`, and `FloatHistogram.String()` does not print the
     hint — the trap §3 records for `promql/histogram-stats`, in a corpus that predates the lesson).
     **Refuted** by an assertion in the same test.

  So the hints reach `trackCounterReset`, whose two call sites match Go line for line including the
  seed sample, and the *values* are right (`{} 21`), so the aggregation runs.

  The annotation return path was then checked and is also correct: `Annotations.add` is `mutating`,
  the collision is added to the same `annos` the histogram branch returns, and the `failed` arm that
  replaces it cannot be taken here.

  **And here is the localisation that matters:** the *same* warning at a *wider* window **passes** —
  `histogram_count(sum_over_time(mixed[10m]))` at `14m` is green, and only the `[2m]` pair at `11m`
  fails. So the collision detection works; what differs is which samples are in the window and what
  hints they carry.

  The `mixed` load is a **`+`/`x` EXPANSION**:

  ```
  mixed {{sum:6 count:5 buckets:[2 2 1]}}+{{sum:2 count:3 buckets:[1 1 1]}}x4
        {{sum:4 count:4 counter_reset_hint:gauge buckets:[1 2 1]}}
        {{sum:6 count:5 buckets:[2 2 1]}}+{{sum:2 count:3 buckets:[1 1 1]}}x4
        {{sum:4 count:4 buckets:[1 2 1]}}+{{sum:2 count:3 buckets:[1 1 1]}}x5
  ```

  At `11m` the `(9m, 11m]` window holds the sample at 10m (the end of the second `x4` run, counting
  up) and the sample at 11m (a fresh literal whose count DROPS back to 4). The test says those two
  are hinted `not_reset` and `reset` — so **the hints on `+`/`x`-EXPANDED histogram samples are the
  remaining suspect**, and `counterResetHintCarriage` only pinned an *explicit* literal's hint. A
  wider window happens to include a differently-hinted sample and passes by luck.

  **FOUND — and the fourth hypothesis was wrong too, in a way worth recording.** Every
  `+`/`x`-expanded sample comes back `unknownCounterReset` in the port. The obvious conclusion was
  that the expansion skips `FloatHistogram.Add` (which calls `adjustCounterReset`, so Go's hints
  looked arithmetic-derived) — and a commit said so. It does not: `Parser+Semantics.swift:276` calls
  `next.add(inc)`, and `adjustCounterReset` returns early when both hints are equal, which they are
  for two freshly parsed literals. **So Go's expanded samples are `UnknownCounterReset` as well.**

  The `not_reset`/`reset` hints the test relies on therefore come from neither the parser nor the
  arithmetic. They come from the **storage**: `teststorage` wraps a real `tsdb.DB`, and the Head
  *re-derives* `CounterResetHint` as it appends — counting up gives `NotCounterReset`, a drop gives
  `CounterReset`. §5 has said this all along, about the `mem-select` corpus: "a histogram appended to
  a real `tsdb.DB` returns through the chunk encoding, which **re-derives `CounterResetHint**".

  So the last collision-warning failure is **not an evaluator bug at all** — it is `MemStorage` not
  deriving hints on append, which is Phases 6-7's chunk-encoding work reaching back into Phase 5's
  stand-in. It belongs with `load_with_nhcb` and `@st` in the Phase 6-7 column, and the honest move
  is to reclassify it there rather than count it against the engine.

  Five hypotheses: four refuted, three of them with permanent tests left behind, and the fifth is
  the one §5 wrote down before any of this started. **The symptom was four layers from the cause, and
  two of my confident conclusions were wrong** — which is the argument for testing each layer instead
  of reasoning from the one that failed.

  The lesson worth keeping regardless: **the two refuted hypotheses left two permanent tests
  behind.** Neither link had ever been pinned, both were plausible, and finding out cost less than
  reading either implementation would have.
#### (b) `util/convertnhcb` — LANDED, and it paid what the measurement said

**+170 assertions in one commit: 1,898 -> 2,068 passing, 118 skips left.** The scoping above put it
at "~195", and 170 of those turned out to be real while the rest were assertions inside
`load_with_nhcb` blocks that had already been passing on the classic series alone. Measuring the gap
before choosing the work is the whole reason this slice came before `info` (42) and `label_replace`
(21) — it was worth more than both together, and it is a self-contained utility rather than TSDB
work.

What it is: `Sources/PromConvertNHCB/ConvertNHCB.swift` (`TempHistogram`, the three setters,
`Convert`, and the metric-name helpers) plus `appendCustomHistograms` in the runner, which collates
each base metric's `_bucket`/`_sum`/`_count` parts by timestamp and appends one NHCB per timestamp.
Pinned by `Fixtures/histogram/convertnhcb.jsonl`, 49 cases.

**Four things the corpus and the controls caught that reading the Go would not have:**

1. the integer path compacts with `Compact(2)` and the float path with `Compact(0)` — quirk 100. Both
   controls **survived** the first corpus, because every case had at most a one-wide empty bucket run
   and nothing could tell the two arguments apart. Three cases now pin it, including a three-wide gap
   that *both* decline to merge, which is what proves the difference is the gap width rather than the
   path;
2. `errCountNotCumulative` renders `%g < %g` in two places and `%g > %g` in a third — quirk 101. Two
   cases failed on the first run for exactly this;
3. the **out-of-order predecessor** cumulativity check was never reached: every out-of-order case
   tripped the successor check first, so deleting the predecessor branch entirely left the corpus
   green;
4. the corpus recorded only `Convert`'s error, never what a **setter returned** — and upstream's own
   callers write `_ = h.SetBucketCount(...)`, so that half of the API was unobserved. Turning the
   out-of-order duplicate-`le` tolerance into an error changed nothing anyone looked at. The wire now
   carries `opErrs`.

`Scripts/controls-convertnhcb.sh` has 19 controls. 18 break; the survivor is
`out.validate()` in the loader, and it is **argued rather than covered**: `validate()` is a pure
check that only throws, and `convert()` cannot produce a structurally invalid NHCB from valid classic
input (single span run, always the custom-buckets schema, boundaries kept in order by
`setBucketCount`). The call is kept because upstream makes it and because Phase 8's scrape path will
reach it with input this loader never sees.

Two loader branches had **no coverage in the `.test` corpus at all** — a malformed `le`, and a
histogram-valued sample inside a classic series. Neither `histograms.test` nor `operators.test` (the
only two files with a `load_with_nhcb` block) has either, so both controls survived until
`NHCBLoaderEdgeTests` was written for them. Writing that test also caught a hand-derived expectation
of mine that was wrong: when a bucket is skipped, its boundary leaves `custom_values` too.

#### (c) `chunkenc`'s metadata half — LANDED, and the gate is at ZERO failures

**2,092 of 2,188 (96%), no failures, 96 skips — and `native_histograms.test`, the largest file at 522
assertions, passes all 522 with no skips at all.**

The last two failures were quirk 102 and they were never an evaluator bug: `MemStorage` returned
stored counter-reset hints unchanged where a chunk read-back **derives** them from the chunk's header
and the sample's position in it. `Sources/PromChunkEnc/HistogramMeta.swift` and `ChunkPlan.swift` port
that — `appendable`, `appendableGauge`, `expandFloatSpansAndBuckets`, `bucketIterator`,
`counterResetHint`, and the cut/header rules of `AppendFloatHistogram` — with **no bstream, no varint
and no bit packing**, because the decision half of that file is separable from the encoding half. §5d
still stands for the encoding: `xor.go` is where the *encoder* starts, and nothing here depends on it.

Pinned by `Fixtures/chunkenc/chunkmeta.jsonl`, 140 cases. `appendable` is unexported, so the corpus
drives the **composition** through three exported calls — `AppendFloatHistogram` says whether a chunk
started, `GetCounterResetHeader` says what header it got, `AtFloatHistogram` says what hint each
sample reads back with. That is a better seam than the private helper anyway, since the composition is
what the storage and the engine see. **This is the answer to the wall §5d hit with `bstream.go`: when
the function you want is unexported, look for the exported behaviour it decides.**

`MemStorage` keeps one `FloatHistogramChunkPlanner` per series and steps it once per append. That
matters: the first version replanned the whole series on every append and the gate went from 0.4s to
7.9s. The hint is decidable at append time — a chunk's header is fixed when the chunk starts and the
position rule only needs the count so far — so O(1) is available and correct.

Turning the derivation on let two things that had been held back deliberately go on with it: the
`counterResetHintSet` comparison (upstream passes it at test.go:1362) and the histogram-valued
**range** assertions, which Go compares by timing expectation value `i` at `start + i*step` and
splitting the list into a float list and a histogram list, each lining up element-wise with the
series' own two point slices. Together those were the last 22 skips in `native_histograms.test`.
Holding them back was right: turning them on before the storage could derive hints would have turned
2 failures into 8 and found nothing new.

**Five things the corpus and the 24 controls caught, none of which reading the Go would have given:**

1. a **stale** sample short-circuits `AtFloatHistogram` and comes back as a naked stale marker — no
   hint, no schema, no buckets — so it reads `unknown` however deep in a chunk it sits;
2. an explicit `CounterReset` hint **cuts a chunk**, and a chunk's first sample reads back `unknown`.
   So a sample written `reset` never reads back `reset`. Two hand-derived assertions in a row got
   this wrong before the code was asked;
3. `okToAppend` and `counterReset` are independent, and `NotCounterReset` headers are set **only** by
   a Head cut — an internal cut has no `prev` to compare against (quirk 103);
4. a **recode** returns a new chunk object without being a boundary (quirk 104). The oracle's first
   driver treated it as a cut and reported three hints for two samples — a bug in the *oracle*, which
   would have taught the port the wrong answer;
5. fifteen lines modelling the appender's layout preservation across a stale sample were **dead code**,
   and a surviving control is what proved it: once a chunk holds a stale sample, every following
   non-stale sample cuts and every following stale one is exempt, so nothing reads the preserved
   layout. Deleted, with the proof recorded.

Two controls also survived on **corpus** gaps rather than proofs, and both are worth the pattern:
`bucketIterator`'s zero-length-span branch and its first-offset start survived three rounds of
hand-picked span shapes. What killed them was **enumerating** the cross product of seven layouts
instead of choosing shapes — hand-chosen cases kept accidentally putting the same layout on both
sides, where the phantom buckets cancel. When a control survives a shape you thought you had covered,
enumerate.

#### (d) `promql/info.go` — LANDED, 41 of `info.test`'s 42

**2,092 -> 2,133 of 2,188 (97%), still zero failures, 96 -> 55 skips.** `Sources/PromQL/Engine+Info.swift`
plus `regexp.QuoteMeta` in `PromRegex` (62 differential cases). `info` works on **series**, so like
`label_join` it is dispatched from the `Call` arm and never appears in `functionCalls` (quirk 62).

40 of the 42 passed on the first run. The one failure was worth the whole slice: **`info(metric @ 60)`,
and the cause was that the `StepInvariantExpr` arm builds a fresh `Evaluator` that did not copy the
querier.** `info` is the only function that selects during evaluation — every other selector is
populated by `populateSeries` before the evaluator runs — so nothing had ever needed `ev.querier`, and
`@` makes an expression step-invariant. Go copies `querier` at all four construction sites
(`engine.go:819`, `:880`, `:1975`, `:2577`); the port now does too, subquery included. A field that
"nothing reads" is exactly the field a new caller will need.

Quirks 106-110 record what the code does not say out loud. The two worth reading before touching it:

* the `__name__` matcher in the label selector is **not** a data label matcher, and it must be stripped
  on both exits of `fetchInfoSeries` — left in, every series is excluded rather than enriched (106);
* an info sample's **timestamp rides in its float value** (`recordOrigT: true`), which is how two info
  series with the same signature are resolved newest-first. Its actual value is never read (108).

`Scripts/controls-info.sh` has 34 controls; 29 break. The five survivors are all **argued rather than
covered**, and three of the arguments are the interesting output of the slice:

* the identifying-label alternation is a **prefilter**, so `QuoteMeta`ing values and skipping ignored
  series can only narrow it — the join compares signatures exactly, so extra series fetched simply fail
  to match. Escaping becomes observable only when an unescaped value makes the pattern *invalid*
  (`a(b`), which is a query error rather than a wider answer (quirk 110);
* `start -= lookbackDelta - 1` is **redundant** against `vectorSelectorSingle`'s half-open lookback
  window: the only sample it excludes is one at exactly `startTimestamp - lookbackDelta`, which every
  step's own lookback excludes anyway (quirk 109);
* the `seenInfoMetrics` guard is **dead code upstream as well as here** — the loop iterates a map keyed
  by info metric name, so the name is distinct every iteration.

`InfoEdgeTests` covers six behaviours `info.test` does not reach, and writing it taught the thing worth
carrying forward: **the info select hints are only observable when the querier's own window is wider
than theirs.** `MemQuerier` is a two-stage filter and stage 1 clips to the querier's range, which
`getTimeRangesForSelector` computes with the *same* `@`/offset/lookback arithmetic — so a
single-selector argument makes the two windows coincide exactly and no perturbation of the hints can
show. Three tests proved nothing before that was understood; the fix was a two-selector argument plus
two info series whose newest-wins tie-break puts the difference in the *labels*.

#### (e) `label_replace` — LANDED, and **every evaluator arm is now ported**

**2,133 -> 2,154 of 2,188 (98%), still zero failures, 55 -> 34 skips.** It was a `PromRegex` slice
rather than an evaluator one: `Sources/PromRegex/RegexCapture.swift` is a second Pike VM that tracks
captures, plus `ExpandString`'s template language and a `CompiledRegex` facade carrying
`numSubexp`/`subexpNames`. 66 differential cases. The boolean VM in `RegexCompiler.swift` is untouched
and stays boolean — it answers a language-membership question that submatch boundaries cannot change.

**Three findings, and the first is the one to remember.**

1. **Go's `regexp` evaluator has two entry points and the difference is name removal** (quirk 111).
   Exported `Eval` runs `cleanupMetricLabels`, internal `eval` does not, and every function evaluating
   a *subexpression* must call the internal one. The port had collapsed them into one `eval`, so
   `label_replace` and `info` applied the deferred `DropName` to their own argument. The symptom looked
   nothing like a naming bug: `label_replace(rate({env="1"}[10m]), …)` reported **"vector cannot
   contain metrics with the same labelset"**, because both input series had already lost the
   `__name__` that made them distinct. `label_join` had it right; the two new callers did not, and the
   comment on `eval` now says which is which.
2. **The corpus wire cannot carry invalid UTF-8 as a JSON string.** Two cases disagreed on a lone
   `0x80` byte, and the cause was `encoding/json` replacing it with U+FFFD on the way out — so Go was
   measured on the raw byte and the port on the repaired one. The subject and template now travel as
   **hex**. ADR-9's trap, on the wire rather than in an API, and worth checking for in any future
   corpus that tests byte handling.
3. **`info` discards `DropName`**, so it preserves a metric name its argument was going to drop (quirk
   112). Only visible after finding (1), and it changed two expectations in `InfoEdgeTests`.

`Scripts/controls-labelreplace.sh` has 22 controls; 19 break. The three survivors are all the same
shape — **redundant given an anchored pattern or a caller one level up** — and all three are kept
because upstream has them and the first non-anchored caller will need them (quirk 115):

* the first-match cut, which matters only when a lower-priority thread can match further right;
* `matchcap[0] = pos`, which is always 0 for `^(?s:…)$`;
* `label_replace`'s own `mergeSeriesWithSameLabelset`, because `cleanupMetricLabels` merges every
  matrix unconditionally anyway.

#### (f) The last 11 runner directives — LANDED. **Phase 5 has nothing outstanding.**

**2,154 -> 2,165 of 2,188 (99%), zero failures, and all 23 remaining skips are ONE gap:** `@st` loads
and the assertions that depend on them, which need `EncXOR2` (Phases 6-7, quirk 36).

Three directives, and two of them were only possible after the capture VM:

* `expect fail regex:` and `expect … regex:` need an **unanchored** search. The boolean VM cannot do
  one — it answers whole-subject membership — but `findSubmatchIndex` re-seeds the start state at every
  position while unmatched, so an unanchored pattern compiled through `CompiledRegex` is exactly
  `regexp.MatchString`. **This is the caller that makes the first-match cut load-bearing**, the control
  for which survived on anchored patterns alone (quirk 115);
* `expect string <literal>` — the literal is Go-quoted, so it goes through `strconv.Unquote`
  (backticks are a raw string), and a bare `expect string` with nothing after it is an *error* rather
  than the empty string;
* `expect range vector from <d> to <d> step <d>` — an INSTANT query allowed to answer with a range
  vector, over the grid the line names rather than the eval's single timestamp. Two parts: the
  directive sets `cmd.from/to/step`, and the comparison must fall through to the matrix branch when an
  instant result is a `Matrix`. Without the directive Go rejects multiple values in an instant
  evaluation outright, with a message naming the directive, and that check is ported too.

Note the line is **nine** tokens, not eight — off-by-one on the split was the first bug.

#### (g) Phase 5 is DONE, and what Phases 6-10 need

**2,183 of 2,183 — zero failures, zero skips.** `EngineExecTests.unportedArmsAreLoud` asserts the
unported list is empty rather than iterating it.

The last 23 came with `EncXOR2` (§6b), and the encoding was only the first of four pieces:

1. the runner had to parse `@st` lines — `isSTLine`, `parseSTLine`, `parseSTSequence`, `parseSTItem`,
   `parseDurationPrefix`. An ST line does not stand alone: it describes the sample line that FOLLOWS it,
   so it is held pending, its metric must match and its value count must match **exactly** so that `_`
   placeholders line up. The sequence grammar has an asymmetry worth knowing — `_xN` gives **N**
   positions while `<dur>xN` gives **N+1**;
2. the gate had to set `useStartTimestamps: true`, which upstream's runner does (test.go:112);
3. **`MemStorage` had to DROP the ST on histogram samples.** `EncXOR2` is the only encoding with an ST
   field and it holds floats; the histogram chunks have no equivalent, so upstream accepts a `@st` line
   on a histogram series and then silently loses it. `start_timestamps.test` says so in as many words
   and its histogram expectations are written for the ST-free answers. Keeping the ST made four
   assertions fail with *plausible* numbers — `increase` returned 420 where upstream says 300 — which is
   the dangerous kind of wrong;
4. **`instantValue` never read `enh.startTimestamps` at all.** Its file header claimed "every `ST` here
   is 0", which was true only because nothing had ever enabled the flag. A comment describing the
   current state rather than the intended contract aged into a bug, and two `irate` assertions found it
   the moment the flag went on.

One harness fix on the way: `hDetail` did not print **count or sum**, so three of those failures showed
only the counter-reset hint differing while the real difference was the count. A failure message that
omits the field it is failing on is worse than no message.

Remaining phases, from `docs/ROADMAP.md`, none of them started beyond §5e(c)'s chunkenc metadata:

* **6 — TSDB read.** `chunkenc`'s metadata half is merged (§5e(c)), and **`bstream.go` + `xor.go` are
  now ported and PINNED** (§6a below). `EncXOR2` is what the gate's last 23 skips wait on, so it is the
  next piece and it closes Phase 5 too.
* **7 — TSDB write.** Head, WAL, compaction.
* **8 — ingest.** Scrape loop, relabelling, `convertnhcb` on the scrape path (which is where its
  `validate()` call finally earns its keep).
* **9 — the server.** HTTP API, and the five `index.html` substitutions for the prebuilt UI bundle.
* **10 — remote read/write, exemplars, OOO head, agent mode, perf.**

That is roughly 50k lines of Go and it is the bulk of the project; Phase 5 was ~15k. Nothing in 6-10 is
blocked by Phase 5.

### 6a. `bstream.go` + `xor.go` — LANDED and PINNED, and §5d's problem is solved

**`Bstream.swift` finally has a corpus.** It sat unmerged on `wip/phase6-bstream` for several sessions
because `bstream`, `bstreamReader` and `newBReader` are unexported, so the oracle could not call them —
§5d recorded that as an open problem. The answer is the one §5e(c) found for `appendable`: **pin the
exported behaviour the private code decides.** `NewXORChunk`/`Appender`/`Bytes`/`Iterator` are exported,
and an appended sample sequence has exactly one correct byte string, so comparing the bytes checks every
bit the stream wrote and iterating them back checks every bit it reads. 70 cases in
`Fixtures/chunkenc/xor.jsonl`.

**It found a real bug in `Bstream.swift` immediately** (quirk 116). `readBitsFast` computes
`(1 << nbits) - 1`; at `nbits == 64` Go's `0 - 1` wraps to the all-ones mask that was wanted and
Swift's traps. The decoder crashed on the 200-sample case while the encoder had written all 200
happily, because encoding never needs a 64-bit mask. A file with no caller and no fixture is a file with
unknown correctness, and this one said so in its own header.

Two more things worth knowing before touching XOR (quirks 117-119): `bitRange` is **asymmetric**
(`-8191...8192` for 14 bits, with a matching strictly-greater test on the way back), the sample count is
**stored** in two header bytes rather than derived, and `Appender()` on a non-empty chunk **replays the
whole chunk** to recover the encoder state — so the appender is defined by the decoder's final state.

`Scripts/controls-xor.sh` has 23 controls over both files; 21 break. The two survivors are `bstream`'s
copy of the final byte and `loadNextBuffer`'s `+8 <` boundary, and 23 append-while-reading cases were
added specifically to kill them and did not. That is the finding rather than a gap: an iterator's
`numTotal` is fixed at creation so it never reads the appended samples, and an append only fills the
free low bits of the final partial byte — so copy and live byte agree on every bit the reader consumes.
The copy prevents a **data race**, which has no defined value to compare against. Pinning it needs a
concurrent appender and querier, which is Phase 7's Head (quirk 120).

### 6b. `EncXOR2` — LANDED and PINNED

**183 differential cases, all matching byte for byte on the first run**, which is what the scoping below
bought: reading `Append`'s three fast paths and the ST header before writing anything meant no debug
cycles on a 991-line encoder with fused bit writes. `Sources/PromChunkEnc/XOR2Chunk.swift`, plus the XOR2
control-prefix readers that `Bstream.swift` deliberately deferred, plus `varbit.go` from §6c — **which
this corpus finally pins**, since ST deltas are its only route to one.

`Scripts/controls-xor2.sh` has 30 controls; 25 break. All five survivors have proofs recorded next to
them: the `0x7F` header guard is unreachable because `Append` forces the write at index 127 (and the
control for that forcing *does* break), `readSTHeader`'s `0x80` fast path returns what the general path
returns, `readDod`'s `w < 64` guard is a no-op because `1 << 64` is 0 in both languages,
set-versus-accumulate on the first ST delta is identical because `stDiff` is 0 there, and
`readXOR2ControlFast` only ever declines more often than it must.

**Two rounds of corpus gaps, both instructive.** First, the active-ST fast path needs ST to change at
sample **1** specifically — a change later goes through the slow path first, and every early case did
that. Second, and the better lesson: even with ST changing at sample 1, the fused ST buckets stayed
unreached because my cases stepped `st` by a constant while `t` stepped by 1000, so
`newStDiff = prevT - st` moved by ~1000 every sample and `deltaStDiff` never landed in an inlined bucket.
**The buckets need `st` to TRACK `t`** — `st = t - k` makes `deltaStDiff` exactly zero, and drifting `k`
puts it in the small buckets. Three controls survived on that alone.

The scoping that made it work is kept below, unchanged.

### 6d. `tsdb/index`'s postings algebra — LANDED and PINNED

**68 differential cases, and the first Phase 6 slice pinnable on its own** — `Intersect`, `Merge`,
`Without`, `ListPostings`, `BigEndianPostings` and the sentinels are all exported upstream, so the oracle
calls them directly. No container, no "pinned only via X" caveat. `Sources/PromIndex/Postings.swift`, plus
the loser tree in `GoCompat/GoLoserTree.swift` beside `GoHeap` and `GoSort`, for the same reason those are
there: the order it produces is observable.

**`MemPostings` is deliberately NOT in this slice.** That is the Head's in-memory index — locking,
`EnsureOrder`, `Delete`, `Stats` — and it belongs with the Head in Phase 7.

The corpus drives **scripts of iterator operations**, not just expansion, and that is the design decision
that mattered: `Seek` is idempotent, may not advance, and is called repeatedly with unchanged targets by
`Intersect`, so the contract lives in interleaved `next`/`seek` sequences. Expanding alone would have
pinned almost none of quirks 121-125.

`Scripts/controls-postings.sh` has 21 controls; 17 break. Four survive by proof, recorded beside them:
`Without`'s empty-drop short-circuit, and three that are equivalent-but-slower (`merge.seek` via
`tree.next` instead of `Fix`, `Without` stepping the drop side instead of seeking, and the tree's
tie-breaking, which `Merge`'s de-duplication hides).

**The harness itself needed fixing, and the lesson generalises.** A perturbation can make an iterator
NON-TERMINATING rather than wrong — `intersectPostings.Seek` loops until its target settles, so accepting
an equal value means it never does. With no timeout that hung the whole sweep for half an hour at
`=== Intersect ===` and reported nothing. The runner now backgrounds each test with a 120-second budget
and reports `broke (hung)`; three controls land there. **Every other `controls-*.sh` in this repo has the
same hole** — worth fixing the next time one is touched.

Two corpus gaps found by controls, both the same shape: the values were too small to distinguish anything.
`listPostings.Next` resetting `cur` to 0 on exhaustion is observable only through a *backwards* seek
afterwards, and the loser tree's `maxVal` only matters when a real ref approaches `UInt64.max` — every case
had refs under 1000, so a `maxVal` of 1000 still dominated them all.

### 6e. `tsdb/chunks/chunks.go`'s pure half — LANDED and PINNED

**46 differential cases across four fixture files.** `Sources/PromChunks/ChunkFormat.swift`: the two
reference layouts, the per-chunk framing, the checksum, and `WriteChunks`' segment-batching arithmetic.

**The file and segment I/O is deliberately NOT ported, and that is a decision rather than a gap.**
`Writer`, `cut`, `cutSegmentFile` and `NewDirReader` are built on `os.File`, a directory handle,
`fileutil.BufWriter` and mmap. Porting them needs a filesystem abstraction, and *choosing* one is an ADR:
whether the port takes a protocol (testable, and what `MemStorage` would want), `FileManager` directly, or
NIO's non-blocking file I/O changes every later TSDB slice. **Write that ADR before the next chunk-file
slice**, not during it.

What is here is everything about the format that is pure, and it is byte-exact without touching a disk:
the framing bytes, the CRC input, the ref packing, and the batching. Quirks 126-128 record the three
things a straight reading misses — the CRC covering the encoding and data but **not** the length prefix,
`NewBlockChunkRef` having no bounds check where `NewHeadChunkRef` panics, and the batching using the
**maximum** varint width so segments cut slightly early.

The batching is pinned the way a caller sees it: which segment each chunk's reference decodes to, and at
what offset. The oracle gets that by running the real `Writer` against a temporary directory; the port
computes it from `chunkWriteBatches` plus the framing widths, which is what the writer does as it goes.
So the arithmetic is pinned against a real file writer without the port needing one.

Two wire notes worth carrying: sample values travel as **hex bit patterns**, because `encoding/json`
panics outright on NaN — the louder cousin of the submatch corpus's silent U+FFFD substitution. And the
corpus is **four files rather than one**, because `Fixtures.check` decodes every line of a file with a
single `In`/`Out` pair; mixing shapes would need an id filter in shared test infrastructure, and four
files is the cheaper seam.

### 6f. ADR-15 and the index file's header, TOC and symbol table — LANDED

**The filesystem ADR is written** (`docs/DECISIONS.md` ADR-15). It was the thing §6e deferred, and it
decides for the whole TSDB: a narrow `PromFS` protocol with an in-memory implementation for corpora and a
`FileManager`-backed one for real use, modelled on the seam `Queryable` already provides. Three things it
deliberately excludes, each with a reason — **no `mmap`** (recorded as a documented exception, since
upstream can read a 512 MiB index without resident memory and the port cannot), no pre-allocation, and no
directory `Sync`.

**14 differential cases, and the corpus contains real index files.** `Sources/PromIndex/IndexReader.swift`
ports the header constants, `NewTOCFromByteSlice` and `Symbols` — all of which take a `ByteSlice`, so the
reading side needs no filesystem at all even before ADR-15 is implemented.

**The seam is the reusable part.** The oracle writes each index file with Go's own `index.Writer`, then
puts the file's BYTES in the fixture's *input*. The port parses them. So the reader is pinned against
upstream's serialiser without the port owning a writer — §6a's principle ("pin the exported behaviour")
applied to a whole file format. Note the bytes must be **input**: on the output side the port would be
comparing against itself, which is how the first version of this suite was wrong.

Quirks 129-130 record what a straight reading misses: the TOC lives at the END so a truncated file fails
there rather than at the magic header, and `Lookup`'s argument is a **byte offset in v1 and an ordinal in
v2** — with `ReverseLookup` mirroring the split. The sparse index records one offset per 32 symbols, and
its binary search must use **Go's byte ordering** (ADR-10) or it searches a differently-sorted array; the
corpus includes symbols where byte order and collation disagree.

One corpus-generation flaw worth the note: a case with a duplicated symbol made Go's *writer* fail
("out-of-order series added"), so no file existed for the port to parse and the fixture carried a writer
error the port could never produce. The generator de-duplicates the SERIES list now, while still feeding
the duplicates to `AddSymbol` so the symbol table case survives.

**Series records and the raw postings decoder are now in too** — 23 cases, same generator. Quirks 131-133
record what they cost:

* the chunk metas are **double-delta** encoded and the FIRST one is framed differently from the rest, so
  reading either with the other's framing decodes plausible nonsense rather than failing;
* the reference delta is **signed** — and `Writer.AddSeries` refuses to produce a decrease
  (`unsorted chunk reference`). So the signed delta is defensive, no written file exercises it, and the
  corpus case attempting one was *unwritable*. That asymmetry is the finding, and it is the sort of thing
  only trying to generate the case reveals;
* in format v2 a series ID is the byte position **divided by 16**, the same v1/v2 split as quirk 130 on a
  different field.

Two writer constraints came out of the same experiment and are worth having written down before the next
generator: chunk ranges must satisfy `mint > prev.maxt` **strictly**, and chunk references must increase
**globally across series**, not just within one.

**The postings offset table and `Reader.Postings` are in as well** — 26 cases now, all matching on the
first run, which included the 100-value sparse index, the "plus the last value" rule, queries below and
above the table's range, and unsorted query input. Quirks 134-137:

* the offset table is read **without checksum verification, on purpose** — a nil CRC table, with
  upstream's comment saying the full-table CRC is too slow. Every other `NewDecbufAt` in the file
  verifies, so a port that verifies here diverges on a corrupt file by erroring where upstream reads on;
* `traversePostingOffsets`' `skip` optimisation assumes the label NAME does not change, which is only true
  within one name's run — so the **callback protocol** (returning `false`, driven by comparing against the
  next sparse entry) is what keeps it correct, not a convenience;
* the sparse index keeps every name but only every 32nd value **plus the first and last of each name**, and
  the "last" is appended when the next name begins. Without it a lookup for a name's largest value
  traverses from the wrong place;
* `Reader.Postings` sorts its values with Go's byte ordering and walks the table forward **once**, because
  it cannot re-read backwards.

**`LabelValues`, `LabelNames` and `LabelNamesFor` are in too** — 28 cases. Quirks 138-140, and the first
is the one worth internalising:

* **quirks 135, 136 and 138 are one mechanism read three ways.** `LabelValues` walks until it sees the
  name's last value; it needs that sentinel because `traversePostingOffsets`' `skip` would mis-parse the
  next label name's entries; and the sparse index is built to always include each name's last value
  precisely so the sentinel exists. Change any one and the other two break — so treat them as a unit when
  touching the offset table;
* `LabelNames` **excludes the all-postings key** `("", "")`, which is how "every series" is stored and is
  not a real label. Returning the map's keys verbatim reports an empty-string label name;
* the same underlying failure reaches the caller with a **different prefix depending on which method
  asked** — `read series:` from `Reader.Series`, `get buffer for series:` from `LabelNamesFor`. Two cases
  caught the port double-wrapping.

### 6g. `PromFS` — LANDED (the protocol and the in-memory implementation)

`Sources/PromFS/PromFS.swift` implements ADR-15's seam: `PromFS`, `FSWriteHandle`, `FSReadHandle`, and
`InMemoryFS`. **`RealFS` (the `FileManager`-backed one) is not written yet** — nothing needs it until the
port has to read a directory a real Prometheus produced, and every corpus wants the in-memory one.

`PromFS` is NOT a port, so it has no differential corpus: there is no Go function to compare against.
`PromFSTests` is nine hand-written behavioural tests, which is the right shape here and is argued next to
them — the upstream behaviour that matters gets pinned where it belongs, in the index and chunk WRITERS
that will run on top, whose bytes are compared against Go's. A bug in `InMemoryFS` surfaces there as wrong
bytes.

Three of the tests assert things that look like nothing:

* `write(at:)` must **not** move the append position — Go's file offset and `FileWriter.Pos()` are
  separate, and `index.Writer` relies on it when it patches a length prefix and keeps appending;
* `sync` and `syncDirectory` **succeed without doing anything**, because ADR-15 declines durability.
  Asserting that stops a later reader "fixing" them;
* a reader **snapshots** the file at open, because ADR-15 declines mmap. That is a real divergence from
  upstream, where an appender's writes can become visible to an open reader — the same concurrency
  question quirk 120 raised for chunks — and asserting it keeps the divergence documented rather than
  incidental.

**One bug found, and it is a Swift trap worth knowing** (quirk 141): for `[String: [UInt8]?]`,
`files[k] = nil` REMOVES the key rather than storing a nil value, so "this path is a directory" created
nothing. Seven of nine tests failed with "no such file or directory" before it was spotted;
`updateValue(nil, forKey:)` is the spelling that stores.

### 6h. `chunks.Writer` — LANDED, and the port now writes real segment files

`Sources/PromChunks/ChunkWriter.swift`, on `PromFS`. **§6e's batch corpus is now a byte-for-byte comparison
of the writer itself**: Go writes real segment files to a temporary directory, the port writes to
`InMemoryFS`, and every segment's name and full contents are compared. When §6e wrote that suite it could
only check the batching arithmetic; ADR-15's seam is what upgraded it.

Quirks 142-144, and the first is the kind of thing only a differential corpus catches:

* **`BlockChunkRef`'s "file index" is a position in the writer's file LIST, not the segment's filename
  number** — `Writer.seq()` is `len(w.files) - 1`. The two coincide for any fresh directory, so the
  difference hides in exactly the case a test writes first. The port had it as the filename number and
  **all twelve cases disagreed on the ref while the segment bytes matched exactly**;
* a segment's name is the **maximum** parsable filename plus one, not the file count, and unparsable names
  are skipped (which is how a stray `.tmp` is tolerated);
* the header is 8 bytes with 3 of padding, and the padding is load-bearing because quirk 128's batching
  compares against `SegmentHeaderSize`.

Two places the port diverges from upstream's I/O, both deliberate and commented at the call site: there is
no rename (the port copies and removes, since `PromFS` cannot crash between the two and the observable
result is identical), and `finalizeTail`'s truncate is a no-op because ADR-15 declines pre-allocation.

### 6i. `index.Writer`'s meta, symbol and series stages — LANDED

`Sources/PromIndex/IndexWriter.swift`, on `PromFS`. The postings sections are NOT here — they need
`writePostingsToTmpFiles`' second file and a sort of every series — so the corpus does a **prefix
comparison**: the port rebuilds each `index/reader.jsonl` case's input and the bytes up to the end of the
series section are compared against Go's real file, along with the TOC offsets for the sections it wrote.
Reusing the reader suite's fixtures means the two cannot drift apart.

**This slice found the most dangerous bug of the session, and it is now ADR-10a.** ADR-10 says Go compares
strings by byte and Swift by collation; it is usually cited for *ordering*. The same divergence applies to
**equality and hashing**: `"e\u{301}" == "é"` is true in Swift and false in Go. `symbolCache` was
`[String: UInt32]`, mapping each symbol to the ordinal a series record stores — and with both spellings of
`é` in the table, one silently took the other's ordinal. **The file stayed structurally valid, every CRC
passed, and it decoded to the wrong labels.**

It would not have been found by review: every rendering of the failing input — the fixture's JSON, a
`print`, this document — shows the two symbols as the same character. What showed it was Go writing seven
symbols where the port wrote six. The same hazard first bit the *test harness* (a `Set<String>` collapsing
the two) and only then the port, which is worth knowing: the harness is as exposed as the code.

Rule going forward, per ADR-10a: **anywhere the port keys, de-duplicates or compares strings that
originate as Go bytes, use `[UInt8]`.**

**The postings sections landed too, so `IndexWriter` now writes a byte-identical WHOLE FILE** — every
section Go writes, and every TOC offset. The suite compares bytes rather than round-tripping, which matters:
a writer bug and a reader bug that cancelled out would pass a round-trip and fail this.

Quirks 145-148. Two are worth reading before touching the postings code:

* `writePostingsToTmpFiles` **re-reads the series section it just wrote** rather than keeping series in
  memory, so a posting's ordinal is a POSITION (`startPos/16`), not the `ref` the caller passed;
* the offsets in `fPO` are **relative to `fP`** and get `postingsStart` added as they are copied in. Get
  that adjustment wrong and every postings list is unreachable **while the file still passes every
  checksum** — no CRC covers an offset.

And the bug that cost the most time was neither: the offset table has **two** four-byte header fields, a
length placeholder (`"alen"`) and a BE32 count. I wrote the placeholder and dropped the count, so every file
was exactly four bytes short and the divergence appeared *at the offset table* rather than where the field
was missing. The lesson is the diagnostic one — "N bytes short, consistently" points at a dropped
fixed-width field, and the reported offset is where the shift becomes visible, not where it starts.

### 6j. `RealFS` — LANDED, and the property that makes the corpora mean something

`Sources/PromFS/RealFS.swift`, `FileManager`-backed. **Deliberately thin and deliberately barely tested**,
and the reason is worth stating: every corpus in the project drives `InMemoryFS`, so the byte-level behaviour
of both writers and both readers is already pinned against Go without `RealFS` existing. What is left for it
to get right is the *mapping onto the filesystem* — exactly the part a differential corpus cannot check — so
its tests are a handful of round trips in a temporary directory and stop there.

**One test carries the weight: `implementationsAgree`.** The same sequence of operations — append, pad,
`write(at:)`, pad again — is run through both implementations and the bytes, the final position and the
directory listing are compared. That is the property that makes a corpus passing on `InMemoryFS` say
something about a real directory. Without it the in-memory implementation could drift and every fixture
would still be green.

Two divergences from upstream stay documented rather than fixed: reads are **eager** (ADR-15 declines mmap,
so a 512 MiB index is fully resident, and a reader cannot observe an appender's writes — quirk 120's
question again), and `sync` is a no-op with `handle.synchronize()` left for a durability slice that has a
test able to observe it.

### 6k. `meta.json` and ULID — LANDED, byte for byte

`Sources/PromBlock/BlockMeta.swift`. A block's `meta.json` is the only JSON in the TSDB, which makes it the
only place `encoding/json`'s own behaviour is a compatibility surface — so the port emits it **by hand** and
25 corpus cases say whether that was right. Hint strings travel as hex, because they are where the escaping
cases live and a JSON string field would repair exactly what is under test.

Quirks 149-152. Two of them cost 24 of the 25 cases on the first run:

* **an empty object collapses to `{}`** on one line, so an all-zero-stats block contains `"stats": {}` with
  no inner newline — and that is the common case, not an edge one;
* **`omitempty` does not apply to structs, and `compaction.level` does not carry it.** The tag on `stats`
  reads as if an empty stats block would vanish; it never does. Inside `compaction`, `level` is bare while
  every other field carries `omitempty`. Pattern-matching the tags gets this wrong.

Also: `encoding/json` HTML-escapes `<`, `>` and `&` where `strconv.Quote` does not, so the pinned
`GoStrconv.quote` is the wrong tool for JSON (quirk 151); and a ULID's first character can never exceed `7`,
because 26 base32 characters hold 130 bits for a 128-bit value (quirk 152).

### 6l. `chunks.Reader` — LANDED

`Sources/PromChunks/ChunkReader.swift`. The last reader piece: a `BlockChunkRef` to a chunk's encoding and
bytes.

**Its corpus is `chunks/batch.jsonl`, which already holds Go's real segment files AND the refs Go's writer
assigned.** So the reader is checked against Go's files and Go's refs rather than against the port's own
writer — a writer bug and a reader bug cannot cancel out. The write-then-read path is checked separately,
because that is what a block actually does, but only after the against-Go direction passes.

Three details from the file header worth carrying: the segment list's **sorted order is the reference index
space** (quirk 142 from the reading side, and lexicographic order agrees with numeric only because the names
are zero-padded to six digits); there are **two bounds checks with different messages**, the first quoting the
MAXIMUM varint width because the real one is not yet known; and the CRC covers the encoding byte through the
data, **not** the length prefix (quirk 126 again).

One test-authoring note: the round-trip test first asserted a multi-segment layout it had not created — four
small chunks fit inside a 512-byte segment. A test that asserts a precondition it did not establish passes
for the wrong reason, and here it failed loudly instead, which is the better outcome.

**Next in Phase 6:** see §6m, which landed the `BlockReader` — and then the querier-shaped iterator API,
which is the last reading piece before Phase 7's Head. `MemPostings` waits for the Head in Phase 7.

**Previously next, now done:** `index.Writer` on the same seam — bigger than the chunk writer (a five-stage state
machine: symbols, series, label indices, postings, TOC) but pinnable identically, and §6f's reader corpus
already proves the port can read what Go writes, so a writer corpus closes the loop in both directions.
Then `RealFS`, thinly, and a `BlockReader` that ties the chunk and index readers together. `MemPostings`
waits for the Head in Phase 7.

A note for whoever writes the next generator: put anything the port cannot compute in the fixture's
**input**, not its output. The file bytes were on the output side first, which had the port comparing
against itself; `writtenRefs` repeated the mistake one commit later and was dropped rather than moved.

### 6m. `BlockReader` — LANDED, and why it is the one slice with NO new corpus

`Sources/PromBlock/BlockReader.swift`. Open a block directory, read `meta.json`, and join the index reader to
the chunk reader so a series resolves to its samples.

**This slice deliberately adds no oracle suite, and the reasoning is worth keeping** because it is the first
time in the project that "no new fixture" was the right answer rather than a shortcut. Every *format* the
block reader touches is already pinned from both directions: `index/batch.jsonl` says the index writer's bytes
are Go's bytes and the reader reads Go's files, `chunks/batch.jsonl` the same for chunks against Go's own
segment files and Go's own refs, `block/meta.jsonl` that `meta.json` marshals as `encoding/json` marshals it.
A `promoracle` suite that drove `tsdb.OpenBlock` would re-derive those and pin one genuinely new thing — the
directory layout — which is four string literals.

So what got written instead was (a) a round-trip test that writes a block with both writers and reopens it,
and (b) **a second use of the existing meta corpus, from the other end**: `readsBackWhatGoWrote` feeds Go's
own marshalled bytes into `BlockMeta(json:)` and requires the re-marshal to be identical. That is differential
without a new suite, and it is what actually earns confidence in the permissive parser, because all 25 of Go's
`omitempty` shapes — absent stats, absent `sources`, a `compaction` that is `{}`, an escaped hint — are cases
Go produced rather than cases someone thought to write. Six of the sweep's perturbations drop a field the
parser should keep, and every one of them is caught by that test alone.

**The parser is hand-written on the READING side too, and for the mirror of the encoder's reason** (quirk 154):
`json.Unmarshal` ignores unknown fields *and* defaults absent ones, and since `omitempty` means most real
`meta.json` files omit most fields, a `Codable` struct with non-optional properties would reject the very
files the encoder produces. The sweep pins leniency in **both** directions — one control adds a strict
unknown-field check and must break, six others drop a field and must break.

**The one hazard composition can actually introduce is quirk 142**, so the round-trip test uses a 256-byte
segment size to force a multi-segment block. A single-segment block has file index 0 everywhere and would pass
with the join wired to either meaning of "file index", which is the same class of mistake §6l's own test made
when it asserted a multi-segment layout it had not created.

Two argued survivors in `controls-block.sh`, both recorded there and in PORTING.md:

- **the chunk reader's `.sorted()` is redundant**, because both `PromFS` implementations already sort. The
  sweep proves which sort is load-bearing by removing them in a pair: remove either alone and nothing breaks,
  remove both and the file index means nothing. The `.sorted()` stays because `PromFS` is a protocol and a
  third implementation has not made that promise.
- **`toc.labelIndicesTable` and `toc.postingsTable` are the same offset** in every v2 index —
  `index.go:410-412` assigns both `w.f.pos` back to back with nothing between (quirk 155). Reading one at the
  other's offset is unobservable on any file Prometheus has written since v2, and not equivalent in general.

**Tombstones are not read, and that is exception 16 rather than a gap.** A block directory containing a
`tombstones` file still opens; its deletions are simply not applied. Porting `tsdb/tombstones` is a
prerequisite for `Delete()`, not for reading.

**Next in Phase 6:** the querier-shaped API — `blockQuerier`/`blockChunkSeriesSet`, so a block is reachable
through the `Querier` protocol the engine already uses instead of `BlockReader`'s convenience methods. That is
what makes `samples(_:)`'s XOR-only shortcut go away (it exists because chunk-encoding dispatch is the Head's
problem, Phase 7's) and what would let the promqltest gate run against a real block rather than `MemStorage`
— which would be the strongest single check the TSDB port can get, since the gate is 2,183 assertions wide.

### 6n. `PostingsForMatchers` — LANDED, on an exact seam

`Sources/PromBlock/PostingsForMatchers.swift`, plus `indexPostingsForLabelMatching` in the index reader,
which it needed and which did not exist. This is the function that turns a query's label matchers into a
postings list — where the TSDB's query planning actually lives.

**The seam is exact and needs no adapter, which is the best case this project has had.** `*index.Reader`
satisfies `tsdb.IndexReader` in full, so the oracle calls upstream's own exported `PostingsForMatchers`
against a real index file written by upstream's own `index.Writer`. No mock anywhere in the comparison — and
that matters more here than usual, because the function's hardest behaviours are about what the index does
NOT contain. A series with no `l` label has no posting under any value of `l`, and that absence is the entire
reason `labelMustBeSet` exists. 82 queries over ten files; the corpus records both the refs and the label
sets they resolve to, so a wrong answer names the series rather than just the count.

Two things worth carrying forward:

**`labelMustBeSet` is a per-NAME fact, not a per-matcher one.** A name is required when ANY matcher on it
rejects the empty string, which is what makes upstream's `{l=~".", l!="1"}` example work: `l=~"."` guarantees
`l` is present, so `l!="1"` becomes a cheap subtraction instead of "all postings except l=1". Keying the map
per matcher instead breaks that one optimisation and leaves *every single-matcher query correct* — the exact
shape a hand-written test passes and a corpus catches. It is a control, and it breaks.

**Quirk 156: upstream's matcher sort uses a comparator that never returns 0.** It works only because
`SortStableFunc` is stable; a Swift `sort(by:)` given the same predicate can trap on it. The port does a
stable partition, which is what the Go code means rather than what it says.

**Nine argued survivors, and the pattern is one finding (quirk 157):** upstream's four `.*`/`.+` cases and
both set-matching fast paths are *optimisations reachable by the general path*, so a corpus can pin the
answer but never the plan. Deleting the `l=~".*"` case entirely still passes. That survivor was not left as
analysis: the corpus was widened to ten same-name `.*` queries covering all four `labelMustBeSet` x isNot
quadrants, and it still survives — so the equivalence is evidence-backed. The genuinely semantic behaviours
all broke: the per-name keying, the isNot/matchesEmpty quadrants, `l=""`'s inverse walk (issue #3575), the
final intersect-then-subtract, and every perturbation of the traversal underneath.

`controls-pfm.sh` also carries a **deliberate no-op control** that must report SURVIVED. A sweep in which
everything breaks is indistinguishable from a sweep whose build is broken, and that control is what makes
the other SURVIVED verdicts mean anything. Worth copying into future sweeps.

**Next in Phase 6:** `blockBaseSeriesSet` and `blockChunkSeriesSet` — the iterator shape that turns a
postings list into series with samples, and with it `blockQuerier`. `PostingsForMatchers` was the piece those
need; what is left is `labelValuesWithMatchers`/`labelNamesWithMatchers` (thin, on top of this) and the
`populateWithDel*` iterators, whose tombstone half is exception 16's unported territory and whose chunk half
is where `BlockReader.samples(_:)`'s XOR-only shortcut finally goes away.

### 6o. `FindIntersectingPostings` — LANDED, and the session's most useful lesson

`Sources/PromIndex/FindIntersecting.swift`, plus `GoHeap.initialized` (Go's `heap.Init`, which the port did
not have). The question it answers is not "which series match" but **"which of these candidate lists have at
least one series in common with `p`"** — it returns INDEXES into `candidates`. That is what
`labelValuesWithMatchers` needs: one candidate list per label value, and the answer is which values survive.

Exported, so the corpus drives it directly. Two behaviours are worth carrying (quirk 158): the heap **never
actually pops** — `popIndex` marks the root and re-sinks it, because a real `heap.Pop` would box an
allocation per candidate — so `Len() > 0` does NOT mean non-empty, which upstream flags in a comment because
it is the wrong guess. And `heap.Init` rather than repeated pushes, because the heap's order is the order of
the returned slice.

**Read quirk 159 before adding to any corpus.** This slice is where the project learned that *a SURVIVED
control is a hypothesis, not a proof*:

- The first corpus had 32 cases covering what looked like every interesting shape — ties, reversed orders,
  shared values, heap sizes at every power of two.
- The control replacing `heap.Init` with a push loop **survived all 32**.
- The equivalence argument was easy to write and completely wrong: "the loop always seeks to the heap
  minimum, so pops happen in value order and layout cannot matter; ties compare equal both ways so no swap
  resolves them."
- A brute-force search — the two constructions side by side over 300k random inputs — found a divergence in
  **15 trials**. The shape: several candidates tying on their FIRST value, where the initial layout is the
  only tie-break there is. Three such cases are in the corpus now and the control breaks on all three.

So the rule for the rest of the port: when a perturbation is a *plausible alternative implementation* rather
than an obvious bug, treat a survivor as a corpus gap until a search says otherwise. The argued survivors
elsewhere in the sweeps are argued from **proofs about the data** — a superset intersection, an empty
subtraction, two offsets assigned the same value on adjacent lines — never from reasoning about order.
Reasoning about heap layouts, iteration orders and tie-breaks is exactly the kind that feels rigorous and is
not.

**Next in Phase 6:** `labelValuesWithMatchers` and `labelNamesWithMatchers`, which sit directly on top of
this and `PostingsForMatchers`. They are unexported, so the seam is `blockIndexReader.LabelValues` reached
through `NewBlockQuerier` — which needs a `tsdb.BlockReader`, and that interface is only five methods
(`Index`, `Chunks`, `Tombstones`, `Meta`, `Size`), all satisfiable in the oracle by delegation to
`index.Reader` + `chunks.Reader` + `tombstones.NewMemTombstones()`. **That adapter is the unlock for the rest
of `querier.go`**, including `blockQuerier.Select` and the `populateWithDel*` iterators — so write it once,
carefully, as its own step.

### 6b (scoping, retained). `EncXOR2` from the pinned source

Written the way §5c was for `matrixSelector`, because that plan was executed straight out of the doc.
**This is the slice that closes Phase 5's last 23 skips**, since `@st` lines in the `.test` files need
the start-timestamp-aware encoding.

**It is TWO files, not one, and the second is the surprise.** `xor2.go` is 991 lines and calls
`putVarbitIntFast`/`readVarbitInt` from `varbit.go` (263 lines) for every start-timestamp delta. Both
are unexported, so both are pinnable only through the same seam §6a used —
`NewXOR2Chunk`/`Appender`/`Bytes`/`Iterator`. `varbit.go` is also what `histogram.go` and
`float_histogram.go` need, so porting it here pays for the histogram chunks later.

Order: `varbit.go` first (it has no dependencies beyond `Bstream`), then `xor2.go` on top.
**`varbit.go` is now ported** — `Sources/PromChunkEnc/Varbit.swift`. Its verification status is honest
and partial, and §6c below says exactly what is and is not established.

#### The grammar, copied from the source comment so it is not re-derived

Control prefix for samples >= 2 — note it is a **joint** timestamp+value code, which is what makes XOR2
different from XOR rather than merely extended:

```
0     -> dod=0 AND value unchanged              (1 bit)
10    -> dod=0, value changed                   (2 bits, then a value field)
110   -> dod!=0, 13-bit signed [-4096, 4095]    (prefix+dod packed into 2 BYTES)
1110  -> dod!=0, 20-bit signed [-524288, 524287] (prefix+dod packed into 3 BYTES)
11110 -> dod!=0, 64-bit escape                  (5+64 bits, then a value field)
11111 -> dod=0, STALE NaN                       (5 bits, and NO value field at all)
```

The dod bins are widened *specifically so prefix+dod lands on a byte boundary*, which is why the 13-
and 20-bit cases are `writeByte` rather than `writeBits`. That is the same shape XOR's 14-bit case has
(quirk 117's neighbour) and it means the bin edges are **not** the ones a "smallest sufficient width"
reading would pick — `bitRange(dod, 13)` after a 3-bit prefix, not `bitRange(dod, 14)`.

Two value encodings, and which one applies depends on the prefix:

```
after a dod!=0 prefix:   0 unchanged | 10 reuse window | 110 new window | 111 stale NaN
after the dod=0 prefix:  0 reuse window | 1 new window          (value is known to have changed)
```

So **stale NaN is representable in two different places** — as a whole-sample prefix (`11111`) and as a
value code (`111`) — and which one is used depends on whether the timestamp also moved.

#### The ST header, which is the point of the encoding

One byte at `b[chunkHeaderSize]`, i.e. between the sample count and the data:

```
bit 7 (0x80): firstSTKnown    — an ST for the first sample is present in the stream
bits 6-0:     firstSTChangeOn — the sample INDEX at which the first ST change begins
```

`maxFirstSTChangeOn` is `0x7F`, and `writeHeaderFirstSTChangeOn` **silently returns** when the index
exceeds it rather than erroring — upstream's comment says "this should never happen, would cause
corruption". Reproduce the silent return; a port that throws diverges on a chunk that upstream would
write (badly) rather than reject.

`readSTHeader` has two fast paths before the mask (`0x00` and `0x80` exactly), which matter only for
speed but are worth keeping so the two implementations read alike.

When no ST is ever supplied the header stays `0x00` and **the chunk carries no ST bits at all** — so
an XOR2 chunk of ST-less samples is not an XOR chunk with a spare byte, it is a different byte string
with one extra byte. The `@st`-free assertions in the gate currently pass through `EncXOR`, so this
must not change them.

#### Four things read out of `Append` that the grammar comment does not tell you

Read after the scoping above, from `xor2.go:144-400`. These are the parts that will cost a day if
discovered during the port rather than before it.

**1. `Appender()` restores the bit position from the READER.** After replaying, it does:

```go
c.b.count = it.br.valid
```

`bstream.count` is free bits in the last byte and `bstreamReader.valid` is unread bits in the buffer —
different quantities with the same units, and XOR2 relies on them coinciding at end-of-stream. XOR's
appender needs no such line because its `Append` only ever writes whole bytes or bit-aligned runs from a
known state; XOR2's fused writes do not. **`Bstream.count` is `private(set)` in the port** (that is what
forced `putBigEndianUInt16(at:)` in §6a), so this needs a second named mutation — do not widen the
property.

**2. There are THREE encoding paths in `default`, not one, and they must agree bit for bit.**

* *no-ST fast path* — `firstSTChangeOn == 0 && st == a.st && numTotal != maxFirstSTChangeOn`. Inlines
  two cases (dod=0 with unchanged value; 13-bit dod with unchanged value) and returns EARLY, skipping
  the shared tail;
* *active-ST fast path* — `firstSTChangeOn > 0`. Same two cases, each **fusing the T/V trailing bit with
  the ST delta into one `writeBitsFast`** — so `0b10<<3 | ...` is written as **6** bits here and **5**
  bits in the `default` sub-case, because one of them carries the extra T/V zero bit. Getting that
  6-versus-5 wrong is a silent one-bit shift of everything after it;
* *full slow path* — `encodeJoint` then maybe an ST delta.

Each fast path duplicates `a.t`/`a.tDelta`/`numTotal` updates and its own header write before returning.
A port that factors them into one shared tail changes nothing *observable* — but only if every duplicated
line is reproduced exactly, and there are three copies of the `numTotal++` plus header rewrite.

**3. `numTotal == maxFirstSTChangeOn` forces the slow path even when nothing about ST changed.**
Upstream's comment: "Must use the slow path at maxFirstSTChangeOn so the header remains valid even if ST
changes on a later sample (index > maxFirstSTChangeOn)." So sample 127 is special *regardless of its
data*, and `st != a.st || a.numTotal == maxFirstSTChangeOn` is the condition that writes the header.
This is why §6b's corpus plan calls for ST first appearing across the `0x7F` boundary — that case is not
an edge case, it is a distinct branch.

**4. A stale NaN does NOT update `a.v`.** Every path guards with `if !value.IsStaleNaN(v) { a.v = v }`,
so the baseline value for the next XOR is the last *non-stale* value. The iterator mirrors this with a
separate `baselineV` field — which is why `Appender()` reads `it.baselineV` and not `it.val`. A port that
keeps one value field will encode correctly until the first stale sample and then diverge on every
sample after it.

#### How to pin it

Mirror `chunkenc/xor.jsonl`: append a sample sequence, compare `Bytes()` hex, `NumSamples`, the samples
read back, and the append-while-reading behaviour. Add on top of that:

* `AtST()` per sample, which is the whole reason the encoding exists;
* cases with **no** ST, ST constant from sample 0, ST first appearing at sample k for k across the
  0..0x7F boundary, and ST changing every sample;
* `firstSTChangeOn > 0x7F`, to pin the silent return;
* both stale-NaN paths, with the timestamp moving and not moving;
* the 13/20/64-bit dod bin edges, both signs, both sides — the same asymmetry trap as quirk 117.

`varbit.go` gets its own corpus through the same chunk seam: its buckets are exercised by ST deltas, so
a case per bucket edge (`val == 0`, then `bitRange(val, 3)`, and each widening branch) belongs in the
XOR2 corpus rather than in a separate one, since that is the only way to reach it.

#### 6c. `varbit.go`'s verification status, stated rather than implied

`Varbit.swift` is ported and **self-consistent, not yet differential**. All five functions are
unexported upstream, so the oracle cannot call them; they get pinned against Go through the first chunk
encoding that uses them, which is XOR2. `VarbitTests` is what can honestly be checked meanwhile, and it
is three different things with three different strengths:

1. **round-trip** over every bucket edge for both predicates — catches an encoder/decoder disagreement,
   says nothing about matching Go;
2. **`putVarbitInt` versus `putVarbitIntFast`**, bit for bit. This one has teeth: they are two
   independent implementations of one encoding, and the fast path folds prefix and payload into a single
   masked write, so a wrong mask or width shows up with no Go involved;
3. **encoded bit-LENGTH per bucket**, asserted against the widths Go's own case labels document (1, 5,
   9, 13, 17, 24, 32, 64, 72). A bucket edge off by one moves a value to the neighbouring bucket and
   changes its length, so this catches the signed/unsigned predicate confusion — `bitRange` is
   asymmetric (`-3...4` for the 3-bit bucket) where `bitRangeUint` is a plain fit (`0...7`). Sharing one
   predicate between them is wrong at every edge.

**What none of it catches** is a systematically wrong bucket table: if every prefix were a bit too long,
all three checks still pass. Only the XOR2 corpus can catch that, which is why §6b's plan calls for a
case per bucket edge. §6a is the precedent for taking this seriously — `Bstream.swift` was "transcribed
and reviewed line by line" and had a crashing bug the moment a corpus reached it.

#### What §6a already proved that applies here

* the `(1 << 64) - 1` trap (quirk 116) is in code XOR2 also calls — it is fixed, but any *new* mask
  arithmetic needs `&-`;
* `GoVarint.putUvarint`/`putVarint` **append**, they do not write into a pre-sized buffer. That cost a
  bug in §6a that was nearly invisible because the varint of `0` is `0x00`;
* the sample count is stored in the header and an iterator's `numTotal` is fixed at creation
  (quirk 118), so append-while-reading tests read only the pre-append samples;
* `Appender()` replays the whole chunk to recover encoder state (quirk 119). XOR2's replay has **more**
  state to recover — the ST bookkeeping, the bit position, and `baselineV` as well as the
  leading/trailing window — so the replay check in the corpus matters more here, not less.

#### Still to read before starting

`encodeJoint` (`:398`), `writeVDelta` (`:438`), `writeVDeltaKnownNonZero` (`:482`), and the decoder half:
`Next` (`:591`), `readDod` (`:740`), `decodeValue` (`:768`), `decodeValueKnownNonZero` (`:888`),
`decodeNewLeadingTrailing` (`:947`). Roughly 590 lines, and the two `KnownNonZero` variants exist because
the dod=0 path has already established that the value changed — so they encode one fewer control bit
than their general twins. That asymmetry is the decoder counterpart of the 6-versus-5 bit fusing above,
and it is the other place a one-bit shift can hide.

* ~~`histogram_quantile`'s monotonicity info does not fire~~ — **FIXED, and it was the RUNNER.** The
  info fired all along, with text matching to the character. The line scanner split on the first `#`
  *anywhere*, a guess at Go's `getLines` — which blanks a line only when it **starts** with `#` — so
  the expectation `… functions/#histogram_quantile` was truncated to `… functions/` and a correct
  answer was compared against a cut string. **A gate failure indicts the harness as readily as the
  engine**, and this one had been miscategorised as an engine finding for several commits.
* ~~`count_values` accepts an invalid UTF-8 label name~~ — **FIXED**, and it is the first piece of
  ADR-9 closed on the byte side rather than deferred. `ValidationScheme` now has a `[UInt8]`
  overload that checks UTF-8 validity properly (overlongs, surrogates, above U+10FFFF), and the
  caller validates `StringLiteral.val` instead of a decoded `String` — decoding substitutes U+FFFD,
  after which the check *cannot* fail. The pattern generalises to every remaining ADR-9 site:
  **validate on the bytes, decode afterwards.**

**The ~30 histogram failures are fixed, and the cause was the comparison rather than the port.**
test.go:1323 is `compareNativeHistogram(expected.H.Compact(0), actual.H.Compact(0), …)` — **both
sides are compacted before comparing.** Without it `histogram_mul_div * 0` fails: the file writes
`buckets:[0 0 0]` and the engine's answer is already compacted to nothing, so the spans differ while
the two `String()` renderings are identical.

Worth keeping the order in which that was established, because the cheap step came second:

1. the failure message was extended to print the fields `String()` omits — spans, `zeroThreshold`,
   `customValues`, the hint — which turned 30 opaque failures into one readable diff;
2. all-zero `Compact` cases were added to `histogram/float` (654 cases now), and **Go and the port
   already agreed** — which eliminated `compact` and `mul` as suspects in one regeneration;
3. only then was the comparison the obvious remaining place to look.

The corpus addition stays regardless: an all-zero histogram was a shape
`floatStructuralHistograms` never built, which is quirk 59's lesson in a third setting.

#### (b) was: `promqltest` — the exit gate, and do this one first

The runner turns the committed `.test` files into the assertion set Phase 5 is measured by. Its
patterns are already reproduced in `oracle/corpus.go`, and the testdata is already committed and
sha256-pinned.

Two things to get right at the start rather than retrofit:

1. **Give it a storage factory**, not a hard-wired `MemStorage`. Upstream's signature is
   `RunBuiltinTestsWithStorage(t, engine, newStorage func(testing.TB) storage.Storage)`, and it is
   how Phases 6-7 re-run the same assertions against the real Head for free.
2. **`promqltest` sets `EnableDelayedNameRemoval` true** (test.go:111) and
   `FloatChunkEncoding = chunkenc.EncXOR2` in its own `init()`. The first used to make the port
   throw; `cleanupMetricLabels` is **now ported** and `promql/exec` carries a `delayed` axis, so the
   runner can use the setting the exit gate needs. `EncXOR2` is still Phases 6-7's (quirk 36).

Expect the first run to fail widely and to be *informative*: the assertions carry exact
annotation text, which is already byte-exact (4,118 pinned cases), so a failure is a real
divergence rather than a formatting difference.

#### (c) `label_replace`, which is a `PromRegex` slice and not an evaluator one

`evalLabelJoin` landed in #49; `evalLabelReplace` is 20 lines of evaluator around two `regexp`
calls the port does not have:

```go
regex, err := regexp.Compile("^(?s:" + regexStr + ")$")   // anchored, DOTALL
indexes := regex.FindStringSubmatchIndex(srcVal)          // needs CAPTURE TRACKING
res := regex.ExpandString([]byte{}, repl, srcVal, indexes) // needs Go's template syntax
```

`Sources/PromRegex/RegexCompiler.swift`'s header says the Pike VM "is boolean-only and needs no
capture tracking. That is not a shortcut" — and it was right for `Matcher`, which asks a
language-membership question. `label_replace` asks a different question, so the note needs
revisiting rather than working around.

What that slice actually needs, in order:

1. **Capture slots on each thread.** `2 * (ncap + 1)` positions; the `capture` instruction writes
   the current position into slot `n`. The compiler already emits `capInst(cap << 1)` and
   `cap << 1 | 1` (RegexCompiler.swift:128-131), so the *program* is already capture-aware — only
   the simulation is not.
2. **Leftmost-first priority.** Go's non-POSIX `regexp` is leftmost-first, which a Pike VM gets by
   processing threads in priority order and **cutting off lower-priority threads when a match is
   found**. The current `matches` returns as soon as it reaches a `match` instruction, which is
   correct for a boolean answer and *not* enough to decide which submatch wins. This is the part
   to be careful about, and Go's own `TestFind`/`TestFindSubmatch` tables are the corpus.
3. **`Expand`'s template syntax** — `$1`, `$name`, `${1}`, `${name}`, `$$`, and the rule that a
   bare `$1x` parses the name as `1x` (so `${1}x` is needed to append a literal). Go's
   `extract`/`expand` in regexp.go, ~60 lines.

Do it as a `PromRegex` slice with its own corpus (`gocompat/regexp-submatch`, driven from Go's
`FindStringSubmatchIndex` over the existing 40,768-case pattern set), and land `evalLabelReplace`
on top in the same PR or the next. **Do not** shortcut it with `NSRegularExpression`: ADR-6 exists
because these patterns come from user queries and need linear-time matching.

### 5c. LANDED in #43/#44: `matrixSelector` / `matrixIterSlice`

**Kept as a record of what the scoping got right and wrong**, because §5e is written the same way.
Every trap it named was real and every one was hit. What it did *not* predict: the reachable
`extendFloats` panic (quirk 84), that the querier's hints hide the window boundaries so the tests
belong a level down (`MatrixIterSliceTests`), and that `FunctionCall` would have to become
`throws`. Scoping finds the traps in the code; it does not find the ones in the corpus.

Read once so the next session does not spend context re-deriving it. Everything it needs on the
Swift side already exists: `BufferedSeriesIterator` + `newBuffer` (PromStorage/Buffer.swift),
`StartTimestamps` (PromQL/Value.swift), `checkAndExpandSeriesSet` and `evalSeries` (#35).

**Functions:** `matrixSelector` (engine.go:2806) and `matrixIterSlice` (:2889), plus the
`MatrixSelector` and `SubqueryExpr` arms of `eval` and the `matrixArg` half of the `Call` arm.
Landing them makes all 82 ported `FunctionCalls` bodies reachable, which is the single biggest
unlock left in Phase 5.

**The traps, in the order they bite:**

1. The buffer's range is **not** the selector's range. `anchored` adds one `lookbackDelta` and
   moves `mint` back by it; `smoothed` adds **two** and moves `mint` back *and* `maxt` forward.
   `matrixMint`/`matrixMaxt` keep the originals, so the widened window feeds the buffer while the
   original bounds decide what the caller sees — the storage-side counterpart of quirk 68's
   `getTimeRangesForSelector`, and it must agree with it or a selector silently loses samples.
2. `matrixIterSlice` **reuses the caller's slices across steps**, and the retention logic is the
   subtle part: when the previous range overlaps, it drops the points at or before `mint` with a
   linear scan, decrements `currentSamples` by exactly that many, and then only appends points
   *after the last retained timestamp*. When it does not overlap it truncates to empty and
   decrements by the whole length. Getting the accounting wrong here is invisible on a single
   step — the same trap as quirk 75 — so the corpus needs a **range query**, or at least two
   evaluations sharing a buffer. **Range queries now exist** (`promql/exec-range`, 332 cases), so
   this is no longer a blocker: extend that suite's shape rather than inventing a new one, and
   note it already varies the step against the sample interval in both directions.
3. `startTimestamps` is truncated at the same drop point, or cleared with the floats. It is
   `nil` unless `useStartTimestamps` is on, so both settings need cases.
4. Histograms repeat the whole float branch with `HPoint.size` accounting rather than 1 —
   upstream's own `TODO(beorn7): Use generics?`.

**What the corpus has to contain,** on top of the shapes #35 already loads: a range query (so the
slice reuse actually runs), a step smaller than the range (overlapping windows), a step larger
than the range (no overlap), samples exactly on `mint` and `maxt`, `anchored` and `smoothed`
ranges, and `useStartTimestamps` both ways. Sample-limit boundaries per shape, as in #34.


## 6. Open decisions and risks

**`Labels` may need to become byte-backed (ADR-9).** Currently `String`-backed. **One instance is now
closed**: `ValidationScheme.isValidLabelName` has a `[UInt8]` overload, because a decoded `String` is
valid UTF-8 by construction and the check could not fail — `count_values("a\xc5z", …)` was accepted
where Go errors, and the exit gate found it. The pattern for the rest: **validate on the bytes,
decode afterwards.** The deciding moment for `Labels` itself is still Phase 8 (`PromTextParse`) — the first point where arbitrary bytes can enter from a scraped target.
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
2. `docs/PORTING.md` — the fidelity contract and its **fourteen documented exceptions**, plus 99 replicated Go quirks
3. `docs/DECISIONS.md` — ADRs 1–14, including the reasoning behind every awkward-looking choice
4. `docs/ROADMAP.md` — the ten phases and their exit gates
5. `CLAUDE.md` — conventions (cite the Go source in every file header, at the pin)

The exceptions in PORTING.md matter most. Each one is a place where "byte-exact" is deliberately not
true, with the reason. Do not silently fix them, and do not silently add to them.
