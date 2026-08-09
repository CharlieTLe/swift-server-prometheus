# Roadmap

Full-server port of Prometheus v3.13.2 to Swift. Expected output ≈ 85k lines of Swift plus ~3k lines
of Go test-oracle harness. See `PORTING.md` for the fidelity contract, `DECISIONS.md` for ADRs.

## Why PromQL before TSDB

TSDB is larger and its formats look scarier, but PromQL is the higher-risk half and the only half
that ships with a portable oracle.

1. **Verification asymmetry.** PromQL's oracle is 2,201 `eval` assertions across 21 plain-text files
   (`promql/promqltest/testdata/`, 11,745 lines) that copy over verbatim. TSDB's oracle is 68,150
   lines of *Go test code* that does not port at all — TSDB-first means inventing a test suite first.
2. **The storage seam is narrow.** `promql/engine.go` needs only `Queryable`, `Querier`, `SeriesSet`,
   `Series`, `SelectHints`, plus `NewBuffer`/`NewMemoizedIterator` — satisfiable by ~800 lines of
   in-memory storage. **PromQL does not need TSDB.** The converse is false.
3. **Risk profile.** TSDB failures are loud (CRC mismatch, bad magic, decode overrun). PromQL
   failures are silent (a wrong Kahan compensation term, an off-by-one in `rate()` extrapolation, a
   NaN that should have gone through `almost.Equal`). Front-load silent failure.
4. **TSDB gets a free gate later.** Phase 6/7 exit criteria include "swap in the real Head, re-run
   the same 2,201 evals" — a TSDB integration suite at zero marginal cost.
5. PromQL over a protocol is independently shippable; a TSDB with no engine is not.

## Phases

| # | Goal | Swift LOC | Exit gate (all vs Go) |
|---|---|---|---|
| 0 | Pin upstream to a read-only `v3.13.2` worktree | — | `git describe` = `v0.313.2`; `st.go` absent |
| **1** ✅ | **Foundations + verification rig.** `GoCompat`, `PromHash`, `PromMath`, `PromModel`, `PromLabels`, `PromEncoding`, the `oracle/` Go harness, `Fixtures/` | 6.1k (+1.4k Go) | **DONE** — 17 suites / ~70k committed cases green on Swift 6.1 and 6.4; `verify-fixtures.sh` green and proven to detect drift. Regex is stubbed (ADR-6), so `Matcher` regex parity is deferred to Phase 2 |
| **2** ✅ | **`PromRegex` — RE2 in Swift.** Parser, Simplify, compiler, Pike VM, FastRegexMatcher | 3.4k | **DONE** — 4,221 parse cases (tree + exact error text), 40,768 MatchString cases, 675 SetMatches cases, all green. `Matcher` now uses it; the literal-only stand-in is gone |
| **3** ✅ | **`PromHistogram` — native histograms** | 4.5k | **DONE** — 12 suites; field-by-field bit-pattern parity on `Add/Sub/Mul/Div/KahanAdd/Compact/DetectReset/ToFloat/Validate/Equals/CopyTo/ReduceResolution`, plus `TrimBuckets` and `convert.go` |
| **4** ✅ | **`PromQLParser` — lexer ported 1:1, hand-written precedence-climbing parser replacing goyacc.** Plus `ast.go`, `printer.go`, `prettier.go`, `model.Duration` and `strutil.Unquote` | 5.9k | **DONE** — 6,154 parse cases across six option sets: AST JSON via `translate_ast.go`, every error message and `PositionRange`, `String()`, `Prettify()`, `Tree()`, and `parse(print(parse(x))) == parse(x)`. Plus 1,685 series descriptions (which is what finally reaches the histogram lexer states), 834 `ParseMetric`, 842 `ParseMetricSelector`, 1,685 `model.Duration`, 408 `strconv.ParseInt`/`ParseUint`. See ADR-11, ADR-12 |
| 5 | `PromQL` engine + storage protocols | 12k | **All 2,201 `eval` assertions green.** Shippable library milestone |
| 6 | TSDB read path | 9k | Read every block in `tsdb/testdata/`; `tsdb dump` byte-equals `promtool`; re-run 2,201 evals on a block querier |
| 7 | TSDB write path | 14k | **Byte-identical block** vs Go (ULID pinned); `promtool tsdb verify` accepts ours; WAL replay both ways |
| 8 | Ingest: text parse, relabel, config, discovery, scrape | 9k | All 217 `config/testdata/` fixtures incl. **byte-identical error strings**; live scrape differential |
| 9 | Server: web API, rules, notifier, template, UI bundle, `prometheus`/`promtool` | 14k | **HTTP differential** — Go and Swift over the same TSDB dir, byte-compare JSON across the API corpus |
| 10 | Remote read/write, exemplars, OOO head, agent mode, perf | 8k | `compliance/` remote-write suite; benchmark parity |

## Module tiers

```
Tier 0  GoCompat, PromHash, PromULID, PromSnappy, PromMath      (no deps)
        CZstd (.systemLibrary) ← PromZstd
Tier 1  PromModel → GoCompat
        PromRegex → GoCompat
        PromLabels → PromModel, PromHash, PromRegex, GoCompat
        PromHistogram → PromModel, PromMath, PromLabels, GoCompat
                        (the PromLabels edge is convert.go's, mirroring upstream:
                         model/histogram imports model/labels to emit classic
                         series from an NHCB)
        PromExemplar, PromMetadata
Tier 2  PromEncoding → PromHash, GoCompat
        PromFileUtil, PromAnnotations, PromCompression
Tier 3  PromChunkEnc → PromHistogram, PromEncoding, GoCompat
Tier 4  PromStorageCore  (protocols + types only)
        PromStorage      (merge, buffer, memoized iterator, series)
Tier 5  PromTSDBIndex / PromTSDBChunks / PromTSDBTombstones / PromTSDBRecord / PromTSDBWAL
        PromTSDB
Tier 6  PromQLParser → PromQL → PromQLTest
Tier 7  PromTextParse, PromRelabel, PromDiscoveryCore, PromConfig, PromDiscovery, PromScrape
Tier 8  PromTemplate, PromRules, PromNotifier, PromRemote, PromWebUI, PromWebAPI, PromServer
  exe   prometheus, promtool, promdiff
```

Go's `storage` package sits *between* the chunk layer and the index layer (`tsdb/index`,
`tsdb/record`, `tsdb/tombstones` need `storage.SeriesRef`, while `storage/merge.go` needs
`chunkenc`). We split it: **`PromStorageCore`** (protocols + types) and **`PromStorage`**
(algorithms). Index depends on Core only. Same trick for `PromDiscoveryCore` so `PromConfig` need
not depend on providers.
