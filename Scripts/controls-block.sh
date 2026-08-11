#!/usr/bin/env bash
# Negative controls for the block reader — the layout, the join, and `meta.json`'s permissive parser.
#
# This slice is composition: every format it touches is pinned against Go by another corpus. So what these
# controls have to reach is what composition can get wrong, and there are exactly three things:
#
#   1. WHICH FILE IS READ WHEN. `readMetaFile` runs before the index, so a future block fails on its
#      metadata rather than part-way through a parse. Nothing but ordering makes that true.
#   2. THE JOIN. A chunk meta's `BlockChunkRef` indexes the SORTED segment list (quirk 142), so the block
#      must hand the chunk reader the ref the index decoded and the chunk reader must sort as Go sorts.
#   3. LENIENCY, in both directions. `json.Unmarshal` ignores unknown fields and defaults absent ones. A
#      parser that is stricter rejects real files; one that drops a field it should keep loses data
#      silently. The `readsBackWhatGoWrote` test catches the second because Go's own bytes are the input.
#
# The perturbations below are grouped by those three. `--filter 'Block'` runs both block suites, so a
# perturbation to the meta parser is checked against all 25 of Go's marshalled metas, not a hand-written one.
set -uo pipefail
cd "$(dirname "$0")/.."
B=Sources/PromBlock/BlockReader.swift
M=Sources/PromBlock/BlockMeta.swift
C=Sources/PromChunks/ChunkReader.swift
F=Sources/PromFS/PromFS.swift
cp "$B" /tmp/b.orig && cp "$M" /tmp/m.orig && cp "$C" /tmp/c.orig && cp "$F" /tmp/f.orig
restore() { cp /tmp/b.orig "$B"; cp /tmp/m.orig "$M"; cp /tmp/c.orig "$C"; cp /tmp/f.orig "$F"; }
trap restore EXIT

# The timeout that `controls-postings.sh` learnt the hard way: a perturbation can hang rather than fail,
# and a control that never returns is a control that broke. `timeout(1)` is not on a stock macOS.
run() {
  local name="$1"
  if ! swift build 2>/dev/null >/dev/null; then printf '  %-56s COMPILE\n' "$name"; restore; return; fi
  local log; log=$(mktemp)
  swift test --filter 'Block' >"$log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 120 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    pkill -9 -f swiftpm-testing-helper 2>/dev/null
    wait "$pid" 2>/dev/null
    printf '  %-56s broke (hung)\n' "$name"
  elif grep -qE '✘|error:|signal' "$log"; then
    printf '  %-56s broke\n' "$name"
  else
    printf '  %-56s SURVIVED\n' "$name"
  fi
  rm -f "$log"
  restore
}

echo "=== 1. meta.json is read first, and its version is checked ==="
perl -0pi -e 's/        if version != 1 \{\n            throw BlockError\.unexpectedMetaVersion\(version\)\n        \}//' "$M"; run "the meta version is not checked at all"
perl -0pi -e 's/        if version != 1 \{/        if version < 1 {/' "$M"; run "a FUTURE version is accepted"
# The ordering itself: swap the meta block and the index block. If the index were read first, a block whose
# version is 2 and whose index is missing would report the missing index instead.
perl -0pi -e 's/        \/\/ `meta\.json` first, so a version mismatch fails before any index parsing\.\n(        let metaHandle.*?self\.meta = try BlockMeta\(json: metaBytes\)\n)\n(        let indexHandle.*?try indexHandle\.close\(\)\n)/$2\n$1/s' "$B"; run "the index is read BEFORE meta.json"

echo "=== 2. the join — a chunk meta's ref means the sorted segment list ==="
perl -0pi -e 's/        try chunks\.chunk\(ref: ChunkRef\(rawValue: meta\.ref\)\)/        try chunks.chunk(ref: ChunkRef(rawValue: meta.ref \&+ 1))/' "$B"; run "the ref handed to the chunk reader is off by one"
perl -0pi -e 's/        for meta in s\.chunks \{/        for meta in s.chunks.prefix(1) {/' "$B"; run "samples walks only the first chunk"
perl -0pi -e 's/        self\.chunks = try ChunkReader\(fs: fs, dir: dir \+ "\/chunks"\)/        self.chunks = try ChunkReader(fs: fs, dir: dir + "\/chunk")/' "$B"; run "the chunk directory is misspelled"
perl -0pi -e 's/        let indexHandle = try fs\.openForReading\(dir \+ "\/index"\)/        let indexHandle = try fs.openForReading(dir + "\/meta.json")/' "$B"; run "the index is read from meta.json's path"
perl -0pi -e 's/        let names = try fs\.list\(dir\)\.sorted\(\)/        let names = try fs.list(dir)/' "$C"; run "the chunk reader does not sort the segment list"
# ^ SURVIVES, ARGUED as redundancy rather than a gap: BOTH `PromFS` implementations already return sorted
# names (`InMemoryFS.list` ends in `names.sorted()`, `RealFS.list` in `.sorted()`), each because Go's
# `fileutil.ReadDir` does. The pair below proves which sort is load-bearing — remove the guarantee from the
# filesystem as well and the join fails immediately. The `.sorted()` stays because `PromFS` is a protocol
# and a third implementation is not obliged to have made that promise.
perl -0pi -e 's/        return names\.sorted\(\)/        return names.sorted().reversed()/' "$F"; run "InMemoryFS.list is unsorted (reader still sorts)"
perl -0pi -e 's/        let names = try fs\.list\(dir\)\.sorted\(\)/        let names = try fs.list(dir)/' "$C"
perl -0pi -e 's/        return names\.sorted\(\)/        return names.sorted().reversed()/' "$F"; run "BOTH sorts removed — the file index means nothing"

echo "=== 3. the index's fixed structures, parsed once at open ==="
perl -0pi -e 's/                byteSlice: bs, version: indexFormatV2, off: Int\(toc\.symbols\)\)/                byteSlice: bs, version: indexFormatV2, off: Int(toc.series))/' "$B"; run "the symbol table is read at the series offset"
perl -0pi -e 's/            let sparse = try buildPostingsOffsetIndex\(bs, postingsTable: toc\.postingsTable\)/            let sparse = try buildPostingsOffsetIndex(bs, postingsTable: toc.labelIndicesTable)/' "$B"; run "the postings table is read at the label-indices offset"
# ^ SURVIVES, ARGUED as a PROOF for every file a v2 writer produces. `index.go:410-412` assigns
# `LabelIndicesTable` and `PostingsTable` the SAME `w.f.pos`, back to back with nothing written between —
# because v2 writes no label indices section and keeps the field only for v1 compatibility. So the two
# offsets are equal in every index Prometheus has written since v2, and reading one at the other's offset
# cannot be observed. It is NOT equivalent in general (a v1 file has a real label-indices table there), so
# `toc.postingsTable` stays as the offset that is meant. Recorded rather than fixed.

echo "=== 4. the parser is lenient, and lenient in the right places ==="
# Stricter than Go: reject a key `Unmarshal` would ignore. A block from a newer Prometheus must still open.
perl -0pi -e 's/        \/\/ Go checks the version and NOTHING else, so an unknown field is ignored rather than rejected\./        if root.keys.contains(where: { ![\"ulid\", \"minTime\", \"maxTime\", \"stats\", \"compaction\", \"version\"].contains(\$0) }) {\n            throw BlockError.malformedMeta(\"unknown field\")\n        }/' "$M"; run "an unknown field is rejected (stricter than Unmarshal)"
# Less faithful than Go: drop a field that was there. Go's own bytes are the input, so the re-marshal differs.
perl -0pi -e 's/            compaction\.hints = \(c\["hints"\] as\? \[String\]\) \?\? \[\]/            compaction.hints = []/' "$M"; run "compaction.hints is dropped"
perl -0pi -e 's/            compaction\.sources = \(\(c\["sources"\] as\? \[String\]\) \?\? \[\]\)\.compactMap\(ULID\.init\)/            compaction.sources = []/' "$M"; run "compaction.sources is dropped"
perl -0pi -e 's/            for p in \(c\["parents"\] as\? \[\[String: Any\]\]\) \?\? \[\] \{/            for p in [[String: Any]]() {/' "$M"; run "compaction.parents is dropped"
perl -0pi -e 's/            compaction\.level = Int\(i64\(c\["level"\]\)\)/            compaction.level = 0/' "$M"; run "compaction.level is dropped"
perl -0pi -e 's/            compaction\.deletable = \(c\["deletable"\] as\? Bool\) \?\? false/            compaction.deletable = false/' "$M"; run "compaction.deletable is dropped"
perl -0pi -e 's/            compaction\.failed = \(c\["failed"\] as\? Bool\) \?\? false/            compaction.failed = false/' "$M"; run "compaction.failed is dropped"
perl -0pi -e 's/        if let st = root\["stats"\] as\? \[String: Any\] \{/        if let st = root["statistics"] as? [String: Any] {/' "$M"; run "the stats object is looked up under the wrong key"
perl -0pi -e 's/            stats\.numFloatSamples = u64\(st\["numFloatSamples"\]\)/            stats.numFloatSamples = 0/' "$M"; run "stats.numFloatSamples is dropped"
perl -0pi -e 's/        guard let ulidString = root\["ulid"\] as\? String, let parsed = ULID\(ulidString\) else \{/        guard let ulidString = root["ulid"] as? String, let parsed = Optional(ULID(bytes: Array(ulidString.utf8))) else {/' "$M"; run "the ULID is taken as raw bytes, not base32"
perl -0pi -e 's/            ulid: parsed, minTime: i64\(root\["minTime"\]\), maxTime: i64\(root\["maxTime"\]\)\)/            ulid: parsed, minTime: i64(root["maxTime"]), maxTime: i64(root["minTime"]))/' "$M"; run "minTime and maxTime are swapped"
