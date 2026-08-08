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

## Not ported

- The React UI (`web/ui/mantine-ui`, ~25k lines TS) — ship the prebuilt bundle, do the five
  `index.html` placeholder substitutions.
- 26 of 29 service-discovery providers (~21.4k lines) — each needs a cloud SDK with no Swift
  equivalent. Keeping: `static`, `file`, `http`, `dns`.
- OpenAPI spec machinery (`web/api/v1/openapi*.go`, 4,067 lines).
- `util/fuzzing` and Go test infra (3,869 lines).
- `util/{zeropool,pool,runutil,runtime,osutil,netconnlimit,treecache,documentcli}` — Go-runtime
  gap-fillers Swift does not need.
