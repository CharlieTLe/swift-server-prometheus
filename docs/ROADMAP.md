# Roadmap

Full-server port of Prometheus v3.13.2 to Swift. See `PORTING.md` for the fidelity contract,
`DECISIONS.md` for ADRs, `HANDOFF.md` for the current state in detail.

**Where things stand: phases 0–6 are done, phase 7 is nine slices in.** 58,700 lines of Swift across
28 targets, 20,539 lines of tests, 30,597 lines of Go oracle. 639 tests in 150 suites, green on Swift
6.4 and the 6.1 floor. The query engine passes all 2,183 of upstream's `eval` assertions; the TSDB
read path is closed; the Head ingests, is queried, forgets and survives a restart, and §7i(a) can turn it into
a **byte-identical block**. What is missing is `db.go` — the orchestration that decides when.

**One budget correction, because it is the largest miss in this plan.** The original estimate was
"≈85k lines of Swift plus **~3k** lines of Go test-oracle harness". The oracle is at **30,597 lines**
with three phases still to go — off by a factor of ten. That is not scope creep; it is what the
fidelity bar costs, and it is the number to use when estimating phases 8–10. The Swift estimate is
holding better: 58.7k spent against ≈85k projected, with the remaining phases the ones the estimate
understands worst.

## Why PromQL before TSDB — settled, and it was right

TSDB is larger and its formats look scarier, but PromQL is the higher-risk half and the only half
that ships with a portable oracle.

1. **Verification asymmetry.** PromQL's oracle is 2,183 `eval` assertions across 21 plain-text files
   (`promql/promqltest/testdata/`, 11,557 lines as committed) that copy over verbatim. TSDB's oracle
   is 68,150 lines of *Go test code* that does not port at all — TSDB-first means inventing a test
   suite first. That is exactly what phases 6 and 7 have had to do: fixtures, committed probe
   packages, and a per-slice negative-control sweep, which is where most of the oracle's 30k lines
   went.
2. **The storage seam is narrow.** `promql/engine.go` needs only `Queryable`, `Querier`, `SeriesSet`,
   `Series`, `SelectHints`, plus `NewBuffer`/`NewMemoizedIterator` — satisfiable by ~800 lines of
   in-memory storage. **PromQL does not need TSDB.** The converse is false.

   Landed at 522 lines, in `PromTestStorage`. The budget assumed the stand-in would have to be
   self-justifying; instead its contract is pinned against a real `tsdb.DB` in the oracle, which both
   shrank it and caught four behaviours that had been written backwards (HANDOFF §3).
3. **Risk profile.** TSDB failures are loud (CRC mismatch, bad magic, decode overrun). PromQL
   failures are silent (a wrong Kahan compensation term, an off-by-one in `rate()` extrapolation, a
   NaN that should have gone through `almost.Equal`). Front-load silent failure. Borne out: the
   engine's last eight gate failures were a counter-reset hint derived rather than stored — invisible
   to any test that did not compare against Go.
4. **TSDB gets a free gate later.** "Swap in the real Head, re-run the same evals" — a TSDB
   integration suite at zero marginal cost. **Not yet collected.** It needs §7g (`head_read.go`) to
   make a Head queryable; until then the gate runs on `PromTestStorage`.
5. PromQL over a protocol is independently shippable; a TSDB with no engine is not.

## Phases

`Swift LOC` is planned → actual. Actuals are `wc -l` over the targets each phase created, so a target
that keeps growing later (`PromChunkEnc`, `PromIndex`, `PromStorage`) is counted where it was born;
the column sums to 58,409, with `GoOracleSupport` (268) and `promdiff` (23) making up the rest of the
tree.

| # | Goal | Swift LOC | Exit gate (all vs Go) |
|---|---|---|---|
| 0 ✅ | Pin upstream to a read-only `v3.13.2` worktree | — | **DONE** — `git describe` = `v0.313.2`, commit `bb5dff00c`; `st.go` absent |
| **1** ✅ | **Foundations + verification rig.** `GoCompat`, `PromHash`, `PromMath`, `PromModel`, `PromLabels`, `PromEncoding`, the `oracle/` Go harness, `Fixtures/` | 6.1k → **7.5k** | **DONE** — the rig itself is the deliverable; `verify-fixtures.sh` green and proven to detect drift. Regex was stubbed (ADR-6), so `Matcher` regex parity deferred to Phase 2 |
| **2** ✅ | **`PromRegex` — RE2 in Swift.** Parser, Simplify, compiler, Pike VM, FastRegexMatcher | 3.4k → **7.8k** | **DONE** — 4,221 parse cases (tree + exact error text), 40,768 `MatchString`, 675 `SetMatches`. `Matcher` uses it; the literal-only stand-in is gone. Over budget by 2×, half of it generated tables; capture tracking was added later in §5e(e) for `label_replace` |
| **3** ✅ | **`PromHistogram` — native histograms** | 4.5k → **4.3k** | **DONE** — field-by-field bit-pattern parity on `Add/Sub/Mul/Div/KahanAdd/Compact/DetectReset/ToFloat/Validate/Equals/CopyTo/ReduceResolution`, plus `TrimBuckets` and `convert.go` |
| **4** ✅ | **`PromQLParser` — lexer ported 1:1, hand-written precedence-climbing parser replacing goyacc.** Plus `ast.go`, `printer.go`, `prettier.go`, `model.Duration`, `strutil.Unquote` | 5.9k → **6.5k** | **DONE** — 6,154 parse cases across six option sets: AST JSON via `translate_ast.go`, every error message and `PositionRange`, `String()`, `Prettify()`, `Tree()`, and `parse(print(parse(x))) == parse(x)`. Plus 1,685 series descriptions, 834 `ParseMetric`, 842 `ParseMetricSelector`, 1,685 `model.Duration`, 408 `strconv.ParseInt`/`ParseUint`. See ADR-11, ADR-12 |
| **5** ✅ | **`PromQL` engine + storage protocols.** Shippable library milestone | 12k → **17.6k** | **DONE — 2,183 of 2,183 `eval` assertions, zero failures, zero skips.** Every evaluator arm, every runner directive, every start-timestamp assertion; the gate has nothing left to measure. The count reads 2,183 rather than the 2,201 planned for because `@st` lines are no longer counted as assertions. Deliberately deferred: `storage/merge.go`, `generic.go`, `lazy.go`, every `MarshalJSON`. `storage.Appender` was deferred "to the phase that first has a caller" and duly landed in §7f(f) — the deferral policy working as intended |
| **6** ✅ | **TSDB read path** | 9k → **9.6k** | **READ PATH CLOSED** — 23 pinned slices. A block Prometheus wrote can be opened, matched, selected, trimmed and read as samples or chunks, every layer pinned on real files. Two of the three clauses originally written for this gate are **deferred to the phases that own their tooling**: `tsdb dump` byte-equals `promtool` needs `promtool` (Phase 9), and re-running the evals on a block querier needs the Head (§7g). The first clause was met by a stronger route than planned — rather than reading upstream's committed `tsdb/testdata/` blocks, `oracle/blockfixture.go` writes real blocks with upstream's own writer and opens them with `tsdb.OpenBlock`, so the corpus controls the input. Two read-path gaps stay open by construction and are §7i's (`Err` ordering, the undecodable-encoding path — both need malformed or non-XOR chunk bytes the port cannot yet write) |
| **7** 🔨 | **TSDB write path** | 14k → **6.3k so far** | **TEN SLICES IN (§7a–§7h plus §7i(t) and §7i(a)), `head.go` is DONE and the port can WRITE A BLOCK.** §7a `tsdb/record` (the WAL wire format, both directions) · §7b `tsdb/wlog`'s segment format · §7c the corruption corpus (took that sweep from 22 survivors to 9) · §7d `ChunkDiskMapper` · §7e `index.MemPostings` · **§7f the Head, six sub-slices**: `isolation.go`, `seriesHashmap`/`stripeSeries`, the `chunkenc` conformances, `memSeries`' in-order chunk state, `HeadOptions`/`NewHead`, and **the float append path** (§7f(f)) — 40 cases through the real `tsdb.Head`, each asserted in the three places a committed sample lands: the accessors, the WAL records byte for byte, and the chunk files · **§7g `head_read.go`**, so the Head is QUERYABLE · **§7h `head_wal.go` in three sub-slices**: (a) the GC (`gc`, `Delete`, `Truncate`, `MemTombstones`), (b) the REPLAY (`Init`, `loadMmappedChunks`, `loadWAL`), (c) the WAL TRUNCATION and `wlog/checkpoint.go`. **So the Head ingests, is queried, forgets, comes back from a restart, and no longer grows its WAL without bound.** · **§7i(t) the tombstone FILE codec** — `Encode`/`Decode`/`WriteFile`/`ReadTombstones` and the magic/version/CRC framing, in a 30-case round trip over the file's BYTES plus a 64-case CORRUPTION arm modelled on §7c; it found a reachable upstream panic on an eight-byte file (quirk 210). · **§7i(a) `blockwriter.go` + `LeveledCompactor`'s write path** in a new tier-10 `PromCompact` target — 36 differential cases in which upstream's own writer produces a block and the port has to produce the same `index`, chunk-segment and `meta.json` bytes, with the ULID scrubbed and injected (upstream reads `crypto/rand.Reader` directly and has no seam); 62 controls, 53 broke, 9 argued survivors; quirks 195-209 and exceptions 26-28. **So the first clause of this gate is MET: the port writes a byte-identical block, ULID pinned.** `db.go` is untouched. What remains inside §7f is deferred by feature rather than omitted: histograms and exemplars in the appender, `UpdateMetadata`, the out-of-order arm. Gate: the byte-identical-block clause is met; `promtool tsdb verify` accepts ours is Phase 9's tooling; WAL replay both ways landed in §7h(b). Remaining order below |
| 8 | Ingest: text parse, relabel, config, discovery, scrape | 9k | All 217 `config/testdata/` fixtures incl. **byte-identical error strings**; live scrape differential |
| 9 | Server: web API, rules, notifier, template, UI bundle, `prometheus`/`promtool` | 14k | **HTTP differential** — Go and Swift over the same TSDB dir, byte-compare JSON across the API corpus |
| 10 | Remote read/write, exemplars, OOO head, agent mode, perf | 8k | `compliance/` remote-write suite; benchmark parity |

**Scale for 8–10, so it is not rediscovered:** roughly 95k lines of Go against ~4.5k ported per
session at this fidelity bar (an oracle suite plus an argued control sweep per slice). That bar is
what caught ADR-10a, the file-index-vs-filename bug, the four survivor-diagnosis modes and a capacity
heuristic a comment had already dismissed as unobservable. Lowering it for 8–10 would be a legitimate
decision but must be recorded in PORTING.md as a departure, not taken silently.

### What is left of Phase 7, in order

Each is independently pinnable; HANDOFF §7f–§7h has the research. §7g and §7h have both landed, so
the list starts at §7i.

1. **§7i(a) — `blockwriter.go` + `LeveledCompactor`'s write path — LANDED.** See HANDOFF §7i(a).
   It closed one of §6w's two read-path gaps (the undecodable-encoding path, which turned out to be
   reached by *every* compaction of a Head rather than only by a non-XOR chunk) and left the other
   (`Err` ordering) open with the route in written down. Deferred with it: `CompactBlockMetas`,
   `Compact` (which needs `storage/merge.go`), `plan`/`selectDirs`, and everything out-of-order — all
   of them reached only from `db.go`'s driver, so they travel with §7j.
2. **§7i(b) — the two loose ends, neither of which is a session.** Fill §7i(a)'s
   `TombstoneFileWriter` seam with §7i(t)'s codec, which is two lines and deletes exception 26; and
   close what is left of exception 16 — `PromBlock.Block.init` still does not call `readTombstones`
   and there is no `Block.Delete`, both of them `tsdb/block.go` call sites rather than `compact.go`'s.
3. **§7j — `db.go`** (2,666 lines): the orchestration — `Open`, the block list, retention, the
   compaction *driver*, and `DB.Appender`/`Querier`. Last, because everything it schedules has to
   exist first, and it is where `storage/merge.go` finally has a caller. **Read HANDOFF §7j
   (scoping) before starting**: it splits the file into **five** independently pinnable sub-slices
   with a corpus each — (a) the head-only DB, (b) `reloadBlocks`, (c) retention, (d) the compaction
   driver, (e) `DB.Querier` — and corrects the three-way split this entry used to name. The
   corrections worth carrying up here: `Open` *calls* `reload()`, so "`Open` + `reloadBlocks`" is
   not a seam; `plan`/`selectDirs` are `LeveledCompactor`'s — they are not `db.go`'s, as an earlier version of
   item 1 claimed — but §7i(a) DEFERRED them rather than porting them, because their only caller is
   the driver, so they come with this slice and `LeveledCompactor.plan` currently throws
   `CompactError.plannerUnported`; db.go's share of "compaction scheduling" is the driver plus those; `rangeForTimestamp` is **already ported** (§7f(d),
   quirk 184); and the split omitted `DB.Querier`, which is what finally collects Phase 6's deferred
   exit-gate clause and therefore probably belongs second rather than last. §7j needs **no probe
   package** — `tsdb.Open` and `DB` expose almost everything, and even retention's
   `BeyondTimeRetention`/`BeyondSizeRetention` are exported.

**Scale, so it is not rediscovered:** what is left is ~2,700 lines of Go at a bar of one oracle suite
plus one argued control sweep per slice. HANDOFF §7j's scoping costs that out against the §7f–§7h
evidence and the honest number is **five or six** — §7i(b) is not a session, and §7j is five
sub-slices at the one-session-each rate the last ten sub-slices set.

Plus the parts of the appender §7f(f) deferred **by feature rather than by omission**: histograms and
exemplars, `UpdateMetadata`, and the out-of-order arm.

## Module tiers, as built

The graph below is `Package.swift`, not a plan. Where it differs from the original sketch, the
difference is noted — the naming in particular: the planned `PromTSDB*` prefix was dropped in favour
of one target per Go package, named after the package. **The tier numbers are strict:** every edge
points at a lower tier, which the old doc's looser grouping did not guarantee. That is why there are
more tiers here than in the sketch, not because anything was inserted.

```
Tier 0  GoCompat, PromHash, PromPosRange                                  (no deps)
Tier 1  PromModel → GoCompat
        PromRegex → GoCompat
        PromEncoding → PromHash, GoCompat
Tier 2  PromMath → PromModel        (mirrors Go: util/almost imports model/value)
        PromLabels → PromModel, PromHash, PromRegex, GoCompat
        PromAnnotations → PromPosRange, PromModel, GoCompat
        PromFS → PromEncoding                      (ADR-15; was planned as PromFileUtil)
Tier 3  PromHistogram → PromModel, PromMath, PromLabels, GoCompat
                        (the PromLabels edge is convert.go's, mirroring upstream:
                         model/histogram imports model/labels to emit classic
                         series from an NHCB)
        PromSchema → PromLabels, PromModel
        PromWAL → PromFS, PromHash, GoCompat
Tier 4  PromChunkEnc → PromHistogram, PromModel, GoCompat
        PromConvertNHCB → PromHistogram, PromLabels, PromModel, GoCompat
Tier 5  PromChunks → PromChunkEnc, PromHistogram, PromHash, PromFS, GoCompat
Tier 6  PromStorage → PromLabels, PromModel, PromHistogram, PromChunkEnc,
                      PromChunks, PromAnnotations, GoCompat
Tier 7  PromTombstones → PromStorage, PromFS, PromEncoding, PromHash, GoCompat
                          (PromFS/PromEncoding/PromHash arrived with the FILE codec, §7i(t):
                           the on-disk `tombstones` file is magic + Encbuf body + CRC-32C)
        PromIndex → PromStorage, PromLabels, PromEncoding, PromHash, PromFS, GoCompat
        PromQLParser → PromStorage, PromPosRange, PromHistogram, PromLabels, PromModel, GoCompat
        PromTestStorage → PromStorage, PromChunkEnc, PromChunks, PromHistogram,
                          PromLabels, PromAnnotations, GoCompat
Tier 8  PromBlock → PromIndex, PromChunks, PromChunkEnc, PromStorage,
                    PromEncoding, PromFS, PromLabels, PromTombstones, GoCompat
        PromRecord → PromLabels, PromHistogram, PromChunks, PromEncoding,
                     PromStorage, PromTombstones, PromModel, GoCompat
        PromQL → PromQLParser, PromStorage, PromChunkEnc, PromHistogram, PromLabels,
                 PromSchema, PromAnnotations, PromModel, PromRegex, GoCompat
Tier 9  PromHead → PromBlock, PromChunkEnc, PromChunks, PromFS, PromHistogram,
                   PromIndex, PromLabels, PromStorage, PromWAL, GoCompat
        PromQLTest → PromQL, PromQLParser, PromTestStorage, PromStorage, PromChunks,
                     PromHistogram, PromConvertNHCB, PromLabels, PromModel, PromRegex, GoCompat
Tier 10 PromCompact → PromBlock, PromChunkEnc, PromChunks, PromFS, PromHead,
                      PromIndex, PromLabels, PromStorage, PromTombstones, GoCompat
                      (§7i(a): a compactor READS a Head and WRITES a block, so it
                       sits above PromHead and nothing below it knows about
                       compaction. `db.go` joins it here in §7j.)
        (Phase 8) PromTextParse, PromRelabel, PromDiscoveryCore, PromConfig,
                  PromDiscovery, PromScrape
Tier 11 (Phase 9) PromTemplate, PromRules, PromNotifier, PromRemote, PromWebUI,
                  PromWebAPI, PromServer
  exe   promdiff (exists); prometheus, promtool (Phase 9)
```

**Planned tier-0 targets that never happened, and should not be created speculatively:**
`PromULID` — ULID landed inside `PromBlock/BlockMeta.swift`, pinned byte for byte in §6k, and has no
second caller. `PromSnappy`, `PromCompression`, `CZstd`/`PromZstd` — the WAL is uncompressed
(exception 20); snappy and zstd are *recognised on read* in `PromWAL/WALFormat.swift` and rejected,
and the snappy block format deserves its own slice when a corpus needs it. `PromExemplar`,
`PromMetadata` — the exemplar and metadata types live in `PromStorage` and `PromRecord` where their
Go equivalents are reached from; split them out if and when Phase 10 gives them their own storage.

**`PromPosRange` is a separate tier-0 target, and it is forced.** Go's dependency chain is

```
promql/parser -> storage -> util/annotations -> promql/parser/posrange
```

Upstream keeps `posrange` its own package precisely to break that cycle. Phase 4 folded it into
`PromQLParser`; Phase 5 had to split it back out, because the moment `PromStorage` exists the module
graph is circular. Anything new under `PromStorage` should have this edge checked first.

**`PromQLParser` is a tier-6 target that depends on `PromStorage`** — not a leaf, as an earlier
version of this plan assumed. `ast.go` imports `storage`, because `VectorSelector` caches its
`UnexpandedSeriesSet` and expanded `Series` on the node (ADR-11).

### Settled: `PromStorage` was never split, and that is now a decision

Go's `storage` package sits *between* the chunk layer and the index layer (`tsdb/index`,
`tsdb/record`, `tsdb/tombstones` need `storage.SeriesRef`, while `storage/merge.go` needs
`chunkenc`). The plan was to split it into `PromStorageCore` (protocols + types) and `PromStorage`
(algorithms) so index could depend on Core only. Phase 5 did not do it and this plan said to revisit
it in Phase 6.

**Phase 6 went by without it and nothing bent.** `PromIndex`, `PromTombstones` and `PromRecord` all
depend on the whole of `PromStorage`, which stays one target matching Go's one `storage` package. The
split buys nothing while `PromStorage` is still 1,740 lines of mostly protocols — and the cost of
doing it later is a target rename, not a redesign. Treat it as closed unless something in phases 8–10
needs to depend on the protocols without the algorithms. The same trick is still *planned* for
`PromDiscoveryCore`, so `PromConfig` need not depend on providers.

### Still open: `merge.go`, `generic.go`, `lazy.go`

`storage/merge.go` is **not ported.** This plan assumed it would land in Phase 6; it did not, because
nothing in the read path needed it — a single block querier does not merge, and `PromTestStorage`
sorts instead. It becomes load-bearing at §7j (`db.go` merges Head and blocks) and again in Phase 9.
Budget it there.

**`generic.go` is not the merge boilerplate its header claims.** Only ~145 of its 822 lines are the
`genericSeriesSet` adapters. Upstream commit `e1f4380b2` ("web/api: add search API endpoint")
appended a whole label-search subsystem — top-K heaps, streaming two-way merges, relevance scoring —
to the same file without updating the header. Part A belongs with `merge.go`; Part B belongs with the
HTTP API in Phase 9, and neither was a PromQL dependency. Part A is also a pre-generics type-erasure
workaround (`At()` returns an interface that the adapters downcast with unchecked assertions), so a
real Swift generic replaces it rather than porting it.
