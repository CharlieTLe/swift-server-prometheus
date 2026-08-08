# Prometheus (Swift port) — working conventions

A port of Prometheus from Go to Swift. Read `docs/PORTING.md` (fidelity contract),
`docs/ROADMAP.md` (phases), `docs/DECISIONS.md` (ADRs) before making changes.

## The upstream reference

Port against the **pinned worktree**, never the moving `main`:

```sh
# Sibling of this repo, created once:
git -C ../../prometheus/prometheus worktree add ../prometheus-v3.13.2 v3.13.2
# -> ../../prometheus/prometheus-v3.13.2   (v3.13.2 = bb5dff00c)
```

A plain clone of `prometheus/prometheus` tracks `main`, hundreds of commits ahead of the tag, and its
`VERSION` file still says `3.13.2`. Do not read it for porting decisions.

## Conventions

**Cite the source.** Every ported file starts with a header naming its Go origin:

```swift
//===----------------------------------------------------------------------===//
// Ported from model/labels/labels_stringlabels.go @ v3.13.2
//===----------------------------------------------------------------------===//
```

When a Swift function's logic is non-obviously driven by Go's behaviour, cite the line:
`// labels_stringlabels.go:91 — Hash() is over the packed data, not 0xFF-framed.`

**Never format a float with Swift's defaults.** `Double.description`, `"\(x)"` and
`String(describing:)` do not match Go's `strconv`. Use `GoFloat.format`. See ADR-4.

**Byte-exactness beats idiom.** When a Swift-idiomatic rewrite would change output bytes, ordering,
or an error string, keep Go's shape and add a comment saying why. Divergence must be a decision
recorded in `docs/PORTING.md`, never an accident.

**Preserve `Copy`/`CopyTo` call sites** when porting the engine, even though we drop `sync.Pool` —
some code depends on copy-vs-alias semantics of reused histogram pointers. See PORTING.md §4.

**Errors carry contract strings.** Model errors as enums whose `description` reproduces Go's message
byte-for-byte, including any `(line:col)` suffix. Do not assemble messages ad hoc.

## Verification

Correctness is defined by differential testing against Go, not by hand-written expectations.

```
oracle/       Go module (separate from the Swift build) — `promoracle <cmd>`, JSONL in/out
Fixtures/     committed golden JSONL + verbatim upstream testdata, sha256-pinned in MANIFEST.json
Scripts/      regen-fixtures.sh · verify-fixtures.sh · sync-testdata.sh · fuzz-diff.sh
```

- `swift test` is **hermetic** — it reads committed `Fixtures/` and needs no Go toolchain.
- `Scripts/verify-fixtures.sh` regenerates with the oracle and diffs against the committed copies;
  run it in CI where Go is available, and on every upstream-pin bump.
- Adding a new byte-exact surface means adding an oracle subcommand and a fixture file, not writing
  expected values by hand.
- Fixture tests **batch-report**: collect all mismatches and show the first 20 plus a count. Never
  stop at the first failure — corpora run to millions of cases.
