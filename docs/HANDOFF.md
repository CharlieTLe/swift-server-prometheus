# Handoff

Written at the end of the session that landed Phase 5's storage-protocol substrate.
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
| 5 — engine + storage protocols | **in progress** — protocols landed, evaluator next |
| 6–10 | not started |

Green as of this commit: **182,670 committed differential cases, 251 tests**, on both Swift 6.4
(Xcode 27) and the Swift 6.1 floor.

```
Sources/            src     generated
  GoCompat          2,264       193
  PromHash            216         –
  PromMath             91         –
  PromModel           357         –
  PromLabels          798         –
  PromEncoding        343         –
  PromRegex         3,312     3,974
  PromHistogram     4,125       163
  PromPosRange         51         –
  PromAnnotations     609         –
  PromChunkEnc        274         –
  PromChunks           61         –
  PromStorage         503         –
  PromQLParser      5,948       550
Tests               5,670
oracle (Go)         7,003
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

When a fixture disagrees with you, **check Go before changing the implementation.** Write a five-line
Go program in `/tmp` and run it. That habit is the highest-leverage thing in this repo.

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
pair of types, so mixing shapes fails on decode rather than on comparison. Two suites in this phase
were split for that reason (`promql/timestamp-floatsec`, `chunkenc/{encoding,valuetype,compatible}`).

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
| `PromChunks` | `tsdb/chunks/chunks.go` | `Meta`, `ChunkRef`, `ChunkMetaIterator` only |
| `PromStorage` | `storage/interface.go`, `errors.go`, `noop.go` | **query side only** |
| `GoCompat.GoTime` | `time` | ADR-14 |
| `GoCompat.GoContext` | `context` | ADR-13 |
| `PromModel.Timestamp` | `model/timestamp` | |
| `PromQLParser.Statements` | `ast.go` | `EvalStmt`, `TestStmt` |

`VectorSelector` now has its `unexpandedSeriesSet` and `series` fields, so ADR-11's mutate-in-place
design is finally exercisable.

**`posrange` had to become its own target.** Go's chain is
`promql/parser -> storage -> util/annotations -> promql/parser/posrange`, and upstream keeps
`posrange` a separate package precisely to break that cycle. Phase 4 folded it into `PromQLParser`,
which made the module graph circular the moment `storage` appeared. If you add a target under
`PromStorage`, check the direction of this edge first.

### What Phase 5 still has to bring, in order

1. **`storage`'s concrete iterators** — `series.go`, `generic.go`, `buffer.go`
   (`BufferedSeriesIterator` + `sampleRing`), `memoized_iterator.go`, `lazy.go`. `lazy.go` was
   deliberately deferred because it is written against `genericSeriesSet` from `generic.go`. The
   engine needs `storage.NewBuffer` and `NewMemoizedIterator` specifically (engine.go:1732, 2240,
   2829, 2890). **These have real logic and want differential iterator-trace fixtures**, not just
   message pinning — that is the next PR.
2. **`promql/value.go`** — `Vector`, `Matrix`, `Scalar`, `Sample`, `HPoint`/`FPoint`.
3. **`promql/engine.go`** and **`promql/functions.go`** — the evaluator and ~100 function bodies.
4. **`promql/promqltest`** — the `.test` file runner, which is what turns the committed testdata into
   the exit gate. Its patterns are already reproduced in `oracle/corpus.go`.

The exit gate is unchanged and is the one that matters most in the whole project: **all 2,201 `eval`
assertions in `Fixtures/promql/testdata/` green**. That is the shippable-library milestone.

### Deliberately not ported yet, so you do not go looking for them

Each is deferred to the phase that first has a caller, and each is noted in the file that would hold
it:

- `storage`'s **append side** — `Appender`, `AppendableV2`, and the exemplar/metadata/start-timestamp
  appenders (`interface_append.go`) → Phases 6–7, with the Head.
- `Storage`, `ExemplarStorage`, `SampleAndChunkQueryable` → Phase 6.
- `Searcher`, `SearchResultSet`, `SearchHints`, `Filter`, `Ordering` → Phase 9. Nothing in the engine
  or TSDB reads them. Note when you do port them: `noopQuerier`'s search methods return a **nil**
  `SearchResultSet`, so any caller reaching them panics.
- `merge.go`, `fanout.go`, `secondary.go` → Phase 6, when there is more than one querier to merge.
- `chunkenc`'s concrete encodings (XOR, XOR2, histogram, float histogram) and the bstream/varbit
  machinery → Phases 6–7. `PromChunkEnc` currently has no conforming `Chunk` at all.
- `context.WithValue` → Phase 9, for the query logger's `QueryOrigin`.

### What is already worked out for you

**The parser gives the engine everything it needs.** In particular `preprocessExpr`'s mutations are
plain field assignments, which is the whole reason ADR-11 chose classes. Do not "modernise" the AST
into an enum without reading that ADR first.

**`checkAST` already runs at parse time**, so the engine can assume types are correct.

**Annotation messages are already byte-exact and pinned** — 4,118 per-annotation cases plus 19
collection cases. This matters because `promqltest` asserts them verbatim, so it removes a whole
class of exit-gate failure from the evaluator work. Two divergences are documented rather than fixed:
`Annotations` iteration order (Go's is a random map) and `HistogramOperation`'s unreachable
"unknown operation" default. PORTING.md exceptions 7 and 8.

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
2. `docs/PORTING.md` — the fidelity contract and its **eight documented exceptions**
3. `docs/DECISIONS.md` — ADRs 1–14, including the reasoning behind every awkward-looking choice
4. `docs/ROADMAP.md` — the ten phases and their exit gates
5. `CLAUDE.md` — conventions (cite the Go source in every file header, at the pin)

The exceptions in PORTING.md matter most. Each one is a place where "byte-exact" is deliberately not
true, with the reason. Do not silently fix them, and do not silently add to them.
