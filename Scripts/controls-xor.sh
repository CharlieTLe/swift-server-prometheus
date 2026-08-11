#!/usr/bin/env bash
# Negative controls for tsdb/chunkenc/xor.go AND tsdb/chunkenc/bstream.go.
#
# Both files at once, because the XOR corpus is what pins the bit stream: `bstream` is unexported
# upstream so it has no corpus of its own, and a chunk's bytes ARE what the stream wrote. HANDOFF §5d
# called the two one unit of verification; this script is that unit's control sweep.
set -uo pipefail
cd "$(dirname "$0")/.."
X=Sources/PromChunkEnc/XORChunk.swift
B=Sources/PromChunkEnc/Bstream.swift
cp "$X" /tmp/x.orig && cp "$B" /tmp/b.orig
restore() { cp /tmp/x.orig "$X"; cp /tmp/b.orig "$B"; }
trap restore EXIT

run() {
  local name="$1"
  if ! swift build 2>/dev/null >/dev/null; then printf '  %-52s COMPILE\n' "$name"; restore; return; fi
  local out; out=$(swift test --filter 'XORChunk' 2>&1)
  if grep -qE '✘|error:|signal' <<<"$out"; then printf '  %-52s broke\n' "$name"
  else printf '  %-52s SURVIVED\n' "$name"; fi
  restore
}

echo "=== the header count ==="
perl -0pi -e 's/        chunk\.b\.putBigEndianUInt16\(at: 0, num \+ 1\)//' "$X"; run "the sample count is not written back"
perl -0pi -e 's/        stream\[i\] = UInt8\(truncatingIfNeeded: v >> 8\)\n        stream\[i \+ 1\] = UInt8\(truncatingIfNeeded: v\)/        stream[i] = UInt8(truncatingIfNeeded: v)\n        stream[i + 1] = UInt8(truncatingIfNeeded: v >> 8)/' "$B"; run "the header count is little-endian"

echo "=== bitRange's asymmetry ==="
perl -0pi -e 's/    -\(\(1 << \(Int64\(nbits\) - 1\)\) - 1\) <= x && x <= 1 << \(Int64\(nbits\) - 1\)/    -(1 << (Int64(nbits) - 1)) <= x \&\& x < 1 << (Int64(nbits) - 1)/' "$X"; run "bitRange is symmetric two's complement"
perl -0pi -e 's/    -\(\(1 << \(Int64\(nbits\) - 1\)\) - 1\) <= x && x <= 1 << \(Int64\(nbits\) - 1\)/    -((1 << (Int64(nbits) - 1)) - 1) <= x \&\& x < 1 << (Int64(nbits) - 1)/' "$X"; run "bitRange excludes its upper bound"

echo "=== the delta-of-delta buckets ==="
perl -0pi -e 's/            \} else if bitRange\(dod, 14\) \{/            } else if false {/' "$X"; run "the 14-bit bucket is skipped"
perl -0pi -e 's/            \} else if bitRange\(dod, 17\) \{/            } else if false {/' "$X"; run "the 17-bit bucket is skipped"
perl -0pi -e 's/            \} else if bitRange\(dod, 20\) \{/            } else if false {/' "$X"; run "the 20-bit bucket is skipped"
perl -0pi -e 's/chunk\.b\.writeBits\(0b110, 3\)/chunk.b.writeBits(0b110, 4)/' "$X"; run "the 17-bit size code is 4 bits wide"
perl -0pi -e 's/0b10 << 6 \| \(UInt8\(truncatingIfNeeded: dod >> 8\) & \(1 << 6 - 1\)\)/0b10 << 6 | UInt8(truncatingIfNeeded: dod >> 8)/' "$X"; run "the 14-bit case does not mask the high byte"
perl -0pi -e 's/            if bits > \(1 << \(UInt64\(sz\) - 1\)\) \{/            if bits >= (1 << (UInt64(sz) - 1)) {/' "$X"; run "the sign extension uses >= not >"

echo "=== the value encoder ==="
perl -0pi -e 's/    if newLeading >= 32 \{\n        newLeading = 31\n    \}//' "$X"; run "leading zeros are not clamped to 31"
perl -0pi -e 's/    if newLeading >= 32 \{\n        newLeading = 31\n    \}/    if newLeading >= 32 {\n        newLeading = 32\n    }/' "$X"; run "leading zeros are clamped to 32 not 31"
perl -0pi -e 's/    if leading != 0xff && newLeading >= leading && newTrailing >= trailing \{/    if leading != 0xff \&\& newLeading >= leading {/' "$X"; run "the window reuse ignores trailing"
perl -0pi -e 's/    b\.writeBits\(UInt64\(newLeading\), 5\)/    b.writeBits(UInt64(newLeading), 6)/' "$X"; run "the leading count is written in 6 bits"
perl -0pi -e 's/    b\.writeBits\(UInt64\(sigbits\), 6\)/    b.writeBits(UInt64(sigbits), 5)/' "$X"; run "sigbits is written in 5 bits"
perl -0pi -e 's/        if mbits == 0 \{\n            mbits = 64\n        \}//' "$X"; run "0 sigbits is not read back as 64"
perl -0pi -e 's/    if delta == 0 \{\n        b\.writeBit\(false\)\n        return\n    \}//' "$X"; run "an unchanged value still writes a full delta"

echo "=== the appender replay ==="
perl -0pi -e 's/            return XORAppender\(chunk: self, t: Int64\.min, leading: 0xff\)/            return XORAppender(chunk: self, t: Int64.min, leading: 0)/' "$X"; run "the empty-chunk leading sentinel is 0 not 0xff"
perl -0pi -e 's/        return XORAppender\(\n            chunk: self, t: it\.t, v: it\.val, tDelta: it\.tDelta, leading: it\.leading,\n            trailing: it\.trailing\)/        return XORAppender(chunk: self, t: it.t, v: it.val, tDelta: it.tDelta)/' "$X"; run "the replay drops the leading\/trailing window"
perl -0pi -e 's/        var it = iterator\(\)\n        while it\.next\(\) != \.none \{\}/        var it = iterator()\n        _ = it.next()/' "$X"; run "the replay stops after one sample"

echo "=== bstream: the masks and the free-bit count ==="
perl -0pi -e 's/        let bitmask = \(UInt64\(1\) << nbits\) &- 1\n        valid -= nbits/        let bitmask = (UInt64(1) << nbits) - 1\n        valid -= nbits/' "$B"; run "readBitsFast uses trapping subtraction"
perl -0pi -e 's/        if streamOffset \+ 8 < stream\.count \{/        if streamOffset + 8 <= stream.count {/' "$B"; run "loadNextBuffer may read the final byte"
perl -0pi -e 's/            newBuffer \|= UInt64\(last\)/            newBuffer |= UInt64(stream[stream.count - 1])/' "$B"; run "the reader reads the live last byte, not its copy"
# ^ BOTH SURVIVE, and the argument is that they are RACE-AVOIDANCE rather than value behaviour.
#
# 23 append-while-reading cases were added to try to kill them and did not, which is itself the
# finding. An iterator captures `numTotal` at creation, so it never reads the samples appended after
# it; the bits it does read live in bytes the appender only EXTENDS, never rewrites — an append fills
# the free low bits of the final partial byte and leaves the used high bits alone. So the copy and the
# live byte agree on every bit the reader consumes, and differ only in bits it masks off.
#
# What the copy prevents is therefore a DATA RACE, not a wrong answer, and a race has no defined value
# to compare against. Pinning it needs real concurrency — an appender and a querier on the same chunk —
# which is Phase 7's Head, not this slice's. Kept because upstream's comment is explicit about why it
# exists, and because removing it would trade a documented safety property for nothing.
