# swift-server-prometheus

[![CI](https://github.com/CharlieTLe/swift-server-prometheus/actions/workflows/ci.yml/badge.svg)](https://github.com/CharlieTLe/swift-server-prometheus/actions/workflows/ci.yml)

A source-level port of the [Prometheus](https://github.com/prometheus/prometheus) monitoring server
from Go to Swift, pinned to upstream **v3.13.2**.

> **Status: phases 0–6 of 10 complete; phase 7 in progress.** The query engine passes all 2,183 of
> upstream's `eval` assertions with zero failures and zero skips, and the TSDB **read** path is
> closed — a block Prometheus wrote can be opened, matched, selected, trimmed and read. Phase 7 is
> building the write path: the WAL round-trips and rejects corruption, and the Head can hold series
> and cut chunks, but `headAppender`, `compact.go` and `db.go` are outstanding, so **the port cannot
> yet produce a block outside a test**. There is no server, no scrape/ingest and no remote
> read/write. ~58k of a projected ~85k lines of Swift. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Why this exists

Prometheus is ~335k lines of non-test Go. Porting it is only meaningful if the result is
*verifiably* the same, so the project's organising constraint is **byte-exactness**: on-disk formats
identical, PromQL results identical bit-for-bit, error strings identical. That constraint is what
drives nearly every design decision here — see [docs/PORTING.md](docs/PORTING.md) for the contract
(including its deliberate exceptions) and [docs/DECISIONS.md](docs/DECISIONS.md) for the ADRs.

**Picking this up mid-project?** [docs/HANDOFF.md](docs/HANDOFF.md) has the current state, the PR
workflow, the traps that have already cost time, and exactly what to do next.

## How correctness is defined

Not by hand-written expectations. `oracle/` is a separate Go module (~30k lines) that runs the pinned
Prometheus and Go toolchains and emits golden fixtures; `Fixtures/` holds **339,801 committed fixture
lines** across 144 JSONL files, sha256-pinned in `MANIFEST.json`. `swift test` reads those and needs
no Go toolchain.

```sh
swift test                      # hermetic: reads committed Fixtures/
./Scripts/regen-fixtures.sh     # needs Go + the pinned upstream worktree
./Scripts/verify-fixtures.sh    # regenerate and diff — catches upstream drift
```

Adding a new byte-exact surface means adding an oracle subcommand and a fixture file, not writing
expected values by hand. Two practices have been added to that rig as the port reached code with no
exported entry point and no upstream test corpus:

- **Negative-control sweeps.** `Scripts/controls-*.sh` (30 of them, one per slice) each perturb one
  behaviour of the slice at a time, rebuild, run the relevant suites and restore the file, reporting
  `broke` / `SURVIVED`. A corpus that nothing can break is not measuring anything. A *survivor* is a
  hypothesis, not a proof — HANDOFF records the four distinct reasons one can survive.
- **Committed probe packages.** Much of TSDB's interesting logic is unexported Go. Where a file's
  dependencies are all exported packages, it is lifted into its own Go package under `oracle/probe/`
  and **committed** (e.g. `oracle/probe/headmemseries`), so `verify-fixtures.sh` re-runs it on every
  upstream-pin bump rather than verifying the port exactly once.

`Fixtures/promql/testdata/` holds the 21 upstream PromQL conformance files verbatim. They were the
acceptance gate for the query engine, and the reason the roadmap does PromQL before the storage
engine: it is the only half of Prometheus that ships a portable oracle. TSDB's own oracle is 68k
lines of Go *test code*, which does not port at all — hence the fixtures, probes and control sweeps
above.

## What works today

632 tests in 149 suites across 24 test targets, green on Swift 6.4 (Xcode 27) and on the Swift 6.1
floor.

### Foundations

| Module | Verified against Go |
|---|---|
| `GoCompat` | `strconv` (`FormatFloat` `f/e/E/g/G`, `ParseFloat`, `ParseInt`/`ParseUint`, `Quote`/`Unquote`), `encoding/binary` + `dennwc/varint`, `time.Duration.String`, the `time` calendar, `math` (trig, hyperbolic, `Exp`, `Pow`, `Log`), `sort`'s pdqsort, natural sort, `container/heap`, the loser tree, `context` |
| `PromHash` | xxhash64, CRC-32C |
| `PromMath` | Kahan–Neumaier summation (bit-exact), `almost.Equal` |
| `PromModel` | `StaleNaN` payloads, label/metric-name validation |
| `PromLabels` | packed encoding, `Hash`/`StableHash`, ordering, `String()`, `Builder`/`ScratchBuilder`, `Matcher`, OpenMetrics floats |
| `PromRegex` | RE2: `regexp/syntax` parser, `Simplify`, compiler, Pike VM with capture tracking, `FastRegexMatcher` |
| `PromEncoding` | `ByteSlice`, `Encbuf`, `Decbuf` |
| `PromHistogram` | native histograms, integer and float: `Add`/`Sub`/`Mul`/`Div`/`KahanAdd`/`Compact`/`DetectReset`/`ToFloat`/`Validate`/`Equals`/`CopyTo`/`ReduceResolution`, `TrimBuckets`, `convert.go` |
| `PromSchema`, `PromConvertNHCB`, `PromAnnotations`, `PromPosRange` | `prometheus/schema`, `util/convertnhcb`, `util/annotations`, `promql/parser/posrange` |

### PromQL

| Module | Ported surface |
|---|---|
| `PromQLParser` | lexer ported 1:1; hand-written precedence-climbing parser replacing goyacc; `ast.go`, `printer.go`, `prettier.go`, `model.Duration`, `strutil.Unquote`. 6,154 parse cases across six option sets — AST JSON, every error message and `PositionRange`, `String()`, `Prettify()`, `Tree()`, and `parse(print(parse(x))) == parse(x)` |
| `PromQL` | the engine: instant and range queries, vector and matrix selectors, all 13 aggregation operators, the vector binary operators, subqueries, step-invariant duplication, and all 82 `FunctionCalls` entries that have a body. Plus `value.go`, `quantile.go`, `durations.go`, `PreprocessExpr`, `histogram_stats_iterator.go`, `info.go` |
| `PromQLTest` | the `promqltest` runner and its directives — **2,183 of 2,183 `eval` assertions, zero failures, zero skips** |
| `PromStorage`, `PromTestStorage` | the storage protocols, merge and sample iterators; an in-memory `Queryable` whose contract is itself pinned against a real `tsdb.DB` |

### TSDB

| Module | Ported surface |
|---|---|
| `PromChunkEnc` | `chunkenc` in full: `bstream`, `xor.go`, `xor2.go`, `varbit.go`, the histogram chunks, `appendable` and the chunk-cut/header rules |
| `PromChunks` | `tsdb/chunks`: `Writer`/`Reader` producing byte-identical chunk files, and `ChunkDiskMapper` — the Head's chunk files, both directions |
| `PromIndex` | the index **reader and writer** (byte-identical index files), the postings algebra, `FindIntersectingPostings`, `MemPostings` |
| `PromBlock` | `BlockReader`, `meta.json` + `ULID`, `PostingsForMatchers`, the label queries with matchers, `DeletedIterator`, both `populateWithDel*` iterators, `blockBaseSeriesSet`, both queriers |
| `PromTombstones`, `PromFS` | deletion-interval arithmetic and `Stone`; the filesystem layer (ADR-15) |
| `PromRecord` | `tsdb/record` in full — the WAL wire format both directions: Series, Samples V1 **and V2**, Metadata, Tombstones, Exemplars, MmapMarkers, and integer/float histograms in V1, V2 and custom-buckets flavours |
| `PromWAL` | `tsdb/wlog`'s segment format: 32 KB page framing, the `[type\|flags][BE16 length][BE32 CRC-32C]` fragment header, `WL`, `Reader`, `SegmentBufReader` — plus a corruption corpus that pins every rejection path. Uncompressed only |
| `PromHead` | **in progress**: `isolation.go`, `seriesHashmap`/`stripeSeries`, `memSeries`' in-order chunk state (all four of upstream's cut rules), `HeadOptions`/`NewHead`. `headAppender`, `head_read.go` and `head_wal.go` are next |

### Two divergences worth knowing about

`PromRegex` is a real RE2, not a wrapper. `NSRegularExpression` is backtracking ICU where Go is RE2 —
that diverges on pathological patterns *and* is a denial-of-service surface, since these patterns
arrive verbatim from user queries. Matching is an NFA simulation: linear in (pattern × input), no
backtracking.

Float formatting cleared 4.8M differential cases with zero mismatches. Swift's `Double.description`
does **not** match Go's `strconv` — that divergence reaches PromQL output, `labels.String()` and the
HTTP API, so ported code must never use it (ADR-4).

## Building

Requires Swift 6.1+ (developed on 6.4, macOS arm64). There are still **no external dependencies**;
swift-server packages (NIO, Hummingbird, ServiceLifecycle, …) arrive with the phases that need them.

```sh
swift build && swift test
```

To regenerate fixtures you also need Go 1.25+ (what CI uses) and the pinned upstream worktree — a
plain clone tracks `main`, hundreds of commits ahead of the tag:

```sh
git clone https://github.com/prometheus/prometheus.git ../../prometheus/prometheus
git -C ../../prometheus/prometheus worktree add ../prometheus-v3.13.2 v3.13.2
```

## Contributing

`main` is protected: every change goes through a PR that passes three checks (`Xcode 27`,
`Swift 6.1 floor`, `Verify fixtures against Go`). Reviews are not required — merge your own PR once
it is green. Generated files (`Sources/*/Generated/`, `Fixtures/`) are never hand-edited; regenerate
them with `Scripts/regen-tables.sh` and `Scripts/regen-fixtures.sh`.

## Licensing

Apache 2.0, matching upstream. This is a derivative work of three differently-licensed sources —
Prometheus (Apache 2.0), the Go standard library (BSD 3-Clause), and cespare/xxhash (MIT). See
[NOTICE](NOTICE); every ported file names its origin in a header comment.

Not affiliated with the Prometheus project or the [swift-server](https://github.com/swift-server)
organisation.
