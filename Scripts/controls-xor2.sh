#!/usr/bin/env bash
# Negative controls for xor2.go, and for varbit.go which it is the only corpus route to.
set -uo pipefail
cd "$(dirname "$0")/.."
X=Sources/PromChunkEnc/XOR2Chunk.swift
V=Sources/PromChunkEnc/Varbit.swift
B=Sources/PromChunkEnc/Bstream.swift
cp "$X" /tmp/x2.orig && cp "$V" /tmp/v.orig && cp "$B" /tmp/b2.orig
restore() { cp /tmp/x2.orig "$X"; cp /tmp/v.orig "$V"; cp /tmp/b2.orig "$B"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'XOR2Chunk|Varbit' 54
  restore
}

echo "=== the ST header ==="
perl -0pi -e 's/    b\.setByte\(at: chunkHeaderSize, 0x80\)/    b.setByte(at: chunkHeaderSize, 0x40)/' "$X"; run "firstSTKnown is bit 6 not bit 7"
perl -0pi -e 's/    if firstSTChangeOn > maxFirstSTChangeOn \{\n        return\n    \}//' "$X"; run "the header write does not guard 0x7F"
# ^ SURVIVES, ARGUED as unreachable. `Append` forces the slow path at `numTotal == maxFirstSTChangeOn`
# precisely so the header is written while the index still fits in seven bits, so
# `writeHeaderFirstSTChangeOn` is never called above 0x7F. Upstream's comment says the same ("should
# never happen, would cause corruption"). The guard is a belt against a future caller, not live code —
# and note the control for the FORCING (`the 0x7F forced slow path is removed`) does break, which is
# what makes this one safe to leave unpinned.
perl -0pi -e 's/    if b\[i\] == 0x80 \{ return \(true, 0\) \}//' "$X"; run "readSTHeader loses its 0x80 fast path"
# ^ SURVIVES, ARGUED as identical: `0x80` falls through to `(b[i] & 0x80 != 0, b[i] & 0x7F)` = `(true, 0)`,
# which is what the fast path returns. Pure speed.
perl -0pi -e 's/    return \(b\[i\] & 0x80 != 0, b\[i\] & 0x7F\)/    return (b[i] \& 0x80 != 0, b[i] \& 0x3F)/' "$X"; run "firstSTChangeOn is masked to 6 bits"

echo "=== sample 127's forced slow path ==="
perl -0pi -e 's/if firstSTChangeOn == 0 && st == self\.st && numTotal != maxFirstSTChangeOn \{/if firstSTChangeOn == 0 \&\& st == self.st {/' "$X"; run "the 0x7F forced slow path is removed"
perl -0pi -e 's/            if st != self\.st \|\| numTotal == maxFirstSTChangeOn \{/            if st != self.st {/' "$X"; run "the slow path does not write the header at 0x7F"

echo "=== the dod bins: two's complement, NOT bitRange ==="
perl -0pi -e 's/        if dod >= -\(1 << 12\) && dod <= \(1 << 12\) - 1 \{/        if bitRange(dod, 13) {/' "$X"; run "encodeJoint uses bitRange for the 13-bit bin"
perl -0pi -e 's/        \} else if dod >= -\(1 << 19\) && dod <= \(1 << 19\) - 1 \{/        } else if bitRange(dod, 20) {/' "$X"; run "encodeJoint uses bitRange for the 20-bit bin"
perl -0pi -e 's/                0b110_00000 \| UInt8\(truncatingIfNeeded: UInt64\(bitPattern: dod\) >> 8\) & 0x1F\)/                0b110_00000 | UInt8(truncatingIfNeeded: UInt64(bitPattern: dod) >> 8) \& 0x3F)/' "$X"; run "the 13-bit dod high byte masks 6 bits"
perl -0pi -e 's/                0b1110_0000 \| UInt8\(truncatingIfNeeded: UInt64\(bitPattern: dod\) >> 16\) & 0x0F\)/                0b1110_0000 | UInt8(truncatingIfNeeded: UInt64(bitPattern: dod) >> 16) \& 0x1F)/' "$X"; run "the 20-bit dod high byte masks 5 bits"
perl -0pi -e 's/        if w < 64 && b >= \(1 << \(UInt64\(w\) - 1\)\) \{/        if w < 64 \&\& b > (1 << (UInt64(w) - 1)) {/' "$X"; run "readDod sign-extends with > not >="
perl -0pi -e 's/        if w < 64 && b >= \(1 << \(UInt64\(w\) - 1\)\) \{/        if b >= (1 << (UInt64(w) - 1)) {/' "$X"; run "readDod sign-extends at 64 bits too"
# ^ SURVIVES, ARGUED as a no-op. At `w == 64` the correction is `b -= 1 << 64`, and `1 << 64` is 0 in
# both Go and Swift, so the subtraction changes nothing whether or not the guard runs. Kept because it
# states the intent, and because a 63-bit width would make it live.

echo "=== both stale-NaN spellings ==="
perl -0pi -e 's/                chunk\.b\.writeBitsFast\(0b11111, 5\)/                chunk.b.writeBitsFast(0b11110, 5)/' "$X"; run "the dod=0 stale prefix is 11110"
perl -0pi -e 's/            chunk\.b\.writeBitsFast\(0b111, 3\)/            chunk.b.writeBitsFast(0b110, 3)/' "$X"; run "the value-code stale is 110"
perl -0pi -e 's/        if PromValue\.isStaleNaN\(v\) \{\n            chunk\.b\.writeBitsFast\(0b111, 3\)\n            return\n        \}//' "$X"; run "writeVDelta does not special-case stale"

echo "=== baselineV versus val ==="
perl -0pi -e 's/            if !PromValue\.isStaleNaN\(val\) \{ baselineV = val \}/            baselineV = val/' "$X"; run "a stale first sample becomes the baseline"
perl -0pi -e 's/        if !PromValue\.isStaleNaN\(v\) \{ self\.v = v \}\n        self\.tDelta = tDelta/        self.v = v\n        self.tDelta = tDelta/' "$X"; run "the appender lets a stale value become the baseline"
perl -0pi -e 's/            chunk: self, st: it\.st, t: it\.t, v: it\.baselineV,/            chunk: self, st: it.st, t: it.t, v: it.val,/' "$X"; run "the replay lifts val instead of baselineV"

echo "=== the appender's restored bit position ==="
perl -0pi -e 's/        b\.restoreBitPosition\(it\.br\.valid\)//' "$X"; run "the write bit position is not restored"

echo "=== the fused ST widths ==="
perl -0pi -e 's/                \(0b10 << 3\) \| \(UInt64\(bitPattern: deltaStDiff\) & 0x7\), 5 \+ Int\(extra\)\)/                (0b10 << 3) | (UInt64(bitPattern: deltaStDiff) \& 0x7), 5)/' "$X"; run "the fused 5-bit ST bucket drops its extra bit"
perl -0pi -e 's/            for _ in 0\.\.<\(leadingZeroBits \+ 1\) \{ chunk\.b\.writeBit\(false\) \}/            chunk.b.writeBit(false)/' "$X"; run "the zero ST delta writes one bit not two"
perl -0pi -e 's/            for _ in 0\.\.<leadingZeroBits \{ chunk\.b\.writeBit\(false\) \}\n            putVarbitIntFast/            putVarbitIntFast/' "$X"; run "the varbit fallback drops its leading zero bit"

echo "=== the accumulated ST diff ==="
perl -0pi -e 's/                if savedNumRead == UInt16\(firstSTChangeOn\) \{\n                    stDiff = sdod\n                \} else \{\n                    stDiff = stDiff &\+ sdod\n                \}/                stDiff = stDiff \&+ sdod/' "$X"; run "the first ST delta accumulates instead of setting"
# ^ SURVIVES, ARGUED as identical. `savedNumRead == firstSTChangeOn` is true only at the sample where ST
# deltas BEGIN, and `stDiff` is still 0 there: `reset` zeroes it, and the only other writer is the
# `numRead == 1` branch, which runs only when `firstSTChangeOn == 1` and then returns — so by the time
# the general path first reads a delta, `stDiff + sdod == sdod`. The distinction becomes live the moment
# an iterator is reused without a reset, which is why upstream writes it explicitly.
perl -0pi -e 's/                st = prevT &- stDiff/                st = t \&- stDiff/' "$X"; run "the ST is computed from t not prevT"

echo "=== varbit, reached through the ST deltas ==="
perl -0pi -e 's/    \} else if bitRange\(val, 3\) \{\n        b\.writeBitsFast\(\(0b10 << 3\) \| \(uval & 0x7\), 5\)/    } else if bitRange(val, 3) {\n        b.writeBitsFast((0b10 << 3) | (uval \& 0xF), 5)/' "$V"; run "putVarbitIntFast's 3-bit mask is 4 bits wide"
perl -0pi -e 's/    if bits > \(1 << \(UInt64\(sz\) - 1\)\) \{/    if bits >= (1 << (UInt64(sz) - 1)) {/' "$V"; run "readVarbitInt sign-extends with >="
perl -0pi -e 's/    case 0b111110: return 18/    case 0b111110: return 17/' "$V"; run "the 18-bit varbit bucket reads 17 bits"

echo "=== bstream's XOR2 control readers ==="
perl -0pi -e 's/        if top4 < 12 \{  \/\/ `10xx`: dod=0, value changed\.\n            valid -= 2\n            return 1\n        \}/        if top4 < 12 {\n            valid -= 1\n            return 1\n        }/' "$B"; run "the 10xx control consumes one bit"
perl -0pi -e 's/                return 4 \+ bit4/                return 5 - bit4/' "$B"; run "the fifth control bit is inverted"
perl -0pi -e 's/        if valid < 4 \{\n            return nil\n        \}/        if valid < 5 {\n            return nil\n        }/' "$B"; run "readXOR2ControlFast needs five bits"
# ^ SURVIVES, ARGUED: the fast path only ever declines more often, and `readXOR2Control` computes the
# same answer from the same bits. Pure speed, like the `readBitFast`/`readBit` pair in §6a.
