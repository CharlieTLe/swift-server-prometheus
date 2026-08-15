#!/usr/bin/env bash
# Negative controls for `tsdb/isolation.go`.
#
# The tests here are NOT differential — `isolation`, `isolationState` and `txRing` are unexported upstream and
# nothing on `Head`'s exported surface reaches them until §7g. Their expectations were verified against a
# standalone Go probe of upstream's own `isolation.go` (see the test file header), which makes them evidence
# rather than a reading — but a verified expectation is still only as good as its coverage, so this sweep asks
# the usual question: which of these lines can the tests actually see?
#
# Four clusters: the sentinel-as-counter trick, the watermark's two fallbacks, the read list's ordering, and
# the ring's growth and cleanup.
set -uo pipefail
cd "$(dirname "$0")/.."
IS=Sources/PromHead/Isolation.swift
cp "$IS" /tmp/iso-is.orig
restore() { cp /tmp/iso-is.orig "$IS"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  if cmp -s "$IS" /tmp/iso-is.orig
  then
    printf "  %-62s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'IsolationTests' 62
  restore
}

echo "=== the sentinel as counter ==="
perl -0pi -e 's/        appendsOpenList\.appendID \+= 1/        \/\/ perturbed: counter not advanced/' "$IS"; run "the append counter never advances"
perl -0pi -e 's/        appendsOpenList\.appendID \+= 1\n\n        let app = IsolationAppender\(\)\n        app\.appendID = appendsOpenList\.appendID/        let app = IsolationAppender()\n        app.appendID = appendsOpenList.appendID\n        appendsOpenList.appendID += 1/' "$IS"; run "the counter is POST-incremented, so the first id is 0"
perl -0pi -e 's/        return appendsOpenList\.appendID\n    \}\n\n    \/\/\/ Go: `closeAppend`/        return appendsOpen.keys.max() ?? 0\n    }\n\n    \/\/\/ Go: `closeAppend`/' "$IS"; run "lastAppendID reads the open appenders rather than the sentinel"

echo "=== the watermark's two fallbacks ==="
perl -0pi -e 's/        if readsOpen\.prev !== readsOpen \{\n            return readsOpen\.prev!\.lowWatermark\n        \}//' "$IS"; run "an open read does not pin the watermark"
perl -0pi -e 's/            return readsOpen\.prev!\.lowWatermark/            return readsOpen.next!.lowWatermark/' "$IS"; run "the NEWEST open read pins the watermark, not the oldest"
perl -0pi -e 's/        return appendsOpenList\.next!\.appendID\n    \}/        return appendsOpenList.prev!.appendID\n    }/' "$IS"; run "the watermark falls back to the HIGHEST open appender"
perl -0pi -e 's/        return \(app\.appendID, lowWatermarkLocked\(\)\)/        return (app.appendID, app.appendID)/' "$IS"; run "newAppendID returns its own id as the watermark"
perl -0pi -e 's/    public func lowWatermark\(\) -> UInt64 \{\n        if disabled \{ return 0 \}/    public func lowWatermark() -> UInt64 {\n        if false { return 0 }/' "$IS"; run "a disabled isolation reports a real watermark"

echo "=== State, and the disabled asymmetry ==="
perl -0pi -e 's/        isoState\.maxAppendID = appendsOpenList\.appendID/        isoState.maxAppendID = appendsOpenList.next!.appendID/' "$IS"; run "State's max comes from the lowest appender rather than the counter"
perl -0pi -e 's/        isoState\.lowWatermark = appendsOpenList\.next!\.appendID/        isoState.lowWatermark = appendsOpenList.appendID/' "$IS"; run "State's watermark is the counter rather than the lowest appender"
perl -0pi -e 's/        isoState\.incompleteAppends = Set\(appendsOpen\.keys\)/        isoState.incompleteAppends = []/' "$IS"; run "State does not record the in-flight appends"
perl -0pi -e 's/    public func state\(mint: Int64, maxt: Int64\) -> IsolationState \{\n        let isoState = IsolationState\(\)/    public func state(mint: Int64, maxt: Int64) -> IsolationState {\n        let isoState = IsolationState()\n        if disabled { return isoState }/' "$IS"; run "a disabled isolation stops tracking reads too"
perl -0pi -e 's/        if disabled \{ return \}\n        guard let app = appendsOpen\[appendID\] else \{ return \}/        guard let app = appendsOpen[appendID] else { return }/' "$IS"; run "closeAppend runs even when disabled"

echo "=== the read list's ordering and unlinking ==="
perl -0pi -e 's/        isoState\.prev = readsOpen\n        isoState\.next = readsOpen\.next\n        readsOpen\.next!\.prev = isoState\n        readsOpen\.next = isoState/        isoState.next = readsOpen\n        isoState.prev = readsOpen.prev\n        readsOpen.prev!.next = isoState\n        readsOpen.prev = isoState/' "$IS"; run "reads are linked in at the tail rather than the head"
perl -0pi -e 's/        next\?\.prev = prev\n        prev\?\.next = next/        \/\/ perturbed: not unlinked/' "$IS"; run "closing a read does not unlink it"
perl -0pi -e 's/        var s = readsOpen\.next!\n        while s !== readsOpen \{/        var s = readsOpen.prev!\n        while s !== readsOpen {/' "$IS"; run "TraverseOpenReads walks the other way"
perl -0pi -e 's/            if !f\(s\) \{ return \}/            _ = f(s)/' "$IS"; run "TraverseOpenReads ignores an early exit"

echo "=== lowestAppendTime ==="
perl -0pi -e 's/        var lowest = Int64\.max/        var lowest = Int64.min/' "$IS"; run "lowestAppendTime starts at MinInt64"
perl -0pi -e 's/            if lowest > a\.minTime \{ lowest = a\.minTime \}/            if lowest < a.minTime { lowest = a.minTime }/' "$IS"; run "lowestAppendTime takes the highest minTime"

echo "=== the ring's growth ==="
perl -0pi -e 's/            var newLen = txIDCount \* 2\n            if newLen == 0 \{ newLen = 4 \}/            var newLen = txIDCount * 2\n            if newLen == 0 { newLen = 1 }/' "$IS"; run "a zero-capacity ring grows to one rather than four"
perl -0pi -e 's/            var newLen = txIDCount \* 2/            var newLen = txIDCount + 1/' "$IS"; run "the ring grows by one rather than doubling"
perl -0pi -e 's/            var idx = 0\n            for k in Int\(txIDFirst\)\.\.<txIDs\.count \{\n                newRing\[idx\] = txIDs\[k\]\n                idx \+= 1\n            \}\n            for k in 0\.\.<Int\(txIDFirst\) \{\n                newRing\[idx\] = txIDs\[k\]\n                idx \+= 1\n            \}/            for k in 0..<txIDs.count { newRing[k] = txIDs[k] }/' "$IS"; run "growth copies in physical order rather than un-wrapping"
perl -0pi -e 's/            txIDFirst = 0\n        \}/        }/' "$IS"; run "growth does not reset the cursor"
perl -0pi -e 's/        txIDs\[\(Int\(txIDFirst\) \+ Int\(txIDCount\)\) % txIDs\.count\] = appendID/        txIDs[Int(txIDCount) % txIDs.count] = appendID/' "$IS"; run "add ignores the ring's start offset"

echo "=== the ring's cleanup and iterator ==="
perl -0pi -e 's/            if txIDs\[pos\] >= bound \{ break \}/            if txIDs[pos] > bound { break }/' "$IS"; run "cleanup also drops an id equal to the bound"
perl -0pi -e 's/            if txIDs\[pos\] >= bound \{ break \}//' "$IS"; run "cleanup drops everything regardless of the bound"
perl -0pi -e 's/        if txIDs\.isEmpty \{ return \}//' "$IS"; run "cleanup does not guard an empty ring"
perl -0pi -e 's/        txIDFirst %= UInt32\(txIDs\.count\)//' "$IS"; run "cleanup leaves the cursor past the end"
perl -0pi -e 's/            txIDFirst \+= 1\n            txIDCount -= 1/            txIDCount -= 1/' "$IS"; run "cleanup drops the count without advancing the cursor"
perl -0pi -e 's/    public mutating func next\(\) \{\n        pos \+= 1\n        if Int\(pos\) == ids\.count \{ pos = 0 \}/    public mutating func next() {\n        pos += 1/' "$IS"; run "the iterator does not wrap"
perl -0pi -e 's/        TxRingIterator\(ids: txIDs, pos: txIDFirst\)/        TxRingIterator(ids: txIDs, pos: 0)/' "$IS"; run "the iterator starts at 0 rather than at the ring's first"

# ---------------------------------------------------------------------------------------------------
# 31 controls: 28 broke, 3 SURVIVED, 0 SKIP — and all three survivors are PROOFS.
#
#   * `a disabled isolation reports a real watermark` — the guard removed is the OUTER one, and
#     `lowWatermarkLocked()` opens with the same `if disabled { return 0 }`. So the two interlock and
#     either alone is sufficient. **Upstream has the same redundancy**, which is why the port keeps it
#     rather than "simplifying": quirk 65's shape, where the pair is the unit of evidence. The control
#     that matters is the one on the inner guard, and that is not this one.
#
#   * `closeAppend runs even when disabled` — unreachable rather than harmless. When isolation is
#     disabled `newAppendID` returns `(0, 0)` and never inserts, so `appendsOpen` is always empty and the
#     `guard let app = appendsOpen[appendID]` returns on its own. Removing the early return changes
#     nothing because there is never anything to close.
#
#   * `cleanup leaves the cursor past the end` — the trailing `txIDFirst %= txIDs.count`. It matters
#     only when the cursor walks past the array end, which needs a non-zero start AND every id dropped
#     (e.g. first=6, count=4 in an 8-ring leaves first=10). Even then `add` is unaffected, because it
#     recomputes `(first + count) % len` and 10 % 8 == 2 either way. The one caller that WOULD see it is
#     `iterator()`, which seeds `pos` from `txIDFirst` and would index out of range — but the ring is
#     empty at that point and every caller bounds its walk by `txIDCount`, so `at()` is never called.
#     A proof resting on caller discipline rather than on this file, so it is the weakest of the three;
#     the modulo stays because upstream has it and because it keeps the invariant local to the ring.
