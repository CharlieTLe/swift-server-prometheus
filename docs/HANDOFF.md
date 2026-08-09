# Handoff

Written at the end of the session that completed Phases 0–2 and the foundation of Phase 3.
Read `README.md` first for what the project is, then this for how to continue it.

---

## 1. Where things stand

| Phase | State |
|---|---|
| 0 — pin upstream | done |
| 1 — foundations + verification rig | done |
| 2 — `PromRegex` (RE2) | done |
| 3 — native histograms | done |
| 4–10 | not started |

Green as of this commit: **164,548 committed differential cases, 178 tests**, on both Swift 6.4
(Xcode 27) and the Swift 6.1 floor.

```
Sources/            src     generated
  GoCompat          1,567       193
  PromHash            216         –
  PromMath             91         –
  PromModel           104         –
  PromLabels          797         –
  PromEncoding        343         –
  PromRegex         3,312     3,974
  PromHistogram     4,125       163
Tests               3,574
oracle (Go)         4,631
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

When a fixture disagrees with you, **check Go before changing the implementation.** Write a five-line
Go program in `/tmp` and run it. That habit is the highest-leverage thing in this repo.

Fixture tests **batch-report** — collect all mismatches, show the first 20 and a count. Never stop at
the first failure; corpora run to tens of thousands of cases.

---

## 4. Traps that have already cost time

**Empty directories.** Git does not track them. A `.testTarget` whose directory exists only on your
machine builds locally and fails on a clean clone. This broke CI once (#1).

**CI runs an older Swift than you develop on, deliberately.** Wide chained shift-or/XOR expressions
compile on 6.4 and blow the Swift 6.1 type checker's budget. Write byte assembly as **loops or
stepwise statements**, never as one long chain. Phases 6–7 (`chunkenc` bstream, varbit, XOR encodings)
are almost entirely bit twiddling — this will bite again. Do not "simplify" the Swift 6.1 floor job
away; it exists because it caught a whole class of bug.

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

**ADR-9 keeps resurfacing.** A Go `string` is arbitrary bytes; a Swift `String` is valid UTF-8. Three
separate times a fixture "failure" was actually the harness decoding hex through
`String(decoding:as:)` and silently substituting U+FFFD. When a surface can carry arbitrary bytes,
the primitive must take `[UInt8]` and the `String` form must wrap it. **This is still an open
architectural question for `Labels`** — see §6.

---

## 5. What to do next: Phase 4

**Phase 3 is done.** `model/histogram` is fully ported — the generic layer, the integer `Histogram`,
`FloatHistogram` in all six slices, and `convert.go`. Twelve oracle suites cover it, and the phase
gate (field-by-field bit-pattern parity on `Add`, `Sub`, `Mul`, `Div`, `KahanAdd`, `Compact`,
`DetectReset`, `ToFloat`, `Validate`, `Equals`, `CopyTo`, `ReduceResolution`) is met.

Next is **Phase 4 — PromQL parser**, then Phase 5's engine. `docs/ROADMAP.md` has the phase list and
the argument for why PromQL comes before TSDB.

Two things from Phase 3 that will matter immediately in Phases 4–5:

- **`FloatHistogram.testExpression()` must round-trip with the parser.** It emits the
  `{{schema:0 sum:5 count:4 buckets:[1 2 1]}}` DSL that the conformance `.test` files are written in.
  It is pinned against Go over 650 histograms, so if the parser disagrees, the parser is wrong.
- **Fused multiply-add is a correctness issue, not an optimisation.** See PORTING.md "Replicated Go
  quirks" #0. Phase 5 is nothing but float arithmetic, and this bit us twice in Phase 3 — once for
  61 ULP. When porting an expression of the form `a + b*c`, disassemble the Go and check.

### What Phase 3 left behind, for reference

| file | suites |
|---|---|
| `generic.go` | `histogram/bounds` |
| `histogram.go` | `histogram/integer`, `-compact`, `-reduce`, `-validate`, `-equals` |
| `float_histogram.go` | `histogram/float`, `-copytoschema`, `-equals`, `-scale`, `-add`, `-kahanadd`, `-reduce`, `-detectreset`, `-trim` |
| `convert.go` | `histogram/nhcb-classic` |
| Go's `math.Log2` | `gocompat/log2` |

`GoMath` (in `GoCompat`) exists because Go implements `Log`, `Log2` and `Frexp` itself rather than
calling libm, and the platform libm disagrees on 43 of 2,350 values — including exact exponential
bucket boundaries. Do not "simplify" it into a libm call.

---

## 6. Open decisions and risks

**`Labels` may need to become byte-backed (ADR-9).** Currently `String`-backed. The deciding moment is
Phase 8 (`PromTextParse`) — the first point where arbitrary bytes can enter from a scraped target.
Decide deliberately then: byte-backed `Labels` (`ContiguousArray<UInt8>` + offsets), or validate and
reject at ingest. Do not let whichever code is written first settle it by accident.

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
2. `docs/PORTING.md` — the fidelity contract and its **six documented exceptions**
3. `docs/DECISIONS.md` — ADRs 1–10, including the reasoning behind every awkward-looking choice
4. `docs/ROADMAP.md` — the ten phases and their exit gates
5. `CLAUDE.md` — conventions (cite the Go source in every file header, at the pin)

The exceptions in PORTING.md matter most. Each one is a place where "byte-exact" is deliberately not
true, with the reason. Do not silently fix them, and do not silently add to them.
