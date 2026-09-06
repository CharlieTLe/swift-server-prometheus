#!/usr/bin/env bash
# Negative controls for §7k — the two native-histogram chunk encodings and the layout codecs under them.
#
#   Sources/PromChunkEnc/HistogramChunk.swift       tsdb/chunkenc/histogram.go
#   Sources/PromChunkEnc/FloatHistogramChunk.swift  tsdb/chunkenc/float_histogram.go
#   Sources/PromChunkEnc/HistogramLayout.swift      tsdb/chunkenc/histogram_meta.go (the encoding half)
#
# The corpora are `Fixtures/chunkenc/histogram.jsonl` and `Fixtures/chunkenc/float-histogram.jsonl`, both
# driven through the real `AppendHistogram`/`AppendFloatHistogram` and committing the chunk BYTES, the
# counter-reset header, the caller's histogram after each append, four read-back paths and a replay append.
# So a perturbation that changes what gets encoded is a byte diff, and one that changes only a decision — a
# cut where there should be a recode, say — is a header or step diff.
#
# Traps, all inherited from earlier sweeps (see `controls-headwaltruncate.sh`'s header for the two perl ones):
#
#   * `\Q…\E` cannot contain a `$` or a `\`, so a pattern can never include a Swift interpolation or an
#     escaped paren. Match a substring on one side of it.
#   * `\Q…\E` does not interpret `\n`; a multi-line pattern needs `\E\n\Q` between the lines.
#   * a control that patches a DOC COMMENT measures nothing. Several strings here appear in both the code and
#     the comment above it, so the patterns carry enough context to be unique.
#   * check the indentation. Most of these lines sit two or three levels deep.
#   * `SKIP (patch did not apply)` is the only thing that catches a stale pattern, hence the `cmp` below.
set -uo pipefail
cd "$(dirname "$0")/.."
H=Sources/PromChunkEnc/HistogramChunk.swift
F=Sources/PromChunkEnc/FloatHistogramChunk.swift
L=Sources/PromChunkEnc/HistogramLayout.swift
# The fourth file is PromBlock's: §7k made `populateCurrForSingleChunk`'s two histogram arms reachable, and
# they are the port's only consumer of these encodings until the Head grows a histogram append path.
P=Sources/PromBlock/PopulateIterators.swift
cp "$H" /tmp/hgc-h.orig
cp "$F" /tmp/hgc-f.orig
cp "$L" /tmp/hgc-l.orig
cp "$P" /tmp/hgc-p.orig
restore() { cp /tmp/hgc-h.orig "$H"; cp /tmp/hgc-f.orig "$F"; cp /tmp/hgc-l.orig "$L"; cp /tmp/hgc-p.orig "$P"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# run <file> <name>
run() {
  local f="$1" name="$2" orig
  case "$f" in
    "$H") orig=/tmp/hgc-h.orig ;;
    "$F") orig=/tmp/hgc-f.orig ;;
    "$L") orig=/tmp/hgc-l.orig ;;
    "$P") orig=/tmp/hgc-p.orig ;;
  esac
  if cmp -s "$f" "$orig"
  then
    printf "  %-72s SKIP (patch did not apply)\n" "$name"
    restore
    return
  fi
  control_verdict "$name" 'HistogramChunkTests|FloatHistogramChunkTests|HistogramChunkEdgeTests|ChunkConformanceTests|PopulateHistogramReencodeTests' 72
  restore
}

echo "=== the three-byte header ==="
perl -0pi -e 's~\Qlet histogramHeaderSize = 3\E~let histogramHeaderSize = 2~' "$L"; run "$L" "the histogram header is two bytes"
perl -0pi -e 's~\Qlet histogramFlagPos = 2\E~let histogramFlagPos = 1~' "$L"; run "$L" "the flag byte is at index 1"
perl -0pi -e 's~\Qlet counterResetHeaderMask: UInt8 = 0b1100_0000\E~let counterResetHeaderMask: UInt8 = 0b1110_0000~' "$L"; run "$L" "the counter-reset mask is three bits"
perl -0pi -e 's{\Q(old & ~counterResetHeaderMask) | (cr.rawValue & counterResetHeaderMask))\E}{cr.rawValue)}' "$H"; run "$H" "setCounterResetHeader clobbers the rest of the flag byte"

echo "=== the layout header, and the two bespoke codecs under it ==="
perl -0pi -e 's~\Q    putZeroThreshold(&b, zeroThreshold)\E\n\Q    putVarbitInt(&b, Int64(schema))\E~    putVarbitInt(\&b, Int64(schema))\n    putZeroThreshold(\&b, zeroThreshold)~' "$L"; run "$L" "the layout writes the schema before the threshold"
perl -0pi -e 's~\Q    putVarbitUint(&b, UInt64(s.length))\E\n\Q        putVarbitInt(&b, Int64(s.offset))\E~    putVarbitInt(\&b, Int64(s.offset))\n        putVarbitUint(\&b, UInt64(s.length))~' "$L"; run "$L" "a span writes offset before length"
perl -0pi -e 's~\Q    if isCustomBucketsSchema(schema) {\E\n\Q        putHistogramChunkLayoutCustomBounds(&b, customValues ?? [])\E~    if true {\n        putHistogramChunkLayoutCustomBounds(\&b, customValues ?? [])~' "$L"; run "$L" "custom bounds are written for every schema"
perl -0pi -e 's~\Q    if frac != 0.5 || exp < -242 || exp > 11 {\E~    if frac != 0.5 || exp < -242 || exp > 10 {~' "$L"; run "$L" "the one-byte threshold range stops at 2^9"
perl -0pi -e 's~\Q    if frac != 0.5 || exp < -242 || exp > 11 {\E~    if frac != 0.5 || exp < -241 || exp > 11 {~' "$L"; run "$L" "the one-byte threshold range starts one exponent up"
perl -0pi -e 's~\Q    b.writeByte(UInt8(truncatingIfNeeded: exp + 243))\E~    b.writeByte(UInt8(truncatingIfNeeded: exp + 242))~' "$L"; run "$L" "the threshold exponent bias is 242"
perl -0pi -e 's~\Q        return GoMath.ldexp(0.5, Int(b) - 243)\E~        return GoMath.ldexp(1, Int(b) - 243)~' "$L"; run "$L" "readZeroThreshold reconstructs from 1 rather than 0.5"
perl -0pi -e 's~\Q    if tf < 0 || tf > 33_554_430 || !isWholeWhenMultiplied(f) {\E~    if tf < 0 || tf > 33_554_431 || !isWholeWhenMultiplied(f) {~' "$L"; run "$L" "the custom-bound varbit ceiling is one higher"
perl -0pi -e 's~\Q    if tf < 0 || tf > 33_554_430 || !isWholeWhenMultiplied(f) {\E~    if tf < 0 || tf > 33_554_430 {~' "$L"; run "$L" "putCustomBound skips the whole-multiple test"
perl -0pi -e 's~\Q    putVarbitUint(&b, UInt64(tf.rounded()) + 1)\E~    putVarbitUint(\&b, UInt64(tf.rounded()))~' "$L"; run "$L" "the custom bound is not offset by one"
perl -0pi -e 's~\Q        return Double(b - 1) / 1000\E~        return Double(b) / 1000~' "$L"; run "$L" "readCustomBound does not undo the offset"
perl -0pi -e 's~\Q    let r = (inValue * 1000).rounded()\E~    let r = (inValue * 1000).rounded(.down)~' "$L"; run "$L" "isWholeWhenMultiplied rounds down"

echo "=== countSpans and the bucket iterator's consumers ==="
perl -0pi -e 's~\Q        cnt += Int(s.length)\E~        cnt += Int(s.length) + Int(s.offset)~' "$L"; run "$L" "countSpans counts offsets too"

echo "=== insert: the deltas flag, and the two arms it selects ==="
perl -0pi -e 's~\Q                out[oi] = v.wrappingNegated\E\n\Q                firstInsert = false\E~                out[oi] = BV.zeroValue\n                firstInsert = false~' "$L"; run "$L" "a delta insert writes 0 rather than -v"
perl -0pi -e 's~\Q        if deltas {\E\n\Q            out[oi] = d.wrappingAdding(v)\E~        if false {\n            out[oi] = d.wrappingAdding(v)~' "$L"; run "$L" "the value after an insert is not re-based"
perl -0pi -e 's~\Q            if deltas && firstInsert {\E~            if deltas {~' "$L"; run "$L" "every insert in a run writes -v, not just the first"
perl -0pi -e 's~\Q        v = v.wrappingAdding(d)\E\n\Q    }\E\n\Q\E\n\Q    // Trailing inserts\E~        v = BV.zeroValue\n    }\n\n    // Trailing inserts~' "$L"; run "$L" "the running value is reset instead of accumulated"
perl -0pi -e 's~\Q        v = BV.zeroValue\E\n\Q    }\E\n\Q    return out\E~    }\n    return out~' "$L"; run "$L" "the trailing-insert loop does not zero the running value"
perl -0pi -e 's~\Qfunc insert<BV: BucketValueArithmetic>(\E~// INERT: a comment above the signature.\nfunc insert<BV: BucketValueArithmetic>(~' "$L"; run "$L" "INERT — a comment inserted above `insert`"

echo "=== the deltas flag at its four call sites ==="
perl -0pi -e 's~\Q                    hOld.positiveBuckets, positiveBuckets, positiveInserts, true)\E~                    hOld.positiveBuckets, positiveBuckets, positiveInserts, false)~' "$H"; run "$H" "the integer recode inserts as absolutes"
perl -0pi -e 's~\Q                hOld.positiveBuckets, positiveBuckets, positiveInserts, false)\E~                hOld.positiveBuckets, positiveBuckets, positiveInserts, true)~' "$F"; run "$F" "the float recode inserts as deltas"
perl -0pi -e 's~\Q                pBackwardInserts, true)\E~                pBackwardInserts, false)~' "$H"; run "$H" "the integer recodeHistogram inserts as absolutes"
perl -0pi -e 's~\Q                pBackwardInter, false)\E~                pBackwardInter, true)~' "$F"; run "$F" "the float recodeHistogram inserts as deltas"

echo "=== expandIntSpansAndBuckets: the accumulate-versus-assign line ==="
perl -0pi -e 's~\Q        if aOK { aCount = aCount &+ aBuckets[aCountIdx] }\E~        if aOK { aCount = aBuckets[aCountIdx] }~' "$H"; run "$H" "the integer walk ASSIGNS the bucket count (the float twin's line)"
perl -0pi -e 's~\Q        if bOK { bCount = bCount &+ bBuckets[bCountIdx] }\E~        if bOK { bCount = bBuckets[bCountIdx] }~' "$H"; run "$H" "the integer walk assigns b's bucket count"
perl -0pi -e 's~\Q    if aOK { aCount = aBuckets[aCountIdx] }\E\n\Q    if bOK { bCount = bBuckets[bCountIdx] }\E~    if aOK { aCount = 0 }\n    if bOK { bCount = bBuckets[bCountIdx] }~' "$H"; run "$H" "the integer walk starts a's count at zero"
perl -0pi -e 's~\Q                if aCount > bCount {\E~                if aCount >= bCount {~' "$H"; run "$H" "an equal bucket count is a reset"
perl -0pi -e 's~\Q                if aCount == 0 {\E\n\Q                    addInsert(&bInserts, &bInter, aIdx)\E~                if true {\n                    addInsert(\&bInserts, \&bInter, aIdx)~' "$H"; run "$H" "a used bucket may vanish from the sample"
perl -0pi -e 's~\Q        } else if insert.bucketIdx + insert.num != otherIdx {\E~        } else if false {~' "$H"; run "$H" "a discontinuous insert run is never flushed"
perl -0pi -e 's~\Q            addInsert(&aInserts, &aInter, bIdx)\E\n\Q                advanceB()\E~            addInsert(\&bInserts, \&bInter, bIdx)\n                advanceB()~' "$H"; run "$H" "growth is recorded as a backward insert"

echo "=== expandSpansBothWays and adjustForInserts (the gauge path) ==="
perl -0pi -e 's~\Q        if offset == 0 && !mergedSpans.isEmpty {\E~        if offset == 1 \&\& !mergedSpans.isEmpty {~' "$L"; run "$L" "addBucket extends a span at offset 1"
perl -0pi -e 's~\Q            if mergedSpans.isEmpty {\E\n\Q                offset += 1\E~            if false {\n                offset += 1~' "$L"; run "$L" "the first merged span is not offset by one"
perl -0pi -e 's~\Q        var offset = bucket - lastBucket - 1\E~        var offset = bucket - lastBucket~' "$L"; run "$L" "addBucket's offset is not relative to the previous bucket"
perl -0pi -e 's~\Q        } else {\E\n\Q            // A run of `num` inserts occupies CONSECUTIVE bucket indices from `bucketIdx`.\E\n\Q            insertIdx += 1\E~        } else {\n            insertIdx += 0~' "$L"; run "$L" "a run of inserts all lands on one bucket index"
perl -0pi -e 's~\Q        if i < inserts.count && insertIdx < bucket {\E~        if i < inserts.count \&\& insertIdx <= bucket {~' "$L"; run "$L" "adjustForInserts places an insert at an occupied index"
perl -0pi -e 's~\Q    if inserts.isEmpty {\E\n\Q        return spans\E~    if false {\n        return spans~' "$L"; run "$L" "adjustForInserts rebuilds even with no inserts"

echo "=== appendable's order of checks, integer ==="
perl -0pi -e 's~\Q        if h.count < cnt {\E~        if h.count <= cnt {~' "$H"; run "$H" "an equal count is a counter reset"
perl -0pi -e 's~\Q            return (none, none, none, none, false, .unknownCounterReset)\E\n\Q        }\E\n\Q        if isCustomBucketsSchema(h.schema)\E~            return (none, none, none, none, false, .notCounterReset)\n        }\n        if isCustomBucketsSchema(h.schema)~' "$H"; run "$H" "a schema change reports NOT-reset (the float chunk's answer)"
perl -0pi -e 's~\Q        if h.zeroCount < zCnt {\E~        if false {~' "$H"; run "$H" "a shrinking zero bucket is not a reset"
perl -0pi -e 's~\Q        if isCustomBucketsSchema(h.schema)\E\n\Q            && !customBucketBoundsMatch(h.customValues, customValues)\E~        if false\n            \&\& !customBucketBoundsMatch(h.customValues, customValues)~' "$H"; run "$H" "changed custom bounds are ignored"
perl -0pi -e 's~\Q        if PromValue.isStaleNaN(h.sum) {\E\n\Q            // A stale sample whose buckets and spans do not matter.\E\n\Q            return (none, none, none, none, true, .notCounterReset)\E~        if PromValue.isStaleNaN(h.sum) {\n            return (none, none, none, none, false, .notCounterReset)~' "$H"; run "$H" "a stale sample is not appendable"
perl -0pi -e 's~\Q        if PromValue.isStaleNaN(sum) {\E\n\Q            // After a stale sample the chunk accepts only stale samples.\E\n\Q            return (none, none, none, none, false, .unknownCounterReset)\E~        if false {\n            return (none, none, none, none, false, .unknownCounterReset)~' "$H"; run "$H" "a chunk keeps taking samples after a stale one"
perl -0pi -e 's~\Q        if numSamples > 0 && counterResetHeader == .gaugeType {\E\n\Q            return (none, none, none, none, false, .notCounterReset)\E~        if false {\n            return (none, none, none, none, false, .notCounterReset)~' "$H"; run "$H" "a counter sample may join a gauge chunk"
perl -0pi -e 's~\Q        if h.counterResetHint == .counterReset {\E\n\Q            // "Always honor the explicit counter reset hint."\E\n\Q            return (none, none, none, none, false, .counterReset)\E~        if false {\n            return (none, none, none, none, false, .counterReset)~' "$H"; run "$H" "the explicit reset hint is not honoured"

echo "=== appendable's order of checks, float ==="
perl -0pi -e 's~\Q        if h.count < cnt.value {\E~        if h.count <= cnt.value {~' "$F"; run "$F" "an equal float count is a counter reset"
perl -0pi -e 's~\Q            // Difference 2 from the integer chunk: there is no "unknown" to return here, so a layout\E\n\Q            // the encoder cannot express reads as "cut, but not a reset".\E\n\Q            return (none, none, none, none, false, false)\E~            return (none, none, none, none, false, true)~' "$F"; run "$F" "a float schema change is a reset"
perl -0pi -e 's~\Q        if h.zeroCount < zCnt.value {\E~        if false {~' "$F"; run "$F" "a shrinking float zero bucket is not a reset"
perl -0pi -e 's~\Q        if PromValue.isStaleNaN(sum.value) {\E\n\Q            return (none, none, none, none, false, false)\E~        if false {\n            return (none, none, none, none, false, false)~' "$F"; run "$F" "a float chunk keeps taking samples after a stale one"

echo "=== AppendHistogram's four outcomes ==="
perl -0pi -e 's~\Q            if !okToAppend || crHint != .notCounterReset {\E~            if !okToAppend {~' "$H"; run "$H" "an ok-to-append sample with a reset hint is appended anyway"
perl -0pi -e 's~\Q                happ.setCounterResetHeader(crHint)\E~~' "$H"; run "$H" "a cut chunk does not carry the reset verdict"
perl -0pi -e 's~\Q            if !pBackward.isEmpty || !nBackward.isEmpty {\E\n\Q                // The sample has to grow the chunk\E~            if false {\n                // The sample has to grow the chunk~' "$H"; run "$H" "backward inserts are never applied"
perl -0pi -e 's~\Q            if !pForward.isEmpty || !nForward.isEmpty {\E\n\Q                if appendOnly {\E\n\Q                    throw HistogramAppendError.layoutChange(\E~            if false {\n                if appendOnly {\n                    throw HistogramAppendError.layoutChange(~' "$H"; run "$H" "forward inserts never recode"
perl -0pi -e 's~\Q                if pForward.isEmpty && nForward.isEmpty {\E~                if true {~' "$H"; run "$H" "the spans are copied from the appender even when the sample grew"
perl -0pi -e 's~\Q                    h.positiveSpans = adjustForInserts(h.positiveSpans, pBackward)\E~                    h.positiveSpans = adjustForInserts(h.positiveSpans, nBackward)~' "$H"; run "$H" "adjustForInserts is given the negative inserts for the positive spans"
perl -0pi -e 's~\Q                let (chk, happ) = recode(pForward, nForward, h.positiveSpans, h.negativeSpans)\E\n\Q                happ.setNumSamples(happ.appendHistogram(happ.numSamples, t, h))\E\n\Q                return (chk, true, happ)\E\n\Q            }\E\n\Q            setNumSamples(appendHistogram(numSamplesNow, t, h))\E~                let (chk, happ) = recode(pForward, nForward, h.positiveSpans, h.negativeSpans)\n                happ.setNumSamples(happ.appendHistogram(happ.numSamples, t, h))\n                return (chk, false, happ)\n            }\n            setNumSamples(appendHistogram(numSamplesNow, t, h))~' "$H"; run "$H" "a recode reports isRecoded = false"
perl -0pi -e 's~\Q                    let r = p.appendable(h)\E\n\Q                    setCounterResetHeader(r.counterResetHint)\E~                    _ = p.appendable(h)~' "$H"; run "$H" "prev's verdict does not set the new chunk's header"
perl -0pi -e 's~\Q            } else if let prev {\E~            } else if false, let prev {~' "$H"; run "$H" "prev is ignored entirely"
perl -0pi -e 's~\Q            if h.counterResetHint == .gaugeType {\E\n\Q                setCounterResetHeader(.gaugeType)\E~            if false {\n                setCounterResetHeader(.gaugeType)~' "$H"; run "$H" "a first gauge sample does not set the gauge header"
perl -0pi -e 's~\Q        if h.counterResetHint != .gaugeType {\E~        if true {~' "$H"; run "$H" "a gauge sample takes the counter path"
perl -0pi -e 's~\Q        if pBackward.count + nBackward.count > 0 {\E~        if false {~' "$H"; run "$H" "the gauge path ignores backward inserts"
perl -0pi -e 's~\Q            h.positiveSpans = pMerged\E~            h.positiveSpans = nMerged~' "$H"; run "$H" "the gauge path uses the negative merged spans for the positive side"

echo "=== AppendFloatHistogram's asymmetries ==="
perl -0pi -e 's~\Q                // Difference 3: guarded, so a non-reset cut leaves the header at zero.\E\n\Q                if counterReset {\E\n\Q                    happ.setCounterResetHeader(.counterReset)\E\n\Q                }\E~                happ.setCounterResetHeader(counterReset ? .counterReset : .notCounterReset)~' "$F"; run "$F" "a float cut always writes a header (the integer chunk's shape)"
perl -0pi -e 's~\Q                    setCounterResetHeader(r.counterReset ? .counterReset : .notCounterReset)\E~                    setCounterResetHeader(r.counterReset ? .counterReset : .unknownCounterReset)~' "$F"; run "$F" "prev's no-reset verdict leaves the float header unknown"
perl -0pi -e 's~\Q            if !okToAppend || counterReset {\E~            if !okToAppend {~' "$F"; run "$F" "a float reset with okToAppend is appended anyway"

echo "=== the encoder: the first sample versus the rest ==="
perl -0pi -e 's~\Q            putVarbitUint(&chunk.b, h.count)\E\n\Q            putVarbitUint(&chunk.b, h.zeroCount)\E~    putVarbitUint(\&chunk.b, h.zeroCount)\n            putVarbitUint(\&chunk.b, h.count)~' "$H"; run "$H" "the first sample writes zeroCount before count"
perl -0pi -e 's~\Q            chunk.b.writeBits(h.sum.bitPattern, 64)\E\n\Q            for b in h.positiveBuckets {\E~            writeSumDelta(h.sum)\n            for b in h.positiveBuckets {~' "$H"; run "$H" "the first sum is XOR encoded rather than raw"
perl -0pi -e 's~\Q            let tDod = tDelta &- self.tDelta\E~            let tDod = tDelta~' "$H"; run "$H" "the timestamp is delta rather than delta-of-delta encoded"
perl -0pi -e 's~\Q                let dod = delta &- pBucketsDelta[i]\E~                let dod = delta~' "$H"; run "$H" "positive buckets are delta rather than dod encoded"
perl -0pi -e 's~\Q                pBucketsDelta[i] = delta\E~                pBucketsDelta[i] = dod~' "$H"; run "$H" "the bucket delta accumulator stores the dod"
perl -0pi -e 's~\Q                cntDod = 0\E\n\Q                zCntDod = 0\E~                cntDod = cntDelta\n                zCntDod = zCntDelta~' "$H"; run "$H" "a stale sample writes real count dods"
perl -0pi -e 's~\Q            h = Histogram(sum: h.sum)\E~~' "$H"; run "$H" "a stale sample keeps its buckets"
perl -0pi -e 's~\Q            h = FloatHistogram(sum: h.sum)\E~~' "$F"; run "$F" "a stale float sample keeps its buckets"
perl -0pi -e 's~\Q        for i in 0..<min(pBuckets.count, h.positiveBuckets.count) {\E~        for i in 0..<pBuckets.count where i < h.positiveBuckets.count {~' "$H"; run "$H" "INERT — the same partial-copy loop, spelled differently"
perl -0pi -e 's~\Q            cnt.value = h.count\E\n\Q            zCnt.value = h.zeroCount\E\n\Q            sum.value = h.sum\E~            sum.value = h.sum\n            cnt.value = h.count\n            zCnt.value = h.zeroCount~' "$F"; run "$F" "INERT — three independent assignments reordered"
perl -0pi -e 's~\Q            writeXorValue(&cnt, h.count)\E\n\Q            writeXorValue(&zCnt, h.zeroCount)\E\n\Q            writeXorValue(&sum, h.sum)\E~            writeXorValue(\&sum, h.sum)\n            writeXorValue(\&cnt, h.count)\n            writeXorValue(\&zCnt, h.zeroCount)~' "$F"; run "$F" "the float fields are written sum-first"
perl -0pi -e 's~\Q        xorWrite(&chunk.b, v, old.value, &old.leading, &old.trailing)\E\n\Q        old.value = v\E~        old.value = v\n        xorWrite(\&chunk.b, v, old.value, \&old.leading, \&old.trailing)~' "$F"; run "$F" "writeXorValue updates the baseline before writing"
perl -0pi -e 's~\QXORValue(value: h.positiveBuckets[\E.\Q0], leading: 0xff)\E~XORValue(value: h.positiveBuckets[\$0])~' "$F"; run "$F" "a float bucket's XOR window starts at 0 rather than the 0xff sentinel"

echo "=== Appender(): the replay ==="
perl -0pi -e 's~\Q            return HistogramAppender(chunk: self, t: Int64.min, leading: 0xff)\E~            return HistogramAppender(chunk: self, t: Int64.min)~' "$H"; run "$H" "a fresh integer appender starts with leading 0 rather than 0xff"
perl -0pi -e 's~\Q        a.trailing = it.trailing\E~~' "$H"; run "$H" "the replay does not restore the trailing window"
perl -0pi -e 's~\Q        a.pBucketsDelta = it.pBucketsDelta\E~~' "$H"; run "$H" "the replay does not restore the bucket delta accumulators"
perl -0pi -e 's~\Q        a.cntDelta = it.cntDelta\E~~' "$H"; run "$H" "the replay does not restore the count delta"
perl -0pi -e 's~\Q            a.sum = XORValue(leading: 0xff)\E\n\Q            a.cnt = XORValue(leading: 0xff)\E\n\Q            a.zCnt = XORValue(leading: 0xff)\E~            a.sum = XORValue(leading: 0xff)~' "$F"; run "$F" "only the sum gets the 0xff sentinel on an empty float chunk"
perl -0pi -e 's~\Q                    value: it.pBuckets[i], leading: it.pBucketsLeading[i],\E\n\Q                    trailing: it.pBucketsTrailing[i]))\E~                    value: it.pBuckets[i]))~' "$F"; run "$F" "the float replay drops each bucket's XOR window"
perl -0pi -e 's~\Q        if b.stream.count == histogramHeaderSize {\E\n\Q            // Avoid allocating an iterator when the chunk is empty.\E~        if false {\n            // Avoid allocating an iterator when the chunk is empty.~' "$H"; run "$H" "the empty-chunk shortcut is skipped, so an empty chunk replays instead"

echo "=== the decoder ==="
perl -0pi -e 's~\Q            tDelta = tDelta &+ tDod\E\n\Q            t = t &+ tDelta\E~            tDelta = tDod\n            t = t \&+ tDelta~' "$H"; run "$H" "the decoder does not accumulate the timestamp delta"
perl -0pi -e 's~\Q                pBucketsDelta[i] = pBucketsDelta[i] &+ dod\E~                pBucketsDelta[i] = dod~' "$H"; run "$H" "the decoder does not accumulate the bucket delta"
perl -0pi -e 's~\Q                current = current &+ pBuckets[i]\E\n\Q                pFloatBuckets[i] = Double(current)\E~                pFloatBuckets[i] = Double(pBuckets[i])~' "$H"; run "$H" "the float view of an integer chunk is not cumulative"
perl -0pi -e 's~\Q            if PromValue.isStaleNaN(sum) {\E\n\Q                // The encoder wrote no bucket dods for a stale sample, so none are read.\E\n\Q                numRead += 1\E~            if false {\n                numRead += 1~' "$H"; run "$H" "the decoder reads bucket dods after a stale sum"
perl -0pi -e 's~\Q            if !isKnownSchema(layout.schema) {\E~    if false {~' "$H"; run "$H" "an unknown schema is accepted"
perl -0pi -e 's~\Q        while target > t || numRead == 0 {\E~        while target > t {~' "$H"; run "$H" "Seek does not force the first advance"
perl -0pi -e 's~\Q        while target > t || numRead == 0 {\E~        while target >= t || numRead == 0 {~' "$H"; run "$H" "Seek advances past an exactly matching timestamp"
perl -0pi -e 's~\Q        t = 0\E\n\Q        cnt = 0\E~        t = Int64.min\n        cnt = 0~' "$H"; run "$H" "reset restores t to MinInt64 rather than 0"
perl -0pi -e 's~\Q        if PromValue.isStaleNaN(sum) {\E\n\Q            // A stale sample carries nothing but its sum, and NOT the counter reset hint.\E\n\Q            return (t, Histogram(sum: sum))\E~        if false {\n            return (t, Histogram(sum: sum))~' "$H"; run "$H" "a stale sample reads back with its layout and hint"
perl -0pi -e 's~\Q        h.counterResetHint = counterResetHint(counterResetHeaderValue, numRead)\E~        h.counterResetHint = counterResetHint(counterResetHeaderValue, numRead + 1)~' "$H"; run "$H" "the hint is derived one sample early"
perl -0pi -e 's~\Q            fh.positiveBuckets = pFloatBuckets\E~            fh.positiveBuckets = nFloatBuckets~' "$H"; run "$H" "AtFloatHistogram(nil) hands out the negative absolute counts"

echo "=== the reserved-schema reduction ==="
perl -0pi -e 's~\Q    guard h.schema > HistogramSchema.exponentialMax\E~    guard h.schema >= HistogramSchema.exponentialMax~' "$H"; run "$H" "schema 8 is reduced too"
perl -0pi -e 's~\Q        && h.schema <= HistogramSchema.exponentialMaxReserved\E~        \&\& h.schema <= HistogramSchema.exponentialMaxReserved + 1~' "$H"; run "$H" "INERT — the reserved ceiling is raised past what a known schema can be"
perl -0pi -e 's~\Q        try h.reduceResolution(targetSchema: HistogramSchema.exponentialMax)\E~        try h.reduceResolution(targetSchema: HistogramSchema.exponentialMax - 1)~' "$H"; run "$H" "the reduction targets schema 7"

echo "=== the populate iterator's histogram arms (PromBlock, reachable only since §7k) ==="
perl -0pi -e 's~\Q            case .histogram:\E~            case ValueType(rawValue: 250):~' "$P"; run "$P" "the integer histogram arm is unreachable"
perl -0pi -e 's~\Q            case .floatHistogram:\E~            case ValueType(rawValue: 251):~' "$P"; run "$P" "the float histogram arm is unreachable"
perl -0pi -e 's~\Q                let (ts, h) = del.atHistogram(nil)\E~                let (ts, h) = del.atHistogram(Histogram())~' "$P"; run "$P" "INERT — the integer arm reads through a reuse buffer"
perl -0pi -e 's~\Q                        prev: nil, st: st, t: t, h: &h, appendOnly: true)\E~                        prev: nil, st: st, t: t, h: \&h, appendOnly: false)~' "$P"; run "$P" "the integer arm requests a new chunk instead of refusing"
perl -0pi -e 's~\Q                    app = r.appender\E\n\Q                } catch {\E\n\Q                    self.error = PopulateError.iterateWhileReEncoding(underlying: error)\E\n\Q                    return false\E\n\Q                }\E\n\Q            case .floatHistogram:\E~                } catch {\n                    self.error = PopulateError.iterateWhileReEncoding(underlying: error)\n                    return false\n                }\n            case .floatHistogram:~' "$P"; run "$P" "the integer arm keeps the old appender"
perl -0pi -e 's~\Q            newChunk = try newEmptyChunk(source.encoding)\E~            newChunk = try newEmptyChunk(.xor)~' "$P"; run "$P" "the re-encoder hard-codes XOR (the §6t defect quirk 208 fixed)"

cat <<'ARGUMENT'

=== the score, and the survivors argued ===

108 controls: 96 broke, 12 survived. Five of the twelve are the deliberately-inert ones and MUST survive;
the other seven are proofs. Read this with HANDOFF §3's four diagnosis modes in hand (quirks
159/160/163/166): a survivor is UNREACHABLE, PROVABLY IDENTICAL, ABSORBED BY A LAYER THE CORPUS CANNOT
BYPASS, or a real GAP.

The five INERT controls are the sweep's control on itself — the failure mode `lib/control-run.sh` exists
for is a sweep in which `broke` is the harness's default. They are: a comment inserted above `insert`; a
`min(a, b)` loop respelled with a `where` clause; three assignments with no data dependence between them
reordered; a bound widened past a value `isKnownSchema` already excludes; and the re-encoder's
`atHistogram(nil)` given a reuse buffer instead, which the non-stale path overwrites field by field and the
stale path ignores. If any of them ever reports `broke`, stop and fix the harness before believing anything
else here.

  * **"the counter-reset mask is three bits"** and **"setCounterResetHeader clobbers the rest of the flag
    byte"** — PROVABLY IDENTICAL, and they are the same proof. The low six bits of `bytes[2]` are reserved
    and *nothing in v3.13.2 ever writes them*: the chunk is allocated zeroed and `setCounterResetHeader` is
    the only writer of that byte. So `old & ~mask` is always 0 for any chunk this encoder produced, and
    widening the read mask to three bits reads one more zero. Seeing either would need a chunk whose flag
    byte has a low bit set — that is, a hand-made byte string, which §6w's harness lesson rules out for this
    corpus. Both are guards against a future upstream that uses those bits, which is presumably why upstream
    masks at all.

  * **"adjustForInserts places an insert at an occupied index"** (`insertIdx < bucket` weakened to `<=`) —
    UNREACHABLE. `adjustForInserts` is only ever called with BACKWARD inserts, and a backward insert's
    `bucketIdx` is by construction an index the sample does NOT have: `expandIntSpansAndBuckets` adds one
    only in the `aIdx < bIdx` and `aOK && !bOK` arms, where `aIdx` is a chunk bucket that `b`'s iterator has
    already passed. Within a run, `consumeInsert` walks `insertIdx` through consecutive indices that were
    contiguous in the chunk and absent from the sample, so it cannot land on one either. `insertIdx == bucket`
    has no input.

  * **"an ok-to-append sample with a reset hint is appended anyway"** and its float twin — UNREACHABLE, and
    the argument is about the neighbouring function rather than the corpus (HANDOFF's "look at the type's
    guarantees" habit). `AppendHistogram` tests `!okToAppend || counterResetHint != .notCounterReset`, but
    every `return` in `appendable` that sets `okToAppend = true` also leaves the hint at `.notCounterReset` —
    there are exactly two, the stale-sample early return and the tail. So the second clause can never be the
    one that fires. It is a belt on a decision made two functions away, and it stays because the day
    `appendable` grows a third `okToAppend = true` return is the day it starts mattering.

  * **"the integer arm requests a new chunk instead of refusing"** (`appendOnly: true` weakened to `false`)
    and **"the integer arm keeps the old appender"** — UNREACHABLE, and it is one argument for both, the same
    one `PopulateHistogramReencodeTests` asserts directly. Re-encoding a chunk's own samples cannot need a
    new chunk: a chunk has ONE layout, every sample reads back with it, and a counter chunk's counts only
    rise, so any in-order subset is appendable. The single shape that WOULD refuse — a non-stale sample after
    a stale one, which `appendable` rejects (quirk 223) — cannot exist, because the appender that would write
    it cuts a new chunk instead. So `AppendHistogram` here always returns `(nil, false, self)` and neither
    `appendOnly` nor the reassignment of `app` has an input that can distinguish it. Both lines stay because
    they are upstream's and because the argument is about a *neighbouring* invariant rather than about this
    function.

Historical note, because it is the useful part of the first run: three more controls survived it and all
three were real GAPS rather than proofs, closed by four new cases rather than by argument.
`isWholeWhenMultiplied`'s rounding needed a bound where `f * 1000` lands just below an integer (1.001, a
harvested witness — see PORTING.md quirk 226). `insert`'s `firstInsert` flag and `addInsert`'s continuity
test both needed TWO `Insert` entries at the same `pos`, which only happens when a sample adds buckets at
non-adjacent indices before the same old bucket. And `adjustForInserts`' `insertIdx += 1` needed a backward
insert run of length > 1 arriving alongside a forward insert. None of the four is exotic; all four were
simply outside a corpus built from "one sample, then a slightly different sample".
ARGUMENT
