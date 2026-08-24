#!/usr/bin/env bash
# Negative controls for §7h(c) — the WAL half of `Head.Truncate` and the checkpoint it writes.
#
# Two source files, so `run` takes the file it perturbed, copying the two-file helper from
# `Scripts/controls-headread.sh`:
#
#   Sources/PromWAL/Checkpoint.swift        `tsdb/wlog/checkpoint.go`
#   Sources/PromHead/HeadWALTruncate.swift  `head.go`'s truncateWAL, walExpiries, keepSeriesInWALCheckpointFn
#
# The corpus is `Fixtures/head/replay.jsonl`, driven through the real `tsdb.Head.Truncate` — it commits the
# checkpoint's directory NAME, its segment BYTES and its records decoded, so a perturbation that changes what
# the checkpoint keeps is a byte diff rather than a counter diff. `CheckpointTests` carries what a corpus driven
# through the Head cannot reach: the error strings, the directory predicates, and the record types the port's
# Head cannot yet produce.
#
# Both suites are run, because Checkpoint.swift is observable from either side.
#
# Traps, all of them paid for by an earlier sweep, plus two this one found:
#
#   * **a `$` cannot be matched inside `\Q…\E` at all.** `\$0` does not survive it — perl still eats the
#     interpolation, and the patch silently fails to apply. Nine controls in this sweep's first run reported SKIP
#     for that one reason. Either break out (`\E\$\Q`) or, better, end the quoted run early and use `[^\n]*` for
#     the rest of the line, which is what `controls-headread.sh` does. A `$` in the REPLACEMENT is fine as `\$`.
#   * **nor can a `\`.** `\Q…\E` consumes `\(` as an escaped paren and the backslash is gone, and no number of
#     extra backslashes brings it back — so a pattern can never contain a Swift string interpolation. Match a
#     substring on one side of it, or use `.` where the backslash is.
#   * `\Q…\E` does not interpret `\n`, so a multi-line pattern needs `\E\n\Q` between the lines.
#   * a control that patches a DOC COMMENT measures nothing. Where the same string appears in a comment above
#     the code, use `/g` or make the pattern include enough context to be unique.
#   * an apostrophe cannot appear in a single-quoted perl program; match a substring after it.
#   * **check the indentation.** Six of the first run's skips were an eight-space pattern against a twelve-space
#     line — the filters sit inside a `switch` inside a `while`. `SKIP (patch did not apply)` is the only reason
#     that was caught, which is what the check is for.
set -uo pipefail
cd "$(dirname "$0")/.."
CP=Sources/PromWAL/Checkpoint.swift
TR=Sources/PromHead/HeadWALTruncate.swift
cp "$CP" /tmp/hwt-cp.orig
cp "$TR" /tmp/hwt-tr.orig
restore() { cp /tmp/hwt-cp.orig "$CP"; cp /tmp/hwt-tr.orig "$TR"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# run <file> <name>
run() {
  local f="$1" name="$2" orig
  case "$f" in
    "$CP") orig=/tmp/hwt-cp.orig ;;
    "$TR") orig=/tmp/hwt-tr.orig ;;
  esac
  if cmp -s "$f" "$orig"
  then
    printf "  %-70s SKIP (patch did not apply)\n" "$name"
    restore
    return
  fi
  control_verdict "$name" 'HeadReplayTests|CheckpointTests' 70
  restore
}

echo "=== truncateWAL's guards, and the segment it always cuts ==="
perl -0pi -e 's~\Q        guard let wal, mint > lastWALTruncationTime else {\E~        guard let wal, mint >= lastWALTruncationTime else {~' "$TR"; run "$TR" "the idempotence guard admits an equal mint"
perl -0pi -e 's~\Q        guard let wal, mint > lastWALTruncationTime else {\E~        guard let wal else {~' "$TR"; run "$TR" "there is no idempotence guard at all"
perl -0pi -e 's~\Q        lastWALTruncationTime = mint\E~~' "$TR"; run "$TR" "the truncation time is never recorded"
perl -0pi -e 's~\Q        _ = try wal.nextSegment()\E~~' "$TR"; run "$TR" "no new segment is cut"
perl -0pi -e 's~\Q        var (first, last) = try walSegments(fsStorage, wal.dir)\E\n\Q        // Start a new segment, so a low-ingestion TSDB does not keep more WAL than it needs.\E\n\Q        _ = try wal.nextSegment()\E~        _ = try wal.nextSegment()\n        var (first, last) = try walSegments(fsStorage, wal.dir)~' "$TR"; run "$TR" "the segment is cut BEFORE the range is read"

echo "=== the two-thirds rule ==="
perl -0pi -e 's~\Q        last -= 1  // Never consider the last segment for a checkpoint.\E~~' "$TR"; run "$TR" "the live segment is considered for the checkpoint"
perl -0pi -e 's~\Q        last -= 1  // Never consider the last segment for a checkpoint.\E~        last -= 2~' "$TR"; run "$TR" "two segments are held back instead of one"
perl -0pi -e 's~\Q        if last < 0 {\E\n\Q            return  // No segments yet.\E\n\Q        }\E~~' "$TR"; run "$TR" "an empty segment directory is not refused"
perl -0pi -e 's~\Q        last = first + (last - first) \E\Q* 2 / 3\E~        last = first + (last - first)~' "$TR"; run "$TR" "the whole range is checkpointed rather than the lower two thirds"
perl -0pi -e 's~\Q        last = first + (last - first) \E\Q* 2 / 3\E~        last = first + (last - first) / 3~' "$TR"; run "$TR" "only the lower THIRD is checkpointed"
perl -0pi -e 's~\Q        last = first + (last - first) \E\Q* 2 / 3\E~        last = (last - first) \* 2 / 3~' "$TR"; run "$TR" "the two-thirds point is not offset by first"
perl -0pi -e 's~\Q        if last <= first {\E~        if last < first {~' "$TR"; run "$TR" "a single-segment range is considered worth checkpointing"
perl -0pi -e 's~\Q        if last <= first {\E\n\Q            return\E\n\Q        }\E~~' "$TR"; run "$TR" "there is no worth-it test at all"

echo "=== what truncateWAL does after the checkpoint ==="
perl -0pi -e 's~\Q        try? wal.truncate(last + 1)\E~        try? wal.truncate(last)~' "$TR"; run "$TR" "the checkpointed high segment is kept rather than removed"
perl -0pi -e 's~\Q        try? wal.truncate(last + 1)\E~~' "$TR"; run "$TR" "the checkpointed segments are never removed"
perl -0pi -e 's~\Q        for (ref, keepUntil) in walExpiries where keepUntil < mint {\E~        for (ref, keepUntil) in walExpiries where keepUntil <= mint {~' "$TR"; run "$TR" "an expiry exactly at mint is pruned"
perl -0pi -e 's~\Q        for (ref, keepUntil) in walExpiries where keepUntil < mint {\E\n\Q            walExpiries.removeValue(forKey: ref)\E\n\Q        }\E~~' "$TR"; run "$TR" "the expiries are never pruned"
perl -0pi -e 's~\Q        try? deleteCheckpoints(fsStorage, wal.dir, maxIndex: last)\E~~' "$TR"; run "$TR" "superseded checkpoints are left behind"
perl -0pi -e 's~\Q        try? deleteCheckpoints(fsStorage, wal.dir, maxIndex: last)\E~        try? deleteCheckpoints(fsStorage, wal.dir, maxIndex: last + 1)~' "$TR"; run "$TR" "deleteCheckpoints is given last + 1, so it removes the new checkpoint"

echo "=== walExpiries and keepSeriesInWALCheckpointFn ==="
perl -0pi -e 's~\Q        walExpiries\E\Q[id] = max(keepUntil, walExpiries[id] ?? Int64.min)\E~        walExpiries[id] = keepUntil~' "$TR"; run "$TR" "updateWALExpiry overwrites rather than taking the max"
perl -0pi -e 's~\Q        walExpiries\E\Q[id] = max(keepUntil, walExpiries[id] ?? Int64.min)\E~        walExpiries[id] = min(keepUntil, walExpiries[id] ?? Int64.max)~' "$TR"; run "$TR" "updateWALExpiry takes the MIN"
perl -0pi -e 's~\Q        walExpiries\E\Q[id] = max(keepUntil, walExpiries[id] ?? Int64.min)\E~        walExpiries[id] = max(keepUntil, walExpiries[id] ?? 0)~' "$TR"; run "$TR" "the absent-expiry seed is 0 rather than Int64.min"
perl -0pi -e 's~\Q        guard let keepUntil = walExpiries[id] else { return (0, false) }\E~        guard let keepUntil = walExpiries[id] else { return (0, true) }~' "$TR"; run "$TR" "walExpiry reports found for a ref it has no expiry for"
perl -0pi -e 's~\Q            if self.series.getByID(id) != nil {\E\n\Q                return true\E\n\Q            }\E~~' "$TR"; run "$TR" "keepSeries drops its does-the-series-exist arm"
perl -0pi -e 's~\Q            return ok && keepUntil >= mint\E~        return false~' "$TR"; run "$TR" "keepSeries drops its WAL-expiry arm"
perl -0pi -e 's~\Q            return ok && keepUntil >= mint\E~            return ok \&\& keepUntil > mint~' "$TR"; run "$TR" "an expiry exactly at mint does not keep the record"
perl -0pi -e 's~\Q            return ok && keepUntil >= mint\E~            return ok~' "$TR"; run "$TR" "any expiry keeps the record, however stale"
perl -0pi -e 's~\Q            return ok && keepUntil >= mint\E~            return true~' "$TR"; run "$TR" "every series record is kept"

echo "=== the checkpoint's range, and the previous checkpoint ==="
perl -0pi -e 's~\Q        if from > last {\E~        if from > last + 1 {~' "$CP"; run "$CP" "the gap check is off by one"
perl -0pi -e 's~\Q        if from > last {\E\n\Q            throw CheckpointError.unexpectedGap(expected: last, requested: from)\E\n\Q        }\E~~' "$CP"; run "$CP" "a gap to the last checkpoint is not refused"
perl -0pi -e 's~\Q        let last = lastCP.index + 1\E~        let last = lastCP.index~' "$CP"; run "$CP" "the previous checkpoint's index is not incremented"
perl -0pi -e 's~\Q        from = last\E~~' "$CP"; run "$CP" "from is not raised to the previous checkpoint's boundary"
perl -0pi -e 's~\Q        ranges.append(WALSegmentRange(dir: lastCP.dir, first: -1, last: Int(Int32.max)))\E~~' "$CP"; run "$CP" "the previous checkpoint is not read into the new one"
perl -0pi -e 's~\Q        ranges.append(WALSegmentRange(dir: lastCP.dir, first: -1, last: Int(Int32.max)))\E\n\Q    }\E\n\Q    ranges.append(WALSegmentRange(dir: wal.dir, first: from, last: to))\E~    }\n    ranges.append(WALSegmentRange(dir: wal.dir, first: from, last: to))\n    if let lastCP { ranges.append(WALSegmentRange(dir: lastCP.dir, first: -1, last: Int(Int32.max))) }~' "$CP"; run "$CP" "the previous checkpoint is read AFTER the live segments"
perl -0pi -e 's~\Q    ranges.append(WALSegmentRange(dir: wal.dir, first: from, last: to))\E~    ranges.append(WALSegmentRange(dir: wal.dir, first: from, last: -1))~' "$CP"; run "$CP" "the live range has no upper bound"
perl -0pi -e 's~\Q    ranges.append(WALSegmentRange(dir: wal.dir, first: from, last: to))\E~    ranges.append(WALSegmentRange(dir: wal.dir, first: -1, last: to))~' "$CP"; run "$CP" "the live range has no lower bound"

echo "=== the checkpoint's name and its temporary twin ==="
perl -0pi -e 's~\Q    let cpdir = checkpointDir(wal.dir, to)\E~    let cpdir = checkpointDir(wal.dir, from)~' "$CP"; run "$CP" "the checkpoint is named after from rather than to"
perl -0pi -e 's~\Q(String(format: "%08d", i))"\E~(i)"~' "$CP"; run "$CP" "the checkpoint index is not zero-padded"
perl -0pi -e 's~\Qpublic let checkpointTempFileSuffix = ".tmp"\E~public let checkpointTempFileSuffix = ".temp"~' "$CP"; run "$CP" "the temporary suffix is spelled differently"
perl -0pi -e 's~\Q    try deleteTempCheckpoints(fs, wal.dir)\E~~' "$CP"; run "$CP" "a leftover temporary checkpoint is not cleared first"
perl -0pi -e 's~\Q        try? removeDirectoryRecursively(fs, cpdirtmp)\E~~' "$CP"; run "$CP" "the temporary directory is left behind"
perl -0pi -e 's~\Q        if name.hasPrefix(checkpointPrefix) && name.hasSuffix(checkpointTempFileSuffix) {\E~        if name.hasPrefix(checkpointPrefix) {~' "$CP"; run "$CP" "DeleteTempCheckpoints takes the real checkpoints too"

echo "=== listCheckpoints and LastCheckpoint ==="
perl -0pi -e 's~\Q        guard name.hasPrefix(checkpointPrefix) else { continue }\E~~' "$CP"; run "$CP" "every directory entry is treated as a checkpoint"
perl -0pi -e 's~\Q            throw CheckpointError.notADirectory(name)\E~~' "$CP"; run "$CP" "a file named like a checkpoint is accepted"
perl -0pi -e 's~\Q        guard let idx = Int(suffix) else { continue }\E~        let idx = Int(suffix) ?? -1~' "$CP"; run "$CP" "an unparseable suffix is admitted as index -1"
perl -0pi -e 's~\Q    refs.sort {\E[^\n]*~~' "$CP"; run "$CP" "listCheckpoints does not sort"
perl -0pi -e 's~\Q    refs.sort {\E[^\n]*~    refs.sort { \$1.index < \$0.index }~' "$CP"; run "$CP" "listCheckpoints sorts descending"
perl -0pi -e 's~\Q    guard let last = checkpoints.last else {\E~    guard let last = checkpoints.first else {~' "$CP"; run "$CP" "LastCheckpoint returns the FIRST checkpoint"
perl -0pi -e 's~\Q        throw RecordError.notFound\E~        throw CheckpointError.notADirectory("")~' "$CP"; run "$CP" "the no-checkpoint case is not RecordError.notFound"
perl -0pi -e 's~\Q        if checkpoint.index >= maxIndex {\E~        if checkpoint.index > maxIndex {~' "$CP"; run "$CP" "DeleteCheckpoints removes maxIndex itself"
perl -0pi -e 's~\Q        if checkpoint.index >= maxIndex {\E\n\Q            break\E\n\Q        }\E~~' "$CP"; run "$CP" "DeleteCheckpoints removes every checkpoint"
perl -0pi -e 's~\Q            break\E\n\Q        }\E\n\Q        do { try removeDirectoryRecursively\E~            continue\n        }\n        do { try removeDirectoryRecursively~' "$CP"; run "$CP" "DeleteCheckpoints continues instead of breaking"

echo "=== the three filters ==="
perl -0pi -e 's~\Q            let repl = series.filter { keep(\E[^\n]*~            let repl = series~' "$CP"; run "$CP" "the series filter keeps everything"
perl -0pi -e 's~\Q            let repl = series.filter { keep(\E[^\n]*~            let repl = series.filter { !keep(\$0.ref) }~' "$CP"; run "$CP" "the series filter is inverted"
perl -0pi -e 's~\Q            let repl = samples.filter\E[^\n]*~            let repl = samples~' "$CP"; run "$CP" "the sample filter keeps everything"
perl -0pi -e 's~\Q            let repl = samples.filter\E[^\n]*~            let repl = samples.filter { \$0.t > mint }~' "$CP"; run "$CP" "a sample exactly at mint is dropped"
perl -0pi -e 's~\Q            let repl = samples.filter\E[^\n]*~            let repl = samples.filter { \$0.t <= mint }~' "$CP"; run "$CP" "the sample filter is inverted"
perl -0pi -e 's~\Q            let repl = tstones.filter\E[^\n]*~            let repl = tstones~' "$CP"; run "$CP" "the tombstone filter keeps everything"
perl -0pi -e 's~\Q            let repl = tstones.filter\E[^\n]*~            let repl = tstones.filter { stone in stone.intervals.contains { \$0.mint >= mint } }~' "$CP"; run "$CP" "the tombstone filter tests mint rather than maxt"
perl -0pi -e 's~\Q            let repl = tstones.filter\E[^\n]*~            let repl = tstones.filter { stone in stone.intervals.allSatisfy { \$0.maxt >= mint } }~' "$CP"; run "$CP" "a tombstone needs EVERY interval to reach mint"
perl -0pi -e 's~\Q            if !repl.isEmpty {\E\n\Q                recs.append(enc.series(repl))\E\n\Q            }\E~            recs.append(enc.series(repl))~' "$CP"; run "$CP" "an all-dropped series record is written as an empty one"
perl -0pi -e 's~\Q                recs.append(enc.samples(repl))\E~                recs.append(enc.samples(repl.reversed()))~' "$CP"; run "$CP" "the surviving samples are written in reverse"

echo "=== the pass-through arm, and the stats ==="
perl -0pi -e 's~\Q        case .unknown, .mmapMarkers:\E~        case .unknown:~' "$CP"; run "$CP" "an mmap-marker record is copied through instead of dropped"
perl -0pi -e 's~\Q            recs.append(rec)\E\n\Q            stats.passedThrough += 1\E~            stats.passedThrough += 1~' "$CP"; run "$CP" "the pass-through records are counted but not written"
perl -0pi -e 's~\Q            stats.passedThrough += 1\E~~' "$CP"; run "$CP" "the pass-through records are not counted"
perl -0pi -e 's~\Q        stats.totalSeries += series.count\E~~' "$CP"; run "$CP" "totalSeries is not accumulated"
perl -0pi -e 's~\Q        stats.droppedSeries += series.count - repl.count\E~        stats.droppedSeries += repl.count~' "$CP"; run "$CP" "droppedSeries counts the KEPT series"
perl -0pi -e 's~\Q        stats.droppedSamples += samples.count - repl.count\E~        stats.droppedSamples += repl.count~' "$CP"; run "$CP" "droppedSamples counts the KEPT samples"
perl -0pi -e 's~\Q        stats.totalTombstones += tstones.count\E~~' "$CP"; run "$CP" "totalTombstones is not accumulated"
perl -0pi -e 's~\Q        stats.droppedTombstones += tstones.count - repl.count\E~        stats.droppedTombstones += repl.count~' "$CP"; run "$CP" "droppedTombstones counts the KEPT stones"

echo "=== the flush, the errors and the copy ==="
perl -0pi -e 's~\Q        if !recs.isEmpty {\E\n\Q            do { try cp.log(records: recs) } catch {\E~        if false, !recs.isEmpty {\n            do { try cp.log(records: recs) } catch {~' "$CP"; run "$CP" "nothing is ever flushed to the checkpoint"
perl -0pi -e 's~\Q            recs.removeAll(keepingCapacity: true)\E~~' "$CP"; run "$CP" "the flushed records are not cleared, so every record is rewritten"
perl -0pi -e 's~\Q    if let err = r.err {\E\n\Q        throw CheckpointError.readSegments(err)\E\n\Q    }\E~~' "$CP"; run "$CP" "a corrupt source segment does not fail the checkpoint"
perl -0pi -e 's~\Q    do { try cp.close() } catch {\E\n\Q        throw CheckpointError.closeCheckpoint(error)\E\n\Q    }\E~~' "$CP"; run "$CP" "the checkpoint WAL is not closed, so its last page never lands"
perl -0pi -e 's~\Qunexpected gap to last checkpoint. expected:\E~unexpected gap to the last checkpoint. expected:~' "$CP"; run "$CP" "the gap message is reworded"
# The message contains no apostrophe, but the same words appear in the doc comment above `listCheckpoints`, so
# the pattern includes the interpolation to stay unique to the code.
perl -0pi -e 's~\Q is not a directory\E~ is not a folder~g' "$CP"; run "$CP" "the not-a-directory message is reworded"
perl -0pi -e 's~\Q        let bytes = try src.read(offset: 0, length: src.size)\E~        let bytes = try src.read(offset: 0, length: max(0, src.size - 1))~' "$CP"; run "$CP" "the copy to the final name drops the last byte"
perl -0pi -e 's~\Q        let dst = try fs.createFile(\E[^\n]*~        let dst = try fs.createFile("\\(cpdir)/x\\(name)")~' "$CP"; run "$CP" "the copied segment lands under a different name"

echo "=== the harness itself ==="
perl -0pi -e 's~\Q    var stats = CheckpointStats()\E~    var stats = CheckpointStats()\n    _ = stats~' "$CP"; run "$CP" "harness check: a no-op perturbation is reported as surviving"

# ---------------------------------------------------------------------------------------------------
# 79 controls: 75 broke, 4 SURVIVED, 0 SKIP, 0 COMPILE.
#
# The first run scored 58/79 with **15 SKIP**, and every skip was a perl-escaping fault rather than a
# corpus fault — see the header. Two of them are new knowledge: inside `\Q…\E` neither `$` nor `\` can
# be matched, so a pattern must never contain a Swift string interpolation. The other six were an
# eight-space pattern against a twelve-space line, because the three filters sit inside a `switch`
# inside a `while`. Fixing the patterns took the sweep to 74/79.
#
# Three of the four then-remaining survivors were closed by widening the hand-written assertions
# rather than the corpus, because all three are `Checkpoint` arms that `Head.truncateWAL` never
# reaches:
#
#   * **`from` is not raised to the previous checkpoint's boundary.** `truncateWAL`'s `first` comes
#     from `Segments`, which after a truncation is already the previous checkpoint's index + 1 — so the
#     assignment is always a no-op there. Calling `Checkpoint(from: 0, ...)` directly with a checkpoint
#     at index 0 is what separates them: without the raise, segment 0 is read TWICE (once through the
#     checkpoint, once directly) and the new checkpoint gets duplicate records.
#   * **a leftover temporary checkpoint is not cleared first.** No case had a `.tmp` directory on entry.
#     It is not hygiene: a crashed run's `.tmp` holds SEGMENTS, so the new `WL` continues writing after
#     them and the stale records get copied to the final name as if they belonged.
#   * **a corrupt source segment does not fail the checkpoint.** `read segments` needs `Reader.Err()`
#     set, which a decode failure does not do — it takes a flipped payload byte, so the record's CRC no
#     longer matches. `temporaryDirectoryIsRemovedOnFailure` was reaching the decode path only.
#
# And a fourth, which is the more interesting kind — the assertion was *nearly* strong enough:
#
#   * **`listCheckpoints does not sort`.** Every name arrives from `fs.list`, which is already sorted,
#     and `%08d` makes lexical order agree with numeric order — so with eight-digit indices the sort is
#     genuinely redundant. It stops being redundant at 100,000,000, where `%08d` emits nine digits and
#     `checkpoint.100000000` sorts BELOW `checkpoint.99999999`. Adding those two names to
#     `listCheckpointsSkipsTemp` is what makes the sort load-bearing. Absurd as a segment count, but it
#     is the difference between a line that is tested and a line that only looks tested — and
#     `CheckpointDir` deliberately does not truncate, which is itself asserted.
#
# The four survivors:
#
# TAUTOLOGIES — a second guard downstream makes the first documentation:
#
#   * `an empty segment directory is not refused`. Removing `if last < 0 { return }` leaves
#     `last = first + (last - first) * 2 / 3`, and Swift's `/` truncates toward zero, so `first = 0`,
#     `last = -1` gives `0 + (-2)/3 = 0` — which the `last <= first` test below then refuses. Both
#     guards answer for the same inputs. Upstream keeps the first because `wlog.Segments` returns
#     `(-1, -1)` for a directory it cannot read, and naming that case is worth a line.
#   * `DeleteCheckpoints continues instead of breaking`. `listCheckpoints` returns its refs SORTED, so
#     `break` on the first index at or above `maxIndex` and `continue` past it remove exactly the same
#     set. Upstream's `break` is an optimisation over a list that is never long. (Same shape as
#     `wlog.Truncate`'s, quirk 177.)
#
# A PROOF, and it is quirk 194:
#
#   * `a tombstone needs EVERY interval to reach mint`. `contains` and `allSatisfy` agree because a
#     `Stone` that came off a WAL never has more than ONE interval — `record.Encoder.Tombstones` writes
#     one entry per (ref, interval) pair and the decoder rebuilds one stone from each. Upstream's inner
#     loop and its `break` are therefore dead on any decoded record, which is worth knowing before
#     someone "simplifies" the filter in the other direction. `CheckpointTests` encodes a two-interval
#     stone and asserts three come back, so the flattening itself is pinned even though the branch is
#     not distinguishable.
#
# DELIBERATE:
#
#   * `harness check: a no-op perturbation is reported as surviving`. The sweep's own control.
