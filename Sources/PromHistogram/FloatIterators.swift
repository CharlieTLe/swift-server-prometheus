//===----------------------------------------------------------------------===//
// Ported from model/histogram/float_histogram.go @ v3.13.2 — the bucket
// iterators.
//
// `floatBucketIterator` is the interesting one: it can merge buckets from the
// stored schema down to a coarser `targetSchema` while iterating, without
// mutating the histogram. Go does that with a labelled `mergeLoop` and a set of
// shadow locals that let it walk forward and roll back; Swift has labelled
// loops, so the shape carries over directly.
//
// `reverseFloatBucketIterator` shadows the embedded `idxInSpan` with a *signed*
// one (float_histogram.go:1323) so exhaustion can be detected by going negative.
// Swift has no embedding, so it simply has its own field and never touches the
// base's.
//===----------------------------------------------------------------------===//

/// Go: `floatBucketIterator`.
public struct FloatBucketIterator: BucketIterator, Sendable {
    var base: BaseBucketIterator<Double, Double>

    /// The schema to merge to. Must be ≤ `base.schema`.
    let targetSchema: Int32
    /// The bucket index within the original schema.
    var origIdx: Int32 = 0
    /// Never return buckets with an upper bound ≤ this value.
    let absoluteStartValue: Double
    /// Has `getBound` reached `absoluteStartValue` already?
    var boundReachedStartValue: Bool

    init(
        spans: [Span], buckets: [Double], schema: Int32, positive: Bool,
        customValues: [Double], targetSchema: Int32, absoluteStartValue: Double
    ) {
        base = BaseBucketIterator(
            schema: schema, spans: spans, buckets: buckets, positive: positive,
            customValues: customValues)
        self.targetSchema = targetSchema
        self.absoluteStartValue = absoluteStartValue
        boundReachedStartValue = absoluteStartValue == 0
    }

    /// Go: `At` — uses `targetSchema` rather than the base's schema.
    public func at() -> Bucket<Double> { base.at(targetSchema) }

    func strippedAt() -> StrippedBucket<Double> { base.strippedAt() }

    public mutating func next() -> Bool {
        if base.spansIdx >= base.spans.count { return false }
        var span = base.spans[base.spansIdx]

        if base.schema == targetSchema {
            // Fast path for the common case.
            if base.bucketsIdx == 0 {
                // Seed origIdx for the first bucket.
                base.currIdx = span.offset
            } else {
                base.currIdx += 1
            }
            if base.bucketsIdx >= base.buckets.count {
                // Guards against an out-of-range index, which only an invalid
                // histogram can produce.
                return false
            }

            while base.idxInSpan >= span.length {
                // The current span is exhausted, so find a new one. This also
                // handles pathological spans of length 0.
                base.idxInSpan = 0
                base.spansIdx += 1
                if base.spansIdx >= base.spans.count { return false }
                span = base.spans[base.spansIdx]
                base.currIdx += span.offset
            }

            base.currCount = base.buckets[base.bucketsIdx]
            base.idxInSpan += 1
            base.bucketsIdx += 1
        } else {
            // Shadow copies, so the iterator can walk forward to test the next
            // bucket for mergeability and roll back if it does not merge.
            var origIdx = self.origIdx
            var spansIdx = base.spansIdx
            var idxInSpan = base.idxInSpan
            var firstPass = true
            base.currCount = 0

            // Merge every bucket from the original schema that falls into one
            // bucket in targetSchema.
            mergeLoop: while true {
                if base.bucketsIdx == 0 {
                    // Seed origIdx for the first bucket.
                    origIdx = span.offset
                } else {
                    origIdx += 1
                }
                if base.bucketsIdx >= base.buckets.count {
                    // Guards against an out-of-range index, which only an invalid
                    // histogram can produce.
                    if firstPass { return false }
                    break mergeLoop
                }
                while idxInSpan >= span.length {
                    idxInSpan = 0
                    spansIdx += 1
                    if spansIdx >= base.spans.count {
                        if firstPass { return false }
                        break mergeLoop
                    }
                    span = base.spans[spansIdx]
                    origIdx += span.offset
                }
                let currIdx = targetIdx(origIdx, base.schema, targetSchema)
                if firstPass {
                    base.currIdx = currIdx
                    firstPass = false
                } else if currIdx != base.currIdx {
                    // Reached the next bucket in targetSchema. Do not actually
                    // forward to it; break out instead.
                    break mergeLoop
                }
                base.currCount += base.buckets[base.bucketsIdx]
                idxInSpan += 1
                base.bucketsIdx += 1
                self.origIdx = origIdx
                base.spansIdx = spansIdx
                base.idxInSpan = idxInSpan
                if base.schema == targetSchema {
                    // Unreachable in this branch — Go tests it anyway, to avoid
                    // checking the next bucket for mergeability when there is no
                    // schema change.
                    break mergeLoop
                }
            }
        }

        // Skip buckets below absoluteStartValue, for exponential schemas only.
        if !boundReachedStartValue, isExponentialSchema(targetSchema),
            getBoundExponential(base.currIdx, targetSchema) <= absoluteStartValue
        {
            return next()
        }
        boundReachedStartValue = true
        return true
    }
}

/// Go: `reverseFloatBucketIterator`.
public struct ReverseFloatBucketIterator: BucketIterator, Sendable {
    var base: BaseBucketIterator<Double, Double>
    /// float_histogram.go:1323 — signed, unlike the base's, so that exhausting a
    /// span can be detected by going negative.
    var idxInSpan: Int32 = 0

    init(spans: [Span], buckets: [Double], schema: Int32, positive: Bool, customValues: [Double]) {
        base = BaseBucketIterator(
            schema: schema, spans: spans, buckets: buckets, positive: positive,
            customValues: customValues)

        base.spansIdx = base.spans.count - 1
        base.bucketsIdx = base.buckets.count - 1
        if base.spansIdx >= 0 {
            idxInSpan = Int32(base.spans[base.spansIdx].length) - 1
        }
        base.currIdx = 0
        for s in base.spans {
            base.currIdx += s.offset + Int32(s.length)
        }
    }

    public func at() -> Bucket<Double> { base.at() }

    public mutating func next() -> Bool {
        base.currIdx -= 1
        if base.bucketsIdx < 0 { return false }

        while idxInSpan < 0 {
            // The current span is exhausted, so find a new one. This also handles
            // pathological spans of length 0.
            base.spansIdx -= 1
            if base.spansIdx < 0 {
                // Guards against an out-of-range index, which only an invalid
                // histogram can produce.
                return false
            }
            idxInSpan = Int32(base.spans[base.spansIdx].length) - 1
            base.currIdx -= base.spans[base.spansIdx + 1].offset
        }

        base.currCount = base.buckets[base.bucketsIdx]
        base.bucketsIdx -= 1
        idxInSpan -= 1
        return true
    }
}

/// Go: `allFloatBucketIterator` — negative, then zero, then positive buckets.
public struct AllFloatBucketIterator: BucketIterator, Sendable {
    private let h: FloatHistogram
    private var leftIter: ReverseFloatBucketIterator
    private var rightIter: FloatBucketIterator
    /// -1 iterating negative buckets, 0 time for the zero bucket, 1 iterating
    /// positive buckets, anything else means iteration is over.
    private var state: Int8 = -1
    private var currBucket = Bucket<Double>(
        lower: 0, upper: 0, lowerInclusive: false, upperInclusive: false, count: 0, index: 0)

    init(h: FloatHistogram, leftIter: ReverseFloatBucketIterator, rightIter: FloatBucketIterator) {
        self.h = h
        self.leftIter = leftIter
        self.rightIter = rightIter
    }

    public func at() -> Bucket<Double> { currBucket }

    public mutating func next() -> Bool {
        switch state {
        case -1:
            if leftIter.next() {
                currBucket = leftIter.at()
                if currBucket.upper < 0 && currBucket.upper > -h.zeroThreshold {
                    currBucket.upper = -h.zeroThreshold
                } else if currBucket.lower > 0 && currBucket.lower < h.zeroThreshold {
                    currBucket.lower = h.zeroThreshold
                }
                return true
            }
            state = 0
            return next()
        case 0:
            state = 1
            if h.zeroCount > 0 {
                currBucket = h.zeroBucket()
                return true
            }
            return next()
        case 1:
            if rightIter.next() {
                currBucket = rightIter.at()
                if currBucket.lower > 0 && currBucket.lower < h.zeroThreshold {
                    currBucket.lower = h.zeroThreshold
                } else if currBucket.upper < 0 && currBucket.upper > -h.zeroThreshold {
                    currBucket.upper = -h.zeroThreshold
                }
                return true
            }
            state = 42
            return false
        default:
            return false
        }
    }
}
