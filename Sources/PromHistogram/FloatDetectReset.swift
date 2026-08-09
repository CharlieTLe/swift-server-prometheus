//===----------------------------------------------------------------------===//
// Ported from model/histogram/float_histogram.go @ v3.13.2 — counter reset
// detection.
//
// This is also the only path that reaches `floatBucketIterator`'s interesting
// features from outside the package: both histograms are iterated at the
// receiver's schema, so a coarser receiver drives the merge path, and both are
// iterated from the receiver's zero threshold, which drives the
// absoluteStartValue skipping. Slice 1 could not pin either; this suite does.
//===----------------------------------------------------------------------===//

extension FloatHistogram {

    /// Go: `DetectReset` — true if the receiver is missing any bucket that has a
    /// non-zero population in `previous`, or if any count (in a bucket, in the
    /// zero count, or in the observation count, but **not** the sum) has
    /// decreased.
    ///
    /// Shortcuts to true on a `counterReset` hint and to false on
    /// `notCounterReset`. For `unknownCounterReset` it does the full work, and it
    /// does the same for `gaugeType` — which should not happen, but PromQL lets
    /// users apply counter-only functions to gauge histograms, and then a gauge is
    /// treated as a counter and the caller warns.
    ///
    /// Where the schema or zero threshold differ:
    ///
    /// - A smaller zero threshold or a larger schema (higher resolution) can only
    ///   happen together with a reset, so either returns true.
    /// - For a larger zero threshold, `previous`'s buckets inside the new
    ///   threshold are folded into its zero count, without mutating it. A bucket
    ///   that is only partly inside can only happen together with a reset, so that
    ///   shortcuts to true.
    /// - For a smaller schema, `previous`'s buckets are merged to match, again
    ///   without mutating it.
    public func detectReset(_ previous: FloatHistogram) -> Bool {
        if counterResetHint == .counterReset { return true }
        if counterResetHint == .notCounterReset { return false }
        if count < previous.count { return true }
        if usesCustomBuckets {
            if !previous.usesCustomBuckets {
                // Something changed, or the application restarted. It does not
                // matter much: the schema change is handled in the chunks and in
                // the PromQL functions.
                return true
            }
            if !customBucketBoundsMatch(customValues ?? [], previous.customValues ?? []) {
                // Bounds differ, so check whether any reconciled bucket decreased.
                return detectResetWithMismatchedCustomBounds(
                    previous, customValues ?? [], previous.customValues ?? [])
            }
        }
        if schema > previous.schema { return true }
        if zeroThreshold < previous.zeroThreshold {
            // The zero threshold decreased.
            return true
        }
        let (previousZeroCount, newThreshold, _) = previous.zeroCountForLargerThreshold(
            zeroThreshold, nil)
        if newThreshold != zeroThreshold {
            // The threshold is inside a populated bucket of the previous histogram.
            return true
        }
        if zeroCount < previousZeroCount { return true }

        var currIt = floatBucketIterator(
            positive: true, absoluteStartValue: zeroThreshold, targetSchema: schema)
        var prevIt = previous.floatBucketIterator(
            positive: true, absoluteStartValue: zeroThreshold, targetSchema: schema)
        if PromHistogram.detectReset(&currIt, &prevIt) { return true }

        currIt = floatBucketIterator(
            positive: false, absoluteStartValue: zeroThreshold, targetSchema: schema)
        prevIt = previous.floatBucketIterator(
            positive: false, absoluteStartValue: zeroThreshold, targetSchema: schema)
        return PromHistogram.detectReset(&currIt, &prevIt)
    }

    /// Go: `detectResetWithMismatchedCustomBounds` — whether any bucket count
    /// decreased, for two NHCBs whose bounds differ. Maps both onto the
    /// intersected bounds as it goes, rather than materialising the mapped
    /// buckets. Traps if either histogram is not an NHCB.
    func detectResetWithMismatchedCustomBounds(
        _ previous: FloatHistogram, _ currBounds: [Double], _ prevBounds: [Double]
    ) -> Bool {
        if schema != HistogramSchema.customBuckets
            || previous.schema != HistogramSchema.customBuckets
        {
            preconditionFailure("detectResetWithMismatchedCustomBounds called with non-NHCB schema")
        }
        var currIt = floatBucketIterator(
            positive: true, absoluteStartValue: 0, targetSchema: HistogramSchema.customBuckets)
        var prevIt = previous.floatBucketIterator(
            positive: true, absoluteStartValue: 0, targetSchema: HistogramSchema.customBuckets)

        /// Sums every bucket up to `bound`, advancing the iterator past them.
        func rollupSumForBound(
            _ iter: inout FloatBucketIterator, _ iterStarted: Bool,
            _ iterBucket: Bucket<Double>, _ bound: Double
        ) -> (sum: Double, bucket: Bucket<Double>, hasMore: Bool) {
            var iterBucket = iterBucket
            if !iterStarted {
                if !iter.next() {
                    return (0, Bucket.empty, false)
                }
                iterBucket = iter.at()
            }
            var sum: Double = 0
            while iterBucket.upper <= bound {
                sum += iterBucket.count
                if !iter.next() {
                    return (sum, Bucket.empty, false)
                }
                iterBucket = iter.at()
            }
            return (sum, iterBucket, true)
        }

        var currBoundIdx = 0
        var prevBoundIdx = 0
        var currBucket = Bucket<Double>.empty
        var prevBucket = Bucket<Double>.empty
        var currIterStarted = false
        var currHasMore = false
        var prevIterStarted = false
        var prevHasMore = false

        while currBoundIdx <= currBounds.count && prevBoundIdx <= prevBounds.count {
            var currBound = Double.infinity
            if currBoundIdx < currBounds.count {
                currBound = currBounds[currBoundIdx]
            }
            var prevBound = Double.infinity
            if prevBoundIdx < prevBounds.count {
                prevBound = prevBounds[prevBoundIdx]
            }

            if currBound == prevBound {
                // A matching bound: roll up the lesser buckets not yet accounted for.
                var currRollupSum = 0.0
                if !currIterStarted || currHasMore {
                    (currRollupSum, currBucket, currHasMore) = rollupSumForBound(
                        &currIt, currIterStarted, currBucket, currBound)
                    currIterStarted = true
                }

                var prevRollupSum = 0.0
                if !prevIterStarted || prevHasMore {
                    // Go passes currBound here, not prevBound — they are equal in
                    // this branch, so it does not matter, but the shape is kept.
                    (prevRollupSum, prevBucket, prevHasMore) = rollupSumForBound(
                        &prevIt, prevIterStarted, prevBucket, currBound)
                    prevIterStarted = true
                }

                if currRollupSum < prevRollupSum { return true }

                currBoundIdx += 1
                prevBoundIdx += 1
            } else if currBound < prevBound {
                currBoundIdx += 1
            } else {
                prevBoundIdx += 1
            }
        }

        return false
    }
}

/// Go: `detectReset` — walks two bucket iterators in lockstep looking for a
/// bucket that shrank or vanished.
func detectReset(_ currIt: inout FloatBucketIterator, _ prevIt: inout FloatBucketIterator) -> Bool {
    if !prevIt.next() {
        // No buckets in the previous histogram, so nothing can have been reset.
        return false
    }
    var prevBucket = prevIt.strippedAt()
    if !currIt.next() {
        // Nothing in the current histogram but something in the previous one.
        // This is a reset if any of those are populated.
        //
        // float_histogram.go:817 — Go's comment says "any", but the loop never
        // reassigns prevBucket, so only the FIRST previous bucket is ever
        // inspected: a populated bucket behind an empty one does not register as a
        // reset. Verified against Go and replicated; see docs/PORTING.md
        // "Replicated Go quirks".
        while true {
            if prevBucket.count != 0 { return true }
            if !prevIt.next() { return false }
        }
    }
    var currBucket = currIt.strippedAt()
    while true {
        // Forward currIt until it reaches the bucket corresponding to prevBucket.
        while currBucket.index < prevBucket.index {
            if !currIt.next() {
                // Reached the end of currIt early, so the previous histogram has a
                // bucket the current one does not. Unless every remaining previous
                // bucket is unpopulated, that is a reset — except that, as above,
                // Go only inspects the bucket it already has.
                while true {
                    if prevBucket.count != 0 { return true }
                    if !prevIt.next() { return false }
                }
            }
            currBucket = currIt.strippedAt()
        }
        if currBucket.index > prevBucket.index {
            // The previous histogram has a bucket the current one does not. If it
            // is populated, that is a reset.
            if prevBucket.count != 0 { return true }
        } else {
            // Corresponding buckets in both iterators: compare the counts.
            if currBucket.count < prevBucket.count { return true }
        }
        if !prevIt.next() {
            // Reached the end of prevIt without finding an offending bucket.
            return false
        }
        prevBucket = prevIt.strippedAt()
    }
}

extension Bucket {
    /// The zero value Go's `Bucket[float64]{}` literal produces.
    static var empty: Bucket<Count> {
        Bucket(
            lower: 0, upper: 0, lowerInclusive: false, upperInclusive: false,
            count: .zero, index: 0)
    }
}
