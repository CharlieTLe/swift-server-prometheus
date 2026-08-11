#!/usr/bin/env bash
# Negative controls for `tsdb/record` — the WAL's wire format.
#
# What this sweep is trying to establish, beyond "the corpus is not empty": the record codec is a pile of
# small, near-identical field sequences, and its failure mode is a field written the way its NEIGHBOUR
# writes it. So most controls here swap one primitive for the plausible alternative at the same position —
# a BE64 for a varint, a uvarint for a varint, a signed delta base for the other one — rather than
# deleting anything.
#
# The three groups that matter, and why:
#
#   1. **the delta bases.** V1 deltas are against `first`; V2's ref delta is against `prev` and its
#      timestamp delta against `first`. Two fields side by side with different bases is exactly the shape
#      a port normalises by accident, and a single-sample corpus cannot see it.
#   2. **the ST marker's three arms and their ORDER.** `case 0` before `case prevST` is load-bearing;
#      swapping them changes the bytes only when `st == 0 && prevST == 0`, which is why the corpus has
#      that pair adjacent.
#   3. **the two error-message spellings.** `Samples` reports a numeric type and `HistogramSamples` a
#      named one. Nothing but a fixture that carries the message text can tell those apart.
set -uo pipefail
cd "$(dirname "$0")/.."
ENC=Sources/PromRecord/RecordEncoder.swift
DEC=Sources/PromRecord/RecordDecoder.swift
TYP=Sources/PromRecord/Record.swift
cp "$ENC" /tmp/rec-enc.orig
cp "$DEC" /tmp/rec-dec.orig
cp "$TYP" /tmp/rec-typ.orig
restore() {
  cp /tmp/rec-enc.orig "$ENC"
  cp /tmp/rec-dec.orig "$DEC"
  cp /tmp/rec-typ.orig "$TYP"
}
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'Record' 62
  restore
}

echo "=== the type table ==="
perl -0pi -e 's/    public static let unknown = RecordType\(rawValue: 255\)/    public static let unknown = RecordType(rawValue: 0)/' "$TYP"; run "Unknown is 0 rather than 255"
perl -0pi -e 's/        case \.mmapMarkers: return "mmapmarkers"/        case .mmapMarkers: return "mmap_markers"/' "$TYP"; run "mmapmarkers gains an underscore"
perl -0pi -e 's/    guard let first = rec\.first else \{ return \.unknown \}/    guard let first = rec.first else { return .series }/' "$TYP"; run "an empty record is not Unknown"
perl -0pi -e 's/    case \.unknown: return RecordMetricType\.unknownMT\.rawValue/    case .unknown: return RecordMetricType.stateset.rawValue/' "$TYP"; run "GetMetricType(unknown) is not 0"
perl -0pi -e 's/    case \.histogramSample: return \.histogram/    case .histogramSample: return .gaugeHistogram/' "$TYP"; run "ToMetricType(3) is gaugehistogram"

echo "=== Samples V1: the base pair and the deltas ==="
perl -0pi -e 's/        buf\.putBE64\(first\.ref\.rawValue\)\n        buf\.putBE64int64\(first\.t\)\n\n        \/\/ Starts at 0/        buf.putBE64int64(first.t)\n        buf.putBE64(first.ref.rawValue)\n\n        \/\/ Starts at 0/' "$ENC"; run "V1 base pair written t-then-ref"
perl -0pi -e 's/        \/\/ Starts at 0, so the first sample is written a second time as a pair of zero deltas\.\n        for s in samples \{/        for s in samples.dropFirst() {/' "$ENC"; run "V1 skips the first sample in the loop"
perl -0pi -e 's/            buf\.putVarint64\(s\.t &- first\.t\)\n            buf\.putBE64\(s\.v\.bitPattern\)/            buf.putVarint64(s.t \&- first.t)\n            buf.putBEFloat64(Double(s.v.bitPattern))/' "$ENC"; run "V1 value written as a converted double"
# Two patches for one control: `HeadSeriesRef` lives in `PromChunks`, which the encoder does not import
# (only the decoder needs it), so the import goes in alongside the perturbation.
perl -0pi -e 's/public import PromHistogram/internal import PromChunks\npublic import PromHistogram/' "$ENC"
perl -0pi -e 's/        guard let first = samples\.first else \{ return buf\.bytes \}\n\n        buf\.putBE64\(first\.ref\.rawValue\)/        let first = samples.first ?? RefSample(ref: HeadSeriesRef(rawValue: 0), t: 0, v: 0)\n        buf.putBE64(first.ref.rawValue)/' "$ENC"; run "V1 writes a base pair for an EMPTY sample list"
perl -0pi -e 's/            let dref = dec\.varint64\(\)\n            let dtime = dec\.varint64\(\)\n            let val = dec\.be64\(\)/            let dtime = dec.varint64()\n            let dref = dec.varint64()\n            let val = dec.be64()/' "$DEC"; run "V1 decode reads dtime before dref"

echo "=== Samples V2: two deltas, two bases ==="
perl -0pi -e 's/                Int64\(bitPattern: s\.ref\.rawValue\) &- Int64\(bitPattern: prev\.ref\.rawValue\)\)\n            buf\.putVarint64\(s\.t &- first\.t\)\n            writeSTMarker/                Int64(bitPattern: s.ref.rawValue) \&- Int64(bitPattern: first.ref.rawValue))\n            buf.putVarint64(s.t \&- first.t)\n            writeSTMarker/' "$ENC"; run "V2 ref delta is against FIRST, not prev"
perl -0pi -e 's/            buf\.putVarint64\(s\.t &- first\.t\)\n            writeSTMarker/            buf.putVarint64(s.t \&- prev.t)\n            writeSTMarker/' "$ENC"; run "V2 timestamp delta is against PREV, not first"
perl -0pi -e 's/        buf\.putVarint64\(Int64\(bitPattern: first\.ref\.rawValue\)\)\n        buf\.putVarint64\(first\.t\)\n        buf\.putVarint64\(first\.st\)\n        buf\.putBE64\(first\.v\.bitPattern\)/        buf.putBE64(first.ref.rawValue)\n        buf.putBE64int64(first.t)\n        buf.putVarint64(first.st)\n        buf.putBE64(first.v.bitPattern)/' "$ENC"; run "V2 first ref/t written as BE64 like V1"
perl -0pi -e 's/        buf\.putVarint64\(first\.st\)\n        buf\.putBE64\(first\.v\.bitPattern\)/        writeSTMarker(\&buf, first.st, first.st, 0)\n        buf.putBE64(first.v.bitPattern)/' "$ENC"; run "V2 first ST written through the marker"
perl -0pi -e 's/    public func samples\(_ samples: \[RefSample\]\) -> \[UInt8\] \{\n        enableSTStorage \? samplesV2\(samples\) : samplesV1\(samples\)/    public func samples(_ samples: [RefSample]) -> [UInt8] {\n        samplesV1(samples)/' "$ENC"; run "EnableSTStorage does not select V2"
perl -0pi -e 's/                let prev = samples\[samples\.count - 1\]\n                ref = Int64\(bitPattern: prev\.ref\.rawValue\) &\+ dec\.varint64\(\)/                let prev = samples[0]\n                ref = Int64(bitPattern: prev.ref.rawValue) \&+ dec.varint64()/' "$DEC"; run "V2 decode takes prev from the FIRST sample"
perl -0pi -e 's/            if samples\.isEmpty \{/            if samples.count == startCount {/' "$DEC"; run "(probe) V2 decode measures the RECORD, not the accumulator"
# ^ Expected COMPILE: `startCount` does not exist. Left in deliberately as the marker for the divergence
# PORTING.md exception 18 records — the accumulator-sensitive `len(samples) == 0` is the behaviour under
# test, and "fixing" it needs a variable the port does not have. The `encode/023` case is what pins it.

echo "=== the ST marker: three arms, and the order of the first two ==="
perl -0pi -e 's/    if st == 0 \{\n        buf\.putByte\(stMarkerNoST\)\n    \} else if st == prevST \{/    if st == prevST {\n        buf.putByte(stMarkerSameST)\n    } else if st == 0 {/' "$ENC"; run "sameST tested before noST"
perl -0pi -e 's/        buf\.putByte\(stMarkerExplicitST\)\n        buf\.putVarint64\(st &- firstST\)/        buf.putByte(stMarkerExplicitST)\n        buf.putVarint64(st \&- prevST)/' "$ENC"; run "explicitST delta is against prevST"
perl -0pi -e 's/        buf\.putByte\(stMarkerExplicitST\)\n        buf\.putVarint64\(st &- firstST\)/        buf.putByte(stMarkerExplicitST)\n        buf.putVarint64(st)/' "$ENC"; run "explicitST writes st absolutely"
perl -0pi -e 's/    case stMarkerSameST: return prevST\n    default: return firstST &\+ buf\.varint64\(\)/    case stMarkerSameST: return prevST\n    case stMarkerExplicitST: return firstST \&+ buf.varint64()\n    default: return 0/' "$DEC"; run "readSTMarker rejects a marker above 2"
perl -0pi -e 's/    case stMarkerNoST: return 0\n    case stMarkerSameST: return prevST/    case stMarkerNoST: return prevST\n    case stMarkerSameST: return 0/' "$DEC"; run "readSTMarker swaps noST and sameST"

echo "=== Series, Metadata, Tombstones, Exemplars, MmapMarkers ==="
perl -0pi -e 's/    buf\.putUvarint\(lbls\.count\)/    buf.putVarint64(Int64(lbls.count))/' "$ENC"; run "the label count is a varint"
perl -0pi -e 's/        buf\.putUvarintStr\(l\.name\)\n        buf\.putUvarintStr\(l\.value\)/        buf.putUvarintStr(l.value)\n        buf.putUvarintStr(l.name)/' "$ENC"; run "labels written value-then-name"
perl -0pi -e 's/            buf\.putUvarint64\(m\.ref\.rawValue\)\n            buf\.putByte\(m\.type\)/            buf.putBE64(m.ref.rawValue)\n            buf.putByte(m.type)/' "$ENC"; run "the Metadata ref is a BE64"
perl -0pi -e 's/            buf\.putUvarint\(2\)\n            buf\.putUvarintStr\(unitMetaName\)/            buf.putUvarint(2)\n            buf.putUvarintStr(helpMetaName)/' "$ENC"; run "the first Metadata field is named HELP"
perl -0pi -e 's/            buf\.putUvarintStr\(unitMetaName\)\n            buf\.putUvarintStr\(m\.unit\)\n            buf\.putUvarintStr\(helpMetaName\)\n            buf\.putUvarintStr\(m\.help\)/            buf.putUvarintStr(unitMetaName)\n            buf.putUvarintStr(m.unit)/' "$ENC"; run "Metadata writes one field but declares two"
perl -0pi -e 's/                    case unitMetaName: unit = fieldValue/                    case unitMetaName: help = fieldValue/' "$DEC"; run "the UNIT field lands in help"
perl -0pi -e 's/            for iv in s\.intervals \{\n                buf\.putBE64\(s\.ref\.rawValue\)/            buf.putBE64(s.ref.rawValue)\n            for iv in s.intervals {/' "$ENC"; run "the Tombstones ref is written once per stone"
perl -0pi -e 's/                buf\.putVarint64\(iv\.mint\)\n                buf\.putVarint64\(iv\.maxt\)/                buf.putVarint64(iv.maxt)\n                buf.putVarint64(iv.mint)/' "$ENC"; run "Tombstones intervals written maxt-then-mint"
perl -0pi -e 's/            buf\.putBE64\(ex\.v\.bitPattern\)\n            encodeLabels\(&buf, ex\.labels\)/            encodeLabels(\&buf, ex.labels)\n            buf.putBE64(ex.v.bitPattern)/' "$ENC"; run "an Exemplar's labels precede its value"
perl -0pi -e 's/                    ref: HeadSeriesRef\(rawValue: baseRef &\+ UInt64\(bitPattern: dref\)\),\n                    t: baseTime &\+ dtime,\n                    v: Double\(bitPattern: val\),\n                    labels: lset\)\)/                    ref: HeadSeriesRef(rawValue: baseRef), t: baseTime \&+ dtime,\n                    v: Double(bitPattern: val), labels: lset))/' "$DEC"; run "an Exemplar's ref delta is ignored on decode"
perl -0pi -e 's/            buf\.putBE64\(s\.ref\.rawValue\)\n            buf\.putBE64\(s\.mmapRef\.rawValue\)/            buf.putBE64(s.mmapRef.rawValue)\n            buf.putBE64(s.ref.rawValue)/' "$ENC"; run "an MmapMarker writes mmapRef first"

echo "=== the histogram field codecs ==="
perl -0pi -e 's/    buf\.putUvarint64\(h\.zeroCount\)\n    buf\.putUvarint64\(h\.count\)\n    buf\.putBE64\(h\.sum\.bitPattern\)/    buf.putBEFloat64(Double(h.zeroCount))\n    buf.putBEFloat64(Double(h.count))\n    buf.putBE64(h.sum.bitPattern)/' "$ENC"; run "an integer histogram writes its counts as BE64"
perl -0pi -e 's/    buf\.putVarint64\(Int64\(h\.schema\)\)\n    buf\.putBE64\(h\.zeroThreshold\.bitPattern\)/    buf.putUvarint64(UInt64(bitPattern: Int64(h.schema)))\n    buf.putBE64(h.zeroThreshold.bitPattern)/' "$ENC"; run "the integer histogram schema is a uvarint"
perl -0pi -e 's/        buf\.putVarint64\(Int64\(s\.offset\)\)\n        buf\.putUvarint32\(s\.length\)/        buf.putUvarint32(UInt32(bitPattern: s.offset))\n        buf.putUvarint32(s.length)/' "$ENC"; run "a span offset is a uvarint"
perl -0pi -e 's/    if isCustomBucketsSchema\(h\.schema\) \{\n        let values = h\.customValues \?\? \[\]\n        buf\.putUvarint\(values\.count\)/    do {\n        let values = h.customValues ?? []\n        buf.putUvarint(values.count)/' "$ENC"; run "customValues written for EVERY schema"
perl -0pi -e 's/    buf\.putByte\(h\.counterResetHint\.rawValue\)\n\n    buf\.putVarint64\(Int64\(h\.schema\)\)\n    buf\.putBEFloat64\(h\.zeroThreshold\)/    buf.putVarint64(Int64(h.schema))\n    buf.putByte(h.counterResetHint.rawValue)\n    buf.putBEFloat64(h.zeroThreshold)/' "$ENC"; run "the float histogram hint follows the schema"
perl -0pi -e 's/    var l = buf\.uvarint\(\)\n    if l > 0 \{ h\.positiveBuckets = \[Int64\]\(repeating: 0, count: l\) \}/    var l = buf.uvarint()\n    h.positiveBuckets = [Int64](repeating: 0, count: max(0, l))/' "$DEC"; run "(probe) a zero bucket count CLEARS rather than keeps"
# ^ Expected to SURVIVE, and provably: every caller of `decodeHistogram` passes a freshly-defaulted
# `Histogram`, so the slice is already empty when `l == 0` and the two spellings agree. The difference is
# only visible to a caller that REUSES a histogram, which upstream has none of — `decodeHistogram` is
# exported, so the shape is kept for that hypothetical caller and documented on the function. This is a
# quirk-160 tautology under today's callers, not a corpus gap.

echo "=== the histogram record framing and the split ==="
perl -0pi -e 's/        \/\/ Every histogram was custom-buckets: the record becomes ZERO bytes, type byte included\.\n        if histograms\.count == customBucketHistograms\.count \{\n            buf\.reset\(\)\n        \}/        \/\/ perturbed: no reset/' "$ENC"; run "an all-custom-buckets record keeps its type byte"
perl -0pi -e 's/            if h\.h\.usesCustomBuckets \{\n                customBucketHistograms\.append\(h\)\n                continue\n            \}/            if false {\n                customBucketHistograms.append(h)\n                continue\n            }/' "$ENC"; run "V1 does not split custom-buckets histograms out"
perl -0pi -e 's/        buf\.putByte\(RecordType\.customBucketsHistogramSamples\.rawValue\)/        buf.putByte(RecordType.histogramSamples.rawValue)/' "$ENC"; run "the custom-buckets record reuses type 7"
perl -0pi -e 's/        if enableSTStorage \{\n            return \(histogramSamplesV2\(histograms\), \[\]\)\n        \}\n        return histogramSamplesV1\(histograms\)/        return histogramSamplesV1(histograms)/' "$ENC"; run "histogramSamples ignores EnableSTStorage"
perl -0pi -e 's/            prevRef = ref\n            prevST = st\n            var h = Histogram\(\)\n            decodeHistogram\(&dec, &h\)\n\n            if !isKnownSchema\(h\.schema\) \{\n                onUnknownSchema\?\(h\.schema, t\)\n                continue\n            \}/            var h = Histogram()\n            decodeHistogram(\&dec, \&h)\n\n            if !isKnownSchema(h.schema) {\n                onUnknownSchema?(h.schema, t)\n                continue\n            }\n            prevRef = ref\n            prevST = st/' "$DEC"; run "a SKIPPED V2 histogram does not advance prev"
perl -0pi -e 's/            if !isKnownSchema\(h\.schema\) \{\n                onUnknownSchema\?\(h\.schema, t\)\n                continue\n            \}\n            if h\.schema > HistogramSchema\.exponentialMax/            if h.schema > HistogramSchema.exponentialMax/' "$DEC"; run "an unknown schema is not skipped"
perl -0pi -e 's/            if h\.schema > HistogramSchema\.exponentialMax\n                && h\.schema <= HistogramSchema\.exponentialMaxReserved\n            \{\n                do \{\n                    try h\.reduceResolution\(targetSchema: HistogramSchema\.exponentialMax\)/            if h.schema > HistogramSchema.exponentialMax\n                \&\& h.schema <= HistogramSchema.exponentialMaxReserved\n            {\n                do {\n                    try h.reduceResolution(targetSchema: h.schema)/' "$DEC"; run "the reduction target is the schema itself"
perl -0pi -e 's/            case \.histogramSamples, \.customBucketsHistogramSamples:\n                out = try histogramSamplesV1\(&dec, out\)/            case .histogramSamples:\n                out = try histogramSamplesV1(\&dec, out)/' "$DEC"; run "type 9 is not accepted by HistogramSamples"

echo "=== the error vocabulary ==="
perl -0pi -e 's/            return "invalid record type \\\(b\), expected Samples\(2\) or SamplesV2\(11\)"/            return "invalid record type \\(RecordType(rawValue: b)), expected Samples(2) or SamplesV2(11)"/' "$TYP"; run "the Samples type error names the type"
perl -0pi -e 's/            return "invalid record type \\\(t\)"/            return "invalid record type \\(t.rawValue)"/' "$TYP"; run "the histogram type error numbers the type"
perl -0pi -e 's/            return "decode error after \\\(n\) \\\(noun\): \\\(inner\)"/            return "decode error after \\(n) \\(noun)"/' "$TYP"; run "the decode error drops the wrapped cause"
perl -0pi -e 's/            return "error reducing resolution of histogram #\\\(n\): \\\(inner\)"/            return "error reducing resolution of histogram #\\(n - 1): \\(inner)"/' "$TYP"; run "the reduction error index is zero-based"
# ^ SURVIVED on the first sweep, and it was a real corpus gap rather than an equivalence, so it is worth
# recording how it closed. The message is only produced when `ReduceResolution` FAILS, and its own three
# guards — custom buckets in, custom buckets out, target not smaller — are every one of them excluded by the
# caller's `schema > 8 && schema <= 52` test. So the failure has to come from `reduceResolution`'s two INNER
# errors instead: a non-first span with a negative offset (generic.go:810) and spans needing more buckets
# than exist (:817). Five `reduce-fails-*` cases in `record/decode`, two of them with a good histogram in
# front so the index is pinned as one-based rather than merely present. Quirk 159's discipline: finish the
# argument, then say which of the four kinds of survivor it was.
perl -0pi -e 's/            if let e = dec\.err \{ throw RecordError\.decbuf\(String\(describing: e\)\) \}\n            if dec\.count > 0 \{ throw RecordError\.unexpectedBytesLeft\(dec\.count\) \}\n        \}\n        return series/            if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }\n            if let e = dec.err { throw RecordError.decbuf(String(describing: e)) }\n        }\n        return series/' "$DEC"; run "Series checks trailing bytes before the decode error"
perl -0pi -e 's/        if let e = dec\.err \{\n            throw RecordError\.decodeErrorAfter\(samples\.count, "samples", String\(describing: e\)\)\n        \}\n        if dec\.count > 0 \{ throw RecordError\.unexpectedBytesLeft\(dec\.count\) \}\n        return samples\n    \}\n\n    \/\/\/ Go: `Decoder\.samplesV2`/        if dec.count > 0 { throw RecordError.unexpectedBytesLeft(dec.count) }\n        if let e = dec.err {\n            throw RecordError.decodeErrorAfter(samples.count, "samples", String(describing: e))\n        }\n        return samples\n    }\n\n    \/\/\/ Go: `Decoder.samplesV2`/' "$DEC"; run "samplesV1 checks trailing bytes before the decode error"

echo "=== the label decode, which must NOT sort ==="
perl -0pi -e 's/        return builder\.labels\(\)/        builder.sort()\n        return builder.labels()/' "$DEC"; run "DecodeLabels sorts"
perl -0pi -e 's/    public mutating func decodeLabels\(_ dec: inout Decbuf\) -> Labels \{\n        builder\.reset\(\)/    public mutating func decodeLabels(_ dec: inout Decbuf) -> Labels {/' "$DEC"; run "the scratch builder is not reset per label set"
