#!/usr/bin/env bash
# Negative controls for the Head's float append path — the two appenders, `Append`, `Commit`, `commitFloats`,
# `log()` and `Rollback`.
#
# The corpus is differential against the real `tsdb.Head` and asserts three things per case: the accessors, the
# WAL bytes and the chunk files. This sweep asks whether every line is visible in at least one of them.
#
# Search sides use perl's \Q...\E with `~` delimiters so Swift source pastes literally; a stale pattern reports
# SKIP, which is loud.
set -uo pipefail
cd "$(dirname "$0")/.."
HA=Sources/PromHead/HeadAppender.swift
cp "$HA" /tmp/ha-ha.orig
restore() { cp /tmp/ha-ha.orig "$HA"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  if cmp -s "$HA" /tmp/ha-ha.orig
  then
    printf "  %-64s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'HeadAppendTests' 64
  restore
}

echo "=== Appender() and initTime ==="
perl -0pi -e 's~\Q        if !initialized() {\E\n\Q            return InitAppender(head: self)\E\n\Q        }\E~~' "$HA"; run "Appender() never returns the init appender"
perl -0pi -e 's~\Q        if !initialized() {\E~        if initialized() {~' "$HA"; run "the init appender is used for an INITIALISED head"
perl -0pi -e 's~\Q        guard maxTimeValue == Int64.min else { return }\E\n\Q        maxTimeValue = t\E\n\Q        if minTimeValue == Int64.max {\E\n\Q            minTimeValue = t\E\n\Q        }\E~        if minTimeValue == Int64.max { minTimeValue = t }\n        if maxTimeValue == Int64.min { maxTimeValue = t }~' "$HA"; run "initTime sets minTime before maxTime"
perl -0pi -e 's~\Q        guard maxTimeValue == Int64.min else { return }\E~~' "$HA"; run "initTime overwrites an established maxTime"
perl -0pi -e 's~\Q        if minTimeValue == Int64.max {\E\n\Q            minTimeValue = t\E\n\Q        }\E~~' "$HA"; run "initTime never sets minTime"

echo "=== headAppender()'s snapshot ==="
perl -0pi -e 's~\Q        let minValid = appendableMinValidTime()\E~        let minValid = minValidTime()~' "$HA"; run "the appender's minValidTime ignores the compaction window"
perl -0pi -e 's~\Qhead: self, minValidTime: minValid, headMaxt: maxTime(),\E~head: self, minValidTime: minValid, headMaxt: minTime(),~' "$HA"; run "the appender snapshots minTime as its headMaxt"
perl -0pi -e 's~\Q            oooTimeWindow: opts.outOfOrderTimeWindow,\E~            oooTimeWindow: 0,~' "$HA"; run "the appender ignores the OOO time window"
perl -0pi -e 's~\Q            storeST: opts.enableSTStorage, useXOR2: opts.useXOR2FloatEncoding())\E~            storeST: false, useXOR2: opts.useXOR2FloatEncoding())~' "$HA"; run "the appender never stores start timestamps"
perl -0pi -e 's~\Q            storeST: opts.enableSTStorage, useXOR2: opts.useXOR2FloatEncoding())\E~            storeST: opts.enableSTStorage, useXOR2: false)~' "$HA"; run "the appender always uses XOR rather than XOR2"
perl -0pi -e 's~\Q        let (appendID, cleanupAppendIDsBelow) = iso.newAppendID(minTime: minValid)\E~        let (appendID, cleanupAppendIDsBelow) = (UInt64(0), UInt64(0))~' "$HA"; run "the appender takes no isolation ID"

echo "=== InitAppender ==="
perl -0pi -e 's~\Q        if let app {\E\n\Q            return try app.append(ref: ref, labels: lset, t: t, v: v)\E\n\Q        }\E\n\Q        head.initTime(t)\E~        head.initTime(t)~' "$HA"; run "the init appender re-initialises the head on every append"
perl -0pi -e 's~\Q        head.initTime(t)\E\n\Q        let a = head.headAppender()\E\n\Q        app = a\E\n\Q        return try a.append(ref: ref, labels: lset, t: t, v: v)\E~        let a = head.headAppender()\n        app = a\n        head.initTime(t)\n        return try a.append(ref: ref, labels: lset, t: t, v: v)~' "$HA"; run "the init appender builds its inner appender BEFORE initTime"
perl -0pi -e 's~\Q    public func commit() throws {\E\n\Q        guard let app else { return }\E\n\Q        try app.commit()\E~    public func commit() throws {\n        guard let app else { throw HeadError.appenderClosed }\n        try app.commit()~' "$HA"; run "an init appender with nothing appended fails to commit"
perl -0pi -e 's~\Q        if let g = app as? any GetRef {\E\n\Q            return g.getRef(labels: lset, hash: hash)\E\n\Q        }\E~~' "$HA"; run "the init appender's GetRef never forwards"

echo "=== Append: the fast fail and the series ==="
perl -0pi -e 's~\Q        if oooTimeWindow == 0 && t < minValidTime {\E~        if oooTimeWindow == 0 \&\& t <= minValidTime {~' "$HA"; run "the out-of-bounds fast fail rejects t == minValidTime"
perl -0pi -e 's~\Q        if oooTimeWindow == 0 && t < minValidTime {\E\n\Q            throw StorageError.outOfBounds\E\n\Q        }\E~~' "$HA"; run "there is no out-of-bounds fast fail"
perl -0pi -e 's~\Q        if oooTimeWindow == 0 && t < minValidTime {\E~        if t < minValidTime {~' "$HA"; run "the fast fail ignores whether OOO is enabled"
perl -0pi -e 's~\Q        var series = head.series.getByID(HeadSeriesRef(rawValue: ref.rawValue))\E\n\Q        if series == nil {\E\n\Q            series = try getOrCreate(labels: lset).series\E\n\Q        }\E\n\Q        guard let s = series else { throw HeadError.invalidSample }\E\n\Q\E\n\Q        if PromValue.isStaleNaN(v) {\E~        let s = try getOrCreate(labels: lset).series\n\n        if PromValue.isStaleNaN(v) {~' "$HA"; run "Append ignores the ref and always looks up by labels"

echo "=== Append: appendable and the batch ==="
perl -0pi -e 's~\Q            if isOOO, let hints, hints.discardOutOfOrder {\E~        if false, let hints, hints.discardOutOfOrder {~' "$HA"; run "DiscardOutOfOrder is not honoured"
perl -0pi -e 's~\Q            s.pendingCommit = true\E\n\Q        }\E\n\Q        if let err {\E~        }\n        if let err {~' "$HA"; run "a collected sample does not mark the series pending"
perl -0pi -e 's~\Q        if let err {\E\n\Q            throw err\E\n\Q        }\E\n\Q\E\n\Q        let b = getCurrentBatch(.float, s.ref)\E~        let b = getCurrentBatch(.float, s.ref)~' "$HA"; run "Append collects a sample appendable rejected"
perl -0pi -e 's~\Q        b.floats.append(RefSample(ref: s.ref, st: 0, t: t, v: v))\E~        b.floats.append(RefSample(ref: s.ref, st: t, t: t, v: v))~' "$HA"; run "the collected sample carries t as its start timestamp"
perl -0pi -e 's~\Q        b.floatSeries.append(s)\E\n\Q        return SeriesRef(rawValue: s.ref.rawValue)\E\n\Q    }\E\n\Q\E\n\Q    /// Go: `headAppender.AppendSTZeroSample`\E~        return SeriesRef(rawValue: s.ref.rawValue)\n    }\n\n    \/\/\/ Go: `headAppender.AppendSTZeroSample`~' "$HA"; run "the sample's series is not recorded alongside it"
perl -0pi -e 's~\Q        return SeriesRef(rawValue: s.ref.rawValue)\E\n\Q    }\E\n\Q\E\n\Q    /// Go: `headAppender.AppendSTZeroSample`\E~        return SeriesRef(rawValue: 0)\n    }\n\n    \/\/\/ Go: `headAppender.AppendSTZeroSample`~' "$HA"; run "Append returns a zero ref"

echo "=== AppendSTZeroSample ==="
perl -0pi -e 's~\Q        if st >= t {\E~        if st > t {~' "$HA"; run "an ST equal to the sample timestamp is accepted"
perl -0pi -e 's~\Qreturn (SeriesRef(rawValue: 0), StorageError.stNewerThanSample)\E~return (SeriesRef(rawValue: 0), StorageError.outOfOrderST)~' "$HA"; run "a too-new ST reports the out-of-order error"
perl -0pi -e 's~\Q        if isOOO {\E\n\Q            // The ONE place a non-zero ref travels with an error.\E\n\Q            return (SeriesRef(rawValue: s.ref.rawValue), StorageError.outOfOrderST)\E\n\Q        }\E~~' "$HA"; run "an out-of-order ST is accepted"
perl -0pi -e 's~\Q        b.floats.append(RefSample(ref: s.ref, st: 0, t: st, v: 0))\E~b.floats.append(RefSample(ref: s.ref, st: 0, t: st, v: 1))~' "$HA"; run "the synthetic ST sample carries 1 rather than 0"
perl -0pi -e 's~\Q        b.floats.append(RefSample(ref: s.ref, st: 0, t: st, v: 0))\E~b.floats.append(RefSample(ref: s.ref, st: 0, t: t, v: 0))~' "$HA"; run "the synthetic ST sample is timestamped t rather than st"

echo "=== getOrCreate's validation ==="
perl -0pi -e 's~\Q        let lset = lset.withoutEmpty()\E~~' "$HA"; run "empty label values are not dropped"
perl -0pi -e 's~\Q        if lset.isEmpty {\E\n\Q            throw AppenderError.emptyLabelset\E\n\Q        }\E~~' "$HA"; run "an empty label set is accepted"
perl -0pi -e 's~\Q        if let duplicate = lset.hasDuplicateLabelNames() {\E\n\Q            throw AppenderError.duplicateLabelName(duplicate)\E\n\Q        }\E~~' "$HA"; run "a duplicate label name is accepted"
perl -0pi -e 's~\Q            return "empty labelset: \(HeadError.invalidSample)"\E~            return "empty labelset"~' "$HA"; run "the empty-labelset message drops the wrapped error"
perl -0pi -e 's~\Q            hash: lset.goHash(), labels: lset, pendingCommit: true)\E~            hash: lset.goHash(), labels: lset, pendingCommit: false)~' "$HA"; run "a series is created without the pending-commit flag"
perl -0pi -e 's~\Q            seriesRefs.append(RefSeries(ref: s.ref, labels: lset))\E~~' "$HA"; run "a created series is not recorded for the WAL"
perl -0pi -e 's~\Q            createdSeries.append(s)\E~~' "$HA"; run "a created series is not recorded for the pending-commit sweep"
perl -0pi -e 's~\Q        if created {\E~        if !created {~' "$HA"; run "the series record is written for an EXISTING series"

echo "=== getCurrentBatch's table ==="
perl -0pi -e 's~\Q        if batches.isEmpty {\E\n\Q            return newBatch()\E\n\Q        }\E~~' "$HA"; run "the first batch is never created"
perl -0pi -e 's~\Q        case prevST == nil && st == .float:\E~        case false:~' "$HA"; run "a new float series cuts a new batch"
perl -0pi -e 's~\Q            typesInBatch.removeAll(keepingCapacity: true)\E~~' "$HA"; run "a new batch does not clear the type map"
perl -0pi -e 's~\Q            batches.append(b)\E~~' "$HA"; run "a new batch is not appended to the list"
perl -0pi -e 's~\Q        let lastBatch = batches[batches.count - 1]\E~        let lastBatch = batches[0]~' "$HA"; run "getCurrentBatch returns the FIRST batch"

echo "=== log() ==="
perl -0pi -e 's~\Q        guard let wal = head.wal else { return }\E~        guard let wal = head.wal else { return }\n        _ = wal~' "$HA"; run "harness check: a no-op perturbation is reported as surviving"
perl -0pi -e 's~\Q        if !seriesRefs.isEmpty {\E\n\Q            do {\E\n\Q                try wal.log(enc.series(seriesRefs))\E\n\Q            } catch {\E\n\Q                throw WALLogError.series(error)\E\n\Q            }\E\n\Q        }\E~~' "$HA"; run "the series record is never logged"
perl -0pi -e 's~\Q                    try wal.log(enc.samples(b.floats))\E~~' "$HA"; run "the samples record is never logged"
perl -0pi -e 's~\Q        let enc = RecordEncoder(enableSTStorage: storeST)\E~        let enc = RecordEncoder(enableSTStorage: false)~' "$HA"; run "the encoder ignores the ST-storage setting"
perl -0pi -e 's~\Q        if !seriesRefs.isEmpty {\E\n\Q            do {\E\n\Q                try wal.log(enc.series(seriesRefs))\E\n\Q            } catch {\E\n\Q                throw WALLogError.series(error)\E\n\Q            }\E\n\Q        }\E\n\Q        for b in batches {\E~        for b in batches {~' "$HA"; run "samples are logged before the series that name them"

echo "=== Commit ==="
perl -0pi -e 's~\Q        if closed {\E\n\Q            throw HeadError.appenderClosed\E\n\Q        }\E\n\Q\E\n\Q        do {\E\n\Q            try log()\E~        do {\n            try log()~' "$HA"; run "Commit can be called twice"
perl -0pi -e 's~\Q        do {\E\n\Q            try log()\E\n\Q        } catch {\E\n\Q            try? rollback()  // Most likely the same error will happen again.\E\n\Q            throw WALLogError.writeToWAL(error)\E\n\Q        }\E~        try? log()~' "$HA"; run "a WAL failure does not roll the append back"
perl -0pi -e 's~\Q            commitFloats(b, &acc)\E~~' "$HA"; run "Commit does not commit the floats"
perl -0pi -e 's~\Q        unmarkCreatedSeriesAsPendingCommit()\E\n\Q\E\n\Q        head.updateMinMaxTime\E~        head.updateMinMaxTime~' "$HA"; run "created series stay marked pending after a commit"
perl -0pi -e 's~\Q        head.updateMinMaxTime(mint: acc.inOrderMint, maxt: acc.inOrderMaxt)\E~~' "$HA"; run "a commit does not widen the head's time window"
perl -0pi -e 's~\Q        head.updateMinMaxTime(mint: acc.inOrderMint, maxt: acc.inOrderMaxt)\E~        head.updateMinMaxTime(mint: acc.inOrderMaxt, maxt: acc.inOrderMint)~' "$HA"; run "the window update swaps its bounds"
perl -0pi -e 's~\Q        head.iso.closeAppend(appendID)\E\n\Q        closed = true\E\n\Q    }\E~        closed = true\n    }~' "$HA"; run "Commit does not close the isolation append"
perl -0pi -e 's~\Q                chunkDiskMapper: head.chunkDiskMapper, chunkRange: head.chunkRange,\E~                chunkDiskMapper: head.chunkDiskMapper, chunkRange: defaultBlockDuration,~' "$HA"; run "the commit's chunk options ignore the head's chunk range"
perl -0pi -e 's~\Q                samplesPerChunk: head.opts.samplesPerChunk, useXOR2: useXOR2, storeST: storeST))\E~                samplesPerChunk: 1, useXOR2: useXOR2, storeST: storeST))~' "$HA"; run "the commit's chunk options force one sample per chunk"

echo "=== commitFloats ==="
perl -0pi -e 's~\Q            let (_, _, err) = series.appendable(\E~        let (_, _, err) = Optional<(Bool, Int64, (any Error)?)>.none ?? (false, 0, nil); _ = series.appendable(~' "$HA"; run "commitFloats does not re-check appendable"
perl -0pi -e 's~\Q                let (ok, created) = series.append(\E\n\Q                    st: s.st, t: s.t, v: s.v, appendID: appendID, o: acc.appendChunkOpts)\E~                let (ok, created) = series.append(\n                    st: s.st, t: s.t, v: s.v, appendID: 0, o: acc.appendChunkOpts)~' "$HA"; run "the committed sample carries no isolation ID"
perl -0pi -e 's~\Q                    if s.t < acc.inOrderMint { acc.inOrderMint = s.t }\E~~' "$HA"; run "the commit's minimum timestamp is not tracked"
perl -0pi -e 's~\Q                    if s.t > acc.inOrderMaxt { acc.inOrderMaxt = s.t }\E~~' "$HA"; run "the commit's maximum timestamp is not tracked"
perl -0pi -e 's~\Q                    if newlyStale { head.incNumStaleSeries() }\E~~' "$HA"; run "a series turning stale is not counted"
perl -0pi -e 's~\Q                    if staleToNonStale { head.decNumStaleSeries() }\E~~' "$HA"; run "a series leaving staleness is not uncounted"
perl -0pi -e 's~\Q                let newlyStale = !PromValue.isStaleNaN(series.lastValue) && PromValue.isStaleNaN(s.v)\E~                let newlyStale = PromValue.isStaleNaN(s.v)~' "$HA"; run "every stale sample counts as a new stale series"
perl -0pi -e 's~\Q            if chunkCreated {\E\n\Q                head.onChunkCreated(series: series, prevHeadChunkCount: prevHeadChunkCount)\E\n\Q            }\E~~' "$HA"; run "a chunk cut during commit is not reported to the head"
perl -0pi -e 's~\Q            series.cleanupAppendIDsBelow(cleanupAppendIDsBelow)\E\n\Q            series.pendingCommit = false\E\n\Q        }\E\n\Q    }\E~            series.pendingCommit = false\n        }\n    }~' "$HA"; run "commitFloats never cleans up old append IDs"
perl -0pi -e 's~\Q            let series = b.floatSeries[i]\E~            let series = b.floatSeries[0]~' "$HA"; run "every sample is committed to the FIRST series of the batch"

echo "=== Rollback ==="
perl -0pi -e 's~\Q        batches = []\E\n\Q        try log()\E~        try log()\n        batches = []~' "$HA"; run "rollback logs the samples as well as the series"
perl -0pi -e 's~\Q        batches = []\E\n\Q        try log()\E~        batches = []~' "$HA"; run "rollback logs nothing at all"
perl -0pi -e 's~\Q        if closed {\E\n\Q            throw HeadError.appenderClosed\E\n\Q        }\E\n\Q        defer {\E~        defer {~' "$HA"; run "rollback can be called twice"
perl -0pi -e 's~\Q                series.pendingCommit = false\E\n\Q            }\E\n\Q        }\E\n\Q        // Truncated BEFORE the log\E~            }\n        }\n        \/\/ Truncated BEFORE the log~' "$HA"; run "rollback leaves the samples' series marked pending"
perl -0pi -e 's~\Q            head.iso.closeAppend(appendID)\E\n\Q            closed = true\E~            closed = true~' "$HA"; run "rollback does not close the isolation append"

echo "=== handleAppendableError ==="
perl -0pi -e 's~\Q            appended -= 1\E\n\Q            oooRejected += 1\E~            oooRejected += 1~' "$HA"; run "an out-of-order rejection does not reduce the appended count"
perl -0pi -e 's~\Q    appended -= 1\E\n\Q}\E~}~' "$HA"; run "an unclassified error does not reduce the appended count"

# ---------------------------------------------------------------------------------------------------
# 74 controls: 65 broke, 9 SURVIVED, 0 SKIP, 0 COMPILE.
#
# The first run scored 50/74 with 23 survivors, and closing them taught the corpus four things it could
# not otherwise reach:
#
#   * **Two appenders have to OVERLAP.** `commitFloats` re-checks `appendable`, and the answer can only
#     differ from `Append`'s if another transaction committed in between — so the input gained an
#     `interleaved` mode that opens every appender before any append.
#   * **A duplicate label NAME cannot come from a map.** `labels.FromMap` de-duplicates by construction;
#     `FromStrings` does not. The input therefore takes a flat pair list as well.
#   * **`headMaxt` is only visible through the OOO window.** It appears in exactly one decision,
#     `t >= headMaxt - oooTimeWindow`, so distinguishing it needs a head whose minTime is far below its
#     maxTime and a sample just outside the real window.
#   * **The compaction-window floor moves.** `appendableMinValidTime` is `max(maxTime - chunkRange/2,
#     minValidTime)`, so a sample that was fine early in a program is out of bounds later — which needs
#     a program, not a list.
#
# One survivor is DELIBERATE (the harness check). The other eight split three ways.
#
# METRICS-ONLY, so unobservable until Phase 9 — and this is the largest family:
#
#   * `commitFloats does not re-check appendable`, `an out-of-order rejection does not reduce the
#     appended count`, `an unclassified error does not reduce the appended count`. The second
#     `appendable` call and the whole `appenderCommitContext` counter set feed `headMetrics` and nothing
#     else: when the verdict changes between Append and Commit, `memSeries.append` ALSO rejects the
#     sample (a duplicate timestamp fails its own `c.maxTime >= t` test), so the chunk contents, the WAL
#     and every accessor agree either way. The counters are the only difference, and the registry is
#     Phase 9. Keep the code — it is what the metrics will read — but do not expect these to break
#     before then.
#
# TAUTOLOGIES:
#
#   * `initTime sets minTime before maxTime`. The order is a CONCURRENCY contract: upstream's comment
#     explains that setting `minTime` first would let another goroutine see `initialized() == true` with
#     `maxTime` still at `MinInt64`. Single-threaded, both orders compute the same two fields. Kept
#     because the port will grow a concurrency model and the comment is the reason.
#   * `a new batch does not clear the type map` and `getCurrentBatch returns the FIRST batch`. A
#     float-only append never creates a second batch — `stFloat` is deliberately not recorded in
#     `typesInBatch`, so `!ok && st == .float` matches every sample. Both controls need two batches,
#     which needs the histogram append path (deferred). They must break when it lands.
#
# NEEDS FAULT INJECTION, or a later slice:
#
#   * `a WAL failure does not roll the append back`. Reaching `Commit`'s `write to WAL: %w` arm needs a
#     WAL whose `Log` fails, which neither side's harness can produce today (Go would need a read-only
#     directory mid-run; `InMemoryFS` has no failure mode). The arm is three lines and its message is
#     pinned by `WALLogError`.
#   * `rollback does not close the isolation append`. Leaking an open append ID is observable only to a
#     truncation that waits on overlapping appenders (`WaitForAppendersOverlapping`), which arrives with
#     §7h/§7j. An open append does NOT hold the low watermark back — only an open READ does (§7f(a)) —
#     which is exactly why this one cannot be seen yet.
