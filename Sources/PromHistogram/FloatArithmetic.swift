//===----------------------------------------------------------------------===//
// Ported from model/histogram/float_histogram.go @ v3.13.2 — the arithmetic:
// Mul, Div, Add, Sub, KahanAdd, and the machinery they need.
//
// Slices 2, 4 and 5 of HANDOFF §5b land together because Add/Sub/KahanAdd cannot
// be correct without all three: the mismatched-NHCB-bounds branch needs
// intersectCustomBucketBounds and addCustomBucketsWithMismatches, and KahanAdd
// needs kahanReduceResolution. Shipping the arithmetic with those paths stubbed
// would be shipping something silently wrong.
//
// Every Kahan variant runs through PromMath.Kahan, which is already pinned
// against Go's util/kahansum. Do not re-derive the compensation arithmetic here.
//
// Go's `goto nextLoop` inside addBuckets/kahanAddBuckets becomes `break body` out
// of a labelled `do`, with the three cursor updates Go puts under the label
// following it. That keeps the control flow identical; restructuring it into
// something more idiomatic is how the bucket-insertion cases get subtly wrong.
//===----------------------------------------------------------------------===//

private import GoCompat
private import PromMath

extension FloatHistogram {

    // MARK: - Scaling

    /// Go: `Mul` — multiplies every bucket count, the zero bucket, the count and
    /// the sum by `factor`. The bucket layout is unchanged. A negative factor sets
    /// the counter reset hint to `gaugeType`.
    @discardableResult
    public mutating func mul(_ factor: Double) -> FloatHistogram {
        zeroCount *= factor
        count *= factor
        sum *= factor
        for i in positiveBuckets.indices {
            positiveBuckets[i] *= factor
        }
        for i in negativeBuckets.indices {
            negativeBuckets[i] *= factor
        }
        if factor < 0 {
            counterResetHint = .gaugeType
        }
        return self
    }

    /// Go: `Div` — like `mul(_:)` but dividing. Dividing by 0 sets the scalars to
    /// infinities and removes every bucket. A negative scalar sets the counter
    /// reset hint to `gaugeType`.
    @discardableResult
    public mutating func div(_ scalar: Double) -> FloatHistogram {
        zeroCount /= scalar
        count /= scalar
        sum /= scalar
        // Division by zero removes all buckets.
        if scalar == 0 {
            positiveBuckets = []
            negativeBuckets = []
            positiveSpans = []
            negativeSpans = []
            return self
        }
        for i in positiveBuckets.indices {
            positiveBuckets[i] /= scalar
        }
        for i in negativeBuckets.indices {
            negativeBuckets[i] /= scalar
        }
        if scalar < 0 {
            counterResetHint = .gaugeType
        }
        return self
    }

    // MARK: - Add and Sub

    /// The flags Go returns alongside the receiver from `Add`/`Sub`/`KahanAdd`.
    public struct AddResult: Sendable, Equatable {
        /// One histogram said `counterReset` and the other `notCounterReset`. The
        /// receiver's hint has been set to `unknownCounterReset`; the caller is
        /// expected to warn.
        public var counterResetCollision: Bool
        /// The two histograms had different custom bounds, so both were mapped
        /// onto the intersection of their bounds.
        public var nhcbBoundsReconciled: Bool
    }

    /// Go: `Add` — adds `other` into the receiver. Counts, sums and buckets are
    /// added componentwise, and buckets present only in `other` are inserted.
    ///
    /// The result may contain buckets with a population of zero, or directly
    /// adjacent spans; call `compact(maxEmptyBuckets:)` to normalise.
    ///
    /// Differences in zero threshold and schema are reconciled, changing the
    /// receiver's if needed. `other` is never modified. Only two exponential
    /// histograms, or two custom-buckets histograms, can be added; mismatched
    /// custom bounds are reconciled to their intersection.
    ///
    /// Go returns the receiver for convenience; the receiver is mutated in place
    /// here, so only the flags come back.
    @discardableResult
    public mutating func add(_ other: FloatHistogram) throws -> AddResult {
        try checkSchemaAndBounds(other)
        var result = AddResult(
            counterResetCollision: adjustCounterReset(other), nhcbBoundsReconciled: false)
        if !usesCustomBuckets {
            let (otherZeroCount, _) = reconcileZeroBucketsWithoutCompensation(other)
            zeroCount += otherZeroCount
        }
        count += other.count
        sum += other.sum

        var hPositiveSpans = positiveSpans
        var hPositiveBuckets = positiveBuckets
        var otherPositiveSpans = other.positiveSpans
        var otherPositiveBuckets = other.positiveBuckets

        if usesCustomBuckets {
            if customBucketBoundsMatch(customValues ?? [], other.customValues ?? []) {
                (positiveSpans, positiveBuckets) = addBuckets(
                    schema: schema, threshold: zeroThreshold, negative: false,
                    spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
                    spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets)
            } else {
                result.nhcbBoundsReconciled = true
                let intersectedBounds = intersectCustomBucketBounds(
                    customValues ?? [], other.customValues ?? [])

                // Add with mapping — maps both histograms to the intersected layout.
                (positiveSpans, positiveBuckets, _) = addCustomBucketsWithMismatches(
                    negative: false,
                    spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
                    boundsA: customValues ?? [],
                    spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets,
                    boundsB: other.customValues ?? [],
                    bucketsC: nil, intersectedBounds: intersectedBounds)
                customValues = intersectedBounds
            }
            return result
        }

        var hNegativeSpans = negativeSpans
        var hNegativeBuckets = negativeBuckets
        var otherNegativeSpans = other.negativeSpans
        var otherNegativeBuckets = other.negativeBuckets

        if other.schema < schema {
            (hPositiveSpans, hPositiveBuckets) = mustReduceResolution(
                originSpans: hPositiveSpans, originBuckets: hPositiveBuckets,
                originSchema: schema, targetSchema: other.schema, deltaBuckets: false)
            (hNegativeSpans, hNegativeBuckets) = mustReduceResolution(
                originSpans: hNegativeSpans, originBuckets: hNegativeBuckets,
                originSchema: schema, targetSchema: other.schema, deltaBuckets: false)
            schema = other.schema
        } else if other.schema > schema {
            (otherPositiveSpans, otherPositiveBuckets) = mustReduceResolution(
                originSpans: otherPositiveSpans, originBuckets: otherPositiveBuckets,
                originSchema: other.schema, targetSchema: schema, deltaBuckets: false)
            (otherNegativeSpans, otherNegativeBuckets) = mustReduceResolution(
                originSpans: otherNegativeSpans, originBuckets: otherNegativeBuckets,
                originSchema: other.schema, targetSchema: schema, deltaBuckets: false)
        }

        (positiveSpans, positiveBuckets) = addBuckets(
            schema: schema, threshold: zeroThreshold, negative: false,
            spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
            spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets)
        (negativeSpans, negativeBuckets) = addBuckets(
            schema: schema, threshold: zeroThreshold, negative: false,
            spansA: hNegativeSpans, bucketsA: hNegativeBuckets,
            spansB: otherNegativeSpans, bucketsB: otherNegativeBuckets)

        return result
    }

    /// Go: `Sub` — like `add(_:)` but subtracting. It adjusts the counter reset
    /// hint the same way, which is what incremental mean calculation wants; for
    /// PromQL's `-` operator the caller must set the hint to `gaugeType`
    /// afterwards.
    @discardableResult
    public mutating func sub(_ other: FloatHistogram) throws -> AddResult {
        try checkSchemaAndBounds(other)
        var result = AddResult(
            counterResetCollision: adjustCounterReset(other), nhcbBoundsReconciled: false)
        if !usesCustomBuckets {
            let (otherZeroCount, _) = reconcileZeroBucketsWithoutCompensation(other)
            zeroCount -= otherZeroCount
        }
        count -= other.count
        sum -= other.sum

        var hPositiveSpans = positiveSpans
        var hPositiveBuckets = positiveBuckets
        var otherPositiveSpans = other.positiveSpans
        var otherPositiveBuckets = other.positiveBuckets

        if usesCustomBuckets {
            if customBucketBoundsMatch(customValues ?? [], other.customValues ?? []) {
                (positiveSpans, positiveBuckets) = addBuckets(
                    schema: schema, threshold: zeroThreshold, negative: true,
                    spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
                    spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets)
            } else {
                result.nhcbBoundsReconciled = true
                let intersectedBounds = intersectCustomBucketBounds(
                    customValues ?? [], other.customValues ?? [])

                // Subtract with mapping — maps both histograms to the intersected
                // layout.
                (positiveSpans, positiveBuckets, _) = addCustomBucketsWithMismatches(
                    negative: true,
                    spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
                    boundsA: customValues ?? [],
                    spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets,
                    boundsB: other.customValues ?? [],
                    bucketsC: nil, intersectedBounds: intersectedBounds)
                customValues = intersectedBounds
            }
            return result
        }

        var hNegativeSpans = negativeSpans
        var hNegativeBuckets = negativeBuckets
        var otherNegativeSpans = other.negativeSpans
        var otherNegativeBuckets = other.negativeBuckets

        if other.schema < schema {
            (hPositiveSpans, hPositiveBuckets) = mustReduceResolution(
                originSpans: hPositiveSpans, originBuckets: hPositiveBuckets,
                originSchema: schema, targetSchema: other.schema, deltaBuckets: false)
            (hNegativeSpans, hNegativeBuckets) = mustReduceResolution(
                originSpans: hNegativeSpans, originBuckets: hNegativeBuckets,
                originSchema: schema, targetSchema: other.schema, deltaBuckets: false)
            schema = other.schema
        } else if other.schema > schema {
            (otherPositiveSpans, otherPositiveBuckets) = mustReduceResolution(
                originSpans: otherPositiveSpans, originBuckets: otherPositiveBuckets,
                originSchema: other.schema, targetSchema: schema, deltaBuckets: false)
            (otherNegativeSpans, otherNegativeBuckets) = mustReduceResolution(
                originSpans: otherNegativeSpans, originBuckets: otherNegativeBuckets,
                originSchema: other.schema, targetSchema: schema, deltaBuckets: false)
        }

        (positiveSpans, positiveBuckets) = addBuckets(
            schema: schema, threshold: zeroThreshold, negative: true,
            spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
            spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets)
        (negativeSpans, negativeBuckets) = addBuckets(
            schema: schema, threshold: zeroThreshold, negative: true,
            spansA: hNegativeSpans, bucketsA: hNegativeBuckets,
            spansB: otherNegativeSpans, bucketsB: otherNegativeBuckets)

        return result
    }

    /// Go: `KahanAdd` — like `add(_:)` but accumulating through Kahan summation to
    /// minimise numerical error.
    ///
    /// `c` holds the compensation terms. Pass nil to have one created; the
    /// returned `updatedC` must be used either way, since Go's `c` parameter is
    /// only updated in place when it was non-nil.
    public mutating func kahanAdd(
        _ other: FloatHistogram, _ c: FloatHistogram?
    ) throws -> (updatedC: FloatHistogram, result: AddResult) {
        try checkSchemaAndBounds(other)

        var result = AddResult(
            counterResetCollision: adjustCounterReset(other), nhcbBoundsReconciled: false)

        var c = c ?? newCompensationHistogram()
        if !usesCustomBuckets {
            let (otherZeroCount, otherCZeroCount) = reconcileZeroBuckets(other, &c)
            (zeroCount, c.zeroCount) = Kahan.inc(otherZeroCount, zeroCount, c.zeroCount)
            (zeroCount, c.zeroCount) = Kahan.inc(otherCZeroCount, zeroCount, c.zeroCount)
        }
        (count, c.count) = Kahan.inc(other.count, count, c.count)
        (sum, c.sum) = Kahan.inc(other.sum, sum, c.sum)

        var hPositiveSpans = positiveSpans
        var hPositiveBuckets = positiveBuckets
        var otherPositiveSpans = other.positiveSpans
        var otherPositiveBuckets = other.positiveBuckets
        var cPositiveBuckets = c.positiveBuckets

        if usesCustomBuckets {
            if customBucketBoundsMatch(customValues ?? [], other.customValues ?? []) {
                (positiveSpans, positiveBuckets, c.positiveBuckets) = kahanAddBuckets(
                    schema: schema, threshold: zeroThreshold, negative: false,
                    spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
                    spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets,
                    compensationBucketsA: cPositiveBuckets, compensationBucketsB: nil)
            } else {
                result.nhcbBoundsReconciled = true
                let intersectedBounds = intersectCustomBucketBounds(
                    customValues ?? [], other.customValues ?? [])

                // Add with mapping — maps both histograms to the intersected layout.
                (positiveSpans, positiveBuckets, c.positiveBuckets) =
                    addCustomBucketsWithMismatches(
                        negative: false,
                        spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
                        boundsA: customValues ?? [],
                        spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets,
                        boundsB: other.customValues ?? [],
                        bucketsC: cPositiveBuckets, intersectedBounds: intersectedBounds)
                customValues = intersectedBounds
                c.customValues = intersectedBounds
            }
            c.positiveSpans = positiveSpans
            return (c, result)
        }

        var hNegativeSpans = negativeSpans
        var hNegativeBuckets = negativeBuckets
        var otherNegativeSpans = other.negativeSpans
        var otherNegativeBuckets = other.negativeBuckets
        var cNegativeBuckets = c.negativeBuckets
        var otherCPositiveBuckets: [Double]?
        var otherCNegativeBuckets: [Double]?

        if other.schema < schema {
            (hPositiveSpans, hPositiveBuckets, cPositiveBuckets) = kahanReduceResolution(
                originSpans: hPositiveSpans, originReceivingBuckets: hPositiveBuckets,
                originCompensationBuckets: cPositiveBuckets,
                originSchema: schema, targetSchema: other.schema)
            (hNegativeSpans, hNegativeBuckets, cNegativeBuckets) = kahanReduceResolution(
                originSpans: hNegativeSpans, originReceivingBuckets: hNegativeBuckets,
                originCompensationBuckets: cNegativeBuckets,
                originSchema: schema, targetSchema: other.schema)
            schema = other.schema
        } else if other.schema > schema {
            if !otherPositiveBuckets.isEmpty {
                (otherPositiveSpans, otherPositiveBuckets, otherCPositiveBuckets) =
                    kahanReduceResolution(
                        originSpans: otherPositiveSpans,
                        originReceivingBuckets: otherPositiveBuckets,
                        originCompensationBuckets: [Double](
                            repeating: 0, count: otherPositiveBuckets.count),
                        originSchema: other.schema, targetSchema: schema)
            }
            if !otherNegativeBuckets.isEmpty {
                (otherNegativeSpans, otherNegativeBuckets, otherCNegativeBuckets) =
                    kahanReduceResolution(
                        originSpans: otherNegativeSpans,
                        originReceivingBuckets: otherNegativeBuckets,
                        originCompensationBuckets: [Double](
                            repeating: 0, count: otherNegativeBuckets.count),
                        originSchema: other.schema, targetSchema: schema)
            }
        }

        (positiveSpans, positiveBuckets, c.positiveBuckets) = kahanAddBuckets(
            schema: schema, threshold: zeroThreshold, negative: false,
            spansA: hPositiveSpans, bucketsA: hPositiveBuckets,
            spansB: otherPositiveSpans, bucketsB: otherPositiveBuckets,
            compensationBucketsA: cPositiveBuckets, compensationBucketsB: otherCPositiveBuckets)
        (negativeSpans, negativeBuckets, c.negativeBuckets) = kahanAddBuckets(
            schema: schema, threshold: zeroThreshold, negative: false,
            spansA: hNegativeSpans, bucketsA: hNegativeBuckets,
            spansB: otherNegativeSpans, bucketsB: otherNegativeBuckets,
            compensationBucketsA: cNegativeBuckets, compensationBucketsB: otherCNegativeBuckets)

        c.schema = schema
        c.zeroThreshold = zeroThreshold
        c.positiveSpans = positiveSpans
        c.negativeSpans = negativeSpans

        return (c, result)
    }

    /// Go: `kahanCompact` — `compact(maxEmptyBuckets:)` specialised for
    /// `kahanAdd`, keeping the compensation buckets in step.
    mutating func kahanCompact(maxEmptyBuckets: Int, _ c: inout FloatHistogram) {
        var compensation: [Double]? = c.positiveBuckets
        (positiveBuckets, compensation, positiveSpans) = compactBuckets(
            primaryBuckets: positiveBuckets, compensationBuckets: compensation,
            spans: positiveSpans, maxEmptyBuckets: maxEmptyBuckets, deltaBuckets: false)
        c.positiveBuckets = compensation ?? []

        compensation = c.negativeBuckets
        (negativeBuckets, compensation, negativeSpans) = compactBuckets(
            primaryBuckets: negativeBuckets, compensationBuckets: compensation,
            spans: negativeSpans, maxEmptyBuckets: maxEmptyBuckets, deltaBuckets: false)
        c.negativeBuckets = compensation ?? []
    }

    // MARK: - Zero-bucket reconciliation

    /// Go: `zeroCountForLargerThreshold` — what the zero count would be if the
    /// threshold had the provided larger (or equal) value, plus the compensation
    /// histogram's zero count when one is given.
    ///
    /// Traps if `largerThreshold` is smaller than the current threshold. If it
    /// lands inside a populated bucket it is raised to that bucket's upper limit
    /// (in absolute terms) and that bucket's count is included; the adjusted
    /// threshold is returned.
    func zeroCountForLargerThreshold(
        _ largerThreshold: Double, _ c: FloatHistogram?
    ) -> (hZeroCount: Double, threshold: Double, cZeroCount: Double) {
        var largerThreshold = largerThreshold
        var cZeroCount: Double = 0
        if let c { cZeroCount = c.zeroCount }
        // Fast path.
        if largerThreshold == zeroThreshold {
            return (zeroCount, largerThreshold, cZeroCount)
        }
        if largerThreshold < zeroThreshold {
            // Go: fmt.Errorf with %f, which is precision 6.
            preconditionFailure(
                "new threshold \(GoFloat.format(largerThreshold, .f, precision: 6)) is less than "
                    + "old threshold \(GoFloat.format(zeroThreshold, .f, precision: 6))")
        }
        outer: while true {
            var hZeroCount = zeroCount
            var i = positiveBucketIterator()
            var bucketsIdx = 0
            while i.next() {
                let b = i.at()
                if b.lower >= largerThreshold { break }
                // Bucket to be merged into the zero bucket.
                (hZeroCount, cZeroCount) = Kahan.inc(b.count, hZeroCount, cZeroCount)
                if let c {
                    (hZeroCount, cZeroCount) = Kahan.inc(
                        c.positiveBuckets[bucketsIdx], hZeroCount, cZeroCount)
                }
                if b.upper > largerThreshold {
                    // The new threshold ended up inside a bucket. If it is
                    // populated, adjust largerThreshold before finishing.
                    if b.count != 0 {
                        largerThreshold = b.upper
                    }
                    break
                }
                bucketsIdx += 1
            }
            var j = negativeBucketIterator()
            bucketsIdx = 0
            var restart = false
            while j.next() {
                let b = j.at()
                if b.upper <= -largerThreshold { break }
                // Bucket to be merged into the zero bucket.
                (hZeroCount, cZeroCount) = Kahan.inc(b.count, hZeroCount, cZeroCount)
                if let c {
                    (hZeroCount, cZeroCount) = Kahan.inc(
                        c.negativeBuckets[bucketsIdx], hZeroCount, cZeroCount)
                }
                if b.lower < -largerThreshold {
                    // The new threshold ended up inside a bucket. If it is
                    // populated, adjust largerThreshold and redo the whole thing,
                    // because the treatment of the positive buckets is invalid now.
                    if b.count != 0 {
                        largerThreshold = -b.lower
                        restart = true
                    }
                    break
                }
                bucketsIdx += 1
            }
            if restart { continue outer }
            return (hZeroCount, largerThreshold, cZeroCount)
        }
    }

    /// Go: `trimBucketsInZeroBucket` — removes every bucket inside the zero
    /// bucket. Assumes the threshold sits on a bucket boundary and that the counts
    /// being removed are already part of the zero count.
    mutating func trimBucketsInZeroBucket(_ c: inout FloatHistogram?) {
        var i = positiveBucketIterator()
        var bucketsIdx = 0
        while i.next() {
            let b = i.at()
            if b.lower >= zeroThreshold { break }
            positiveBuckets[bucketsIdx] = 0
            if c != nil { c!.positiveBuckets[bucketsIdx] = 0 }
            bucketsIdx += 1
        }
        var j = negativeBucketIterator()
        bucketsIdx = 0
        while j.next() {
            let b = j.at()
            if b.upper <= -zeroThreshold { break }
            negativeBuckets[bucketsIdx] = 0
            if c != nil { c!.negativeBuckets[bucketsIdx] = 0 }
            bucketsIdx += 1
        }
        // Go abuses Compact to trim the buckets zeroed above. Compacting early
        // could cost something, but this path is rarely used.
        if c != nil {
            kahanCompact(maxEmptyBuckets: 0, &c!)
        } else {
            compact(maxEmptyBuckets: 0)
        }
    }

    /// Go: `reconcileZeroBuckets` — finds a zero bucket large enough to cover both
    /// histograms' zero buckets, with a threshold that is not inside a populated
    /// bucket in either. Modifies the receiver (and `c`), leaves `other` alone,
    /// and returns the zero count `other` would have had.
    ///
    /// Note the loop condition is `!=` on the thresholds: a NaN threshold on
    /// either side makes it spin forever, in Go as here. Nothing upstream can
    /// produce one, and the fixture corpus deliberately does not either.
    /// Overload for a caller that always has a compensation histogram, so the
    /// updates land back in it.
    mutating func reconcileZeroBuckets(
        _ other: FloatHistogram, _ c: inout FloatHistogram
    ) -> (otherZeroCount: Double, otherCZeroCount: Double) {
        var optional: FloatHistogram? = c
        let result = reconcileZeroBuckets(other, &optional)
        c = optional!
        return result
    }

    /// Overload for Go's `reconcileZeroBuckets(other, nil)`. Spelled out rather
    /// than taking an Optional by value, which would silently discard the
    /// compensation updates if anyone passed a real histogram to it.
    mutating func reconcileZeroBucketsWithoutCompensation(
        _ other: FloatHistogram
    ) -> (otherZeroCount: Double, otherCZeroCount: Double) {
        var none: FloatHistogram?
        return reconcileZeroBuckets(other, &none)
    }

    private mutating func reconcileZeroBuckets(
        _ other: FloatHistogram, _ c: inout FloatHistogram?
    ) -> (otherZeroCount: Double, otherCZeroCount: Double) {
        var otherZeroCount = other.zeroCount
        var otherCZeroCount: Double = 0
        var otherZeroThreshold = other.zeroThreshold

        while otherZeroThreshold != zeroThreshold {
            if zeroThreshold > otherZeroThreshold {
                (otherZeroCount, otherZeroThreshold, otherCZeroCount) =
                    other.zeroCountForLargerThreshold(zeroThreshold, nil)
            }
            if otherZeroThreshold > zeroThreshold {
                let (newZeroCount, newThreshold, cZeroCount) = zeroCountForLargerThreshold(
                    otherZeroThreshold, c)
                zeroCount = newZeroCount
                zeroThreshold = newThreshold
                if c != nil { c!.zeroCount = cZeroCount }
                trimBucketsInZeroBucket(&c)
            }
        }
        return (otherZeroCount, otherCZeroCount)
    }

    // MARK: - Supporting pieces

    /// Go: `newCompensationHistogram` — a companion histogram for Kahan summation,
    /// matching this one's layout with all bucket values zeroed.
    func newCompensationHistogram() -> FloatHistogram {
        var c = FloatHistogram(
            counterResetHint: counterResetHint,
            schema: schema,
            zeroThreshold: zeroThreshold,
            positiveSpans: positiveSpans,
            negativeSpans: negativeSpans,
            positiveBuckets: [Double](repeating: 0, count: positiveBuckets.count),
            customValues: customValues)
        if !usesCustomBuckets {
            c.negativeBuckets = [Double](repeating: 0, count: negativeBuckets.count)
        }
        return c
    }

    /// Go: `checkSchemaAndBounds` — two histograms are compatible when both use a
    /// standard exponential schema, or both are NHCBs.
    func checkSchemaAndBounds(_ other: FloatHistogram) throws {
        if usesCustomBuckets != other.usesCustomBuckets {
            throw HistogramError.incompatibleSchema
        }
    }

    /// Go: `adjustCounterReset` — addition and subtraction are usually only done
    /// between gauge histograms, but if one or both are counters this at least
    /// sets the hint to something meaningful. Returns true when the two hints
    /// collide, meaning one said `counterReset` and the other `notCounterReset`.
    mutating func adjustCounterReset(_ other: FloatHistogram) -> Bool {
        if other.counterResetHint == counterResetHint {
            // Adding apples to apples, all good. Nothing to change.
            return false
        }
        if counterResetHint == .gaugeType {
            // Adding something else to a gauge. Probably fine; the outcome is a
            // gauge, which the receiver already says.
            return false
        }
        if other.counterResetHint == .gaugeType {
            // As before, but this time the receiver is the "something else".
            counterResetHint = .gaugeType
            return false
        }
        if counterResetHint == .unknownCounterReset {
            // Still legitimate if the caller knows what they are doing. The
            // outcome is "unknown", which the receiver already says.
            return false
        }
        if other.counterResetHint == .unknownCounterReset {
            counterResetHint = .unknownCounterReset
            return false
        }
        // All other cases should not happen: they are a direct collision of
        // counterReset and notCounterReset. Conservatively go to "unknown" and
        // let the caller warn.
        counterResetHint = .unknownCounterReset
        return true
    }

    /// Go: `ReduceResolution` — reduces the spans and buckets into `targetSchema`.
    ///
    /// Carries the same post-error quirk as the integer histogram: Go assigns
    /// `reduceResolution`'s `nil, nil` result before testing the error, so a
    /// rejected histogram is left with that side cleared. See docs/PORTING.md
    /// "Replicated Go quirks".
    public mutating func reduceResolution(targetSchema: Int32) throws {
        // Not histogram errors: Go returns plain ones here, because these are
        // programming errors rather than bad data.
        if usesCustomBuckets {
            throw HistogramOperationError.reduceResolutionFromCustomBuckets
        }
        if isCustomBucketsSchema(targetSchema) {
            throw HistogramOperationError.reduceResolutionToCustomBuckets
        }
        if targetSchema >= schema {
            throw HistogramOperationError.reduceResolutionSchema(
                from: schema, to: targetSchema)
        }

        do {
            (positiveSpans, positiveBuckets) = try PromHistogram.reduceResolution(
                originSpans: positiveSpans, originBuckets: positiveBuckets,
                originSchema: schema, targetSchema: targetSchema, deltaBuckets: false)
        } catch {
            positiveSpans = []
            positiveBuckets = []
            throw error
        }
        do {
            (negativeSpans, negativeBuckets) = try PromHistogram.reduceResolution(
                originSpans: negativeSpans, originBuckets: negativeBuckets,
                originSchema: schema, targetSchema: targetSchema, deltaBuckets: false)
        } catch {
            negativeSpans = []
            negativeBuckets = []
            throw error
        }

        schema = targetSchema
    }
}

// MARK: - Bucket addition

/// Go: `addBuckets` — adds the buckets described by `spansB`/`bucketsB` into
/// `spansA`/`bucketsA`, creating missing buckets as needed.
///
/// All buckets must use the given schema. Buckets in B whose absolute upper limit
/// is ≤ `threshold` are ignored. When `negative` is true, B is subtracted.
func addBuckets(
    schema: Int32, threshold: Double, negative: Bool,
    spansA spansAIn: [Span], bucketsA bucketsAIn: [Double],
    spansB: [Span], bucketsB: [Double]
) -> ([Span], [Double]) {
    var spansA = spansAIn
    var bucketsA = bucketsAIn

    var iSpan = -1
    var iBucket = -1
    var iInSpan: Int32 = 0
    var indexA: Int32 = 0
    var indexB: Int32 = 0
    var bIdxB = 0
    var bucketB: Double = 0
    var deltaIndex: Int32 = 0
    var lowerThanThreshold = true

    for spanB in spansB {
        indexB += spanB.offset
        for _ in 0..<Int(spanB.length) {
            // `break body` is Go's `goto nextLoop`: skip the rest of the body but
            // still advance the three cursors below.
            body: do {
                if lowerThanThreshold, isExponentialSchema(schema),
                    getBoundExponential(indexB, schema) <= threshold
                {
                    break body
                }
                lowerThanThreshold = false

                bucketB = bucketsB[bIdxB]
                if negative {
                    bucketB *= -1
                }

                if iSpan == -1 {
                    if spansA.isEmpty || spansA[0].offset > indexB {
                        // Add a bucket before all others.
                        bucketsA.insert(bucketB, at: 0)
                        if !spansA.isEmpty && spansA[0].offset == indexB + 1 {
                            spansA[0].length += 1
                            spansA[0].offset -= 1
                            break body
                        }
                        spansA.insert(Span(offset: indexB, length: 1), at: 0)
                        if spansA.count > 1 {
                            // Convert the absolute offset in the formerly first
                            // span to a relative one.
                            spansA[1].offset -= indexB + 1
                        }
                        break body
                    } else if spansA[0].offset == indexB {
                        // Just add to the first bucket.
                        bucketsA[0] += bucketB
                        break body
                    }
                    iSpan = 0
                    iBucket = 0
                    iInSpan = 0
                    indexA = spansA[0].offset
                }
                deltaIndex = indexB - indexA
                inner: while true {
                    let remainingInSpan = Int32(spansA[iSpan].length) - iInSpan
                    if deltaIndex < remainingInSpan {
                        // The bucket is in the current span.
                        iBucket += Int(deltaIndex)
                        iInSpan += deltaIndex
                        bucketsA[iBucket] += bucketB
                        break inner
                    }
                    deltaIndex -= remainingInSpan
                    iBucket += Int(remainingInSpan)
                    iSpan += 1
                    if iSpan == spansA.count || deltaIndex < spansA[iSpan].offset {
                        // The bucket is in the gap behind the previous span, or
                        // there are no further spans.
                        bucketsA.insert(bucketB, at: iBucket)
                        if deltaIndex == 0 {
                            // Directly after the previous span: extend it.
                            if iSpan < spansA.count {
                                spansA[iSpan].offset -= 1
                            }
                            iSpan -= 1
                            iInSpan = Int32(spansA[iSpan].length)
                            spansA[iSpan].length += 1
                            break body
                        } else if iSpan < spansA.count, deltaIndex == spansA[iSpan].offset - 1 {
                            // Directly before the next span: extend that one.
                            iInSpan = 0
                            spansA[iSpan].offset -= 1
                            spansA[iSpan].length += 1
                            break body
                        } else {
                            // No next span, or it is not adjacent to the new
                            // bucket. Add a new span.
                            iInSpan = 0
                            if iSpan < spansA.count {
                                spansA[iSpan].offset -= deltaIndex + 1
                            }
                            spansA.insert(Span(offset: deltaIndex, length: 1), at: iSpan)
                            break body
                        }
                    } else {
                        // Try the start of the next span.
                        deltaIndex -= spansA[iSpan].offset
                        iInSpan = 0
                    }
                }
            }

            // nextLoop:
            indexA = indexB
            indexB += 1
            bIdxB += 1
        }
    }

    return (spansA, bucketsA)
}

/// Go: `kahanAddBuckets` — `addBuckets` for `kahanAdd`, carrying the compensation
/// buckets of both sides.
func kahanAddBuckets(
    schema: Int32, threshold: Double, negative: Bool,
    spansA spansAIn: [Span], bucketsA bucketsAIn: [Double],
    spansB: [Span], bucketsB: [Double],
    compensationBucketsA compensationBucketsAIn: [Double], compensationBucketsB: [Double]?
) -> (newSpans: [Span], newBucketsA: [Double], newBucketsC: [Double]) {
    var spansA = spansAIn
    var bucketsA = bucketsAIn
    var compensationBucketsA = compensationBucketsAIn

    var iSpan = -1
    var iBucket = -1
    var iInSpan: Int32 = 0
    var indexA: Int32 = 0
    var indexB: Int32 = 0
    var bIdxB = 0
    var bucketB: Double = 0
    var compensationBucketB: Double = 0
    var deltaIndex: Int32 = 0
    var lowerThanThreshold = true

    for spanB in spansB {
        indexB += spanB.offset
        for _ in 0..<Int(spanB.length) {
            body: do {
                if lowerThanThreshold, isExponentialSchema(schema),
                    getBoundExponential(indexB, schema) <= threshold
                {
                    break body
                }
                lowerThanThreshold = false

                bucketB = bucketsB[bIdxB]
                if let compensationBucketsB {
                    compensationBucketB = compensationBucketsB[bIdxB]
                }
                if negative {
                    bucketB *= -1
                    compensationBucketB *= -1
                }

                if iSpan == -1 {
                    if spansA.isEmpty || spansA[0].offset > indexB {
                        // Add a bucket before all others.
                        bucketsA.insert(bucketB, at: 0)
                        compensationBucketsA.insert(compensationBucketB, at: 0)
                        if !spansA.isEmpty && spansA[0].offset == indexB + 1 {
                            spansA[0].length += 1
                            spansA[0].offset -= 1
                            break body
                        }
                        spansA.insert(Span(offset: indexB, length: 1), at: 0)
                        if spansA.count > 1 {
                            // Convert the absolute offset in the formerly first
                            // span to a relative one.
                            spansA[1].offset -= indexB + 1
                        }
                        break body
                    } else if spansA[0].offset == indexB {
                        // Just add to the first bucket.
                        (bucketsA[0], compensationBucketsA[0]) = Kahan.inc(
                            bucketB, bucketsA[0], compensationBucketsA[0])
                        if compensationBucketB != 0 {
                            (bucketsA[0], compensationBucketsA[0]) = Kahan.inc(
                                compensationBucketB, bucketsA[0], compensationBucketsA[0])
                        }
                        break body
                    }
                    iSpan = 0
                    iBucket = 0
                    iInSpan = 0
                    indexA = spansA[0].offset
                }
                deltaIndex = indexB - indexA
                inner: while true {
                    let remainingInSpan = Int32(spansA[iSpan].length) - iInSpan
                    if deltaIndex < remainingInSpan {
                        // The bucket is in the current span.
                        iBucket += Int(deltaIndex)
                        iInSpan += deltaIndex
                        (bucketsA[iBucket], compensationBucketsA[iBucket]) = Kahan.inc(
                            bucketB, bucketsA[iBucket], compensationBucketsA[iBucket])
                        if compensationBucketB != 0 {
                            (bucketsA[iBucket], compensationBucketsA[iBucket]) = Kahan.inc(
                                compensationBucketB, bucketsA[iBucket],
                                compensationBucketsA[iBucket])
                        }
                        break inner
                    }
                    deltaIndex -= remainingInSpan
                    iBucket += Int(remainingInSpan)
                    iSpan += 1
                    if iSpan == spansA.count || deltaIndex < spansA[iSpan].offset {
                        // The bucket is in the gap behind the previous span, or
                        // there are no further spans.
                        bucketsA.insert(bucketB, at: iBucket)
                        compensationBucketsA.insert(compensationBucketB, at: iBucket)
                        if deltaIndex == 0 {
                            // Directly after the previous span: extend it.
                            if iSpan < spansA.count {
                                spansA[iSpan].offset -= 1
                            }
                            iSpan -= 1
                            iInSpan = Int32(spansA[iSpan].length)
                            spansA[iSpan].length += 1
                            break body
                        } else if iSpan < spansA.count, deltaIndex == spansA[iSpan].offset - 1 {
                            // Directly before the next span: extend that one.
                            iInSpan = 0
                            spansA[iSpan].offset -= 1
                            spansA[iSpan].length += 1
                            break body
                        } else {
                            // No next span, or it is not adjacent to the new
                            // bucket. Add a new span.
                            iInSpan = 0
                            if iSpan < spansA.count {
                                spansA[iSpan].offset -= deltaIndex + 1
                            }
                            spansA.insert(Span(offset: deltaIndex, length: 1), at: iSpan)
                            break body
                        }
                    } else {
                        // Try the start of the next span.
                        deltaIndex -= spansA[iSpan].offset
                        iInSpan = 0
                    }
                }
            }

            // nextLoop:
            indexA = indexB
            indexB += 1
            bIdxB += 1
        }
    }

    return (spansA, bucketsA, compensationBucketsA)
}

// MARK: - Custom-bucket reconciliation

/// Go: `intersectCustomBucketBounds` — the intersection of two custom bound sets.
func intersectCustomBucketBounds(_ boundsA: [Double], _ boundsB: [Double]) -> [Double]? {
    if boundsA.isEmpty || boundsB.isEmpty { return nil }

    var result: [Double]?
    var i = 0
    var j = 0

    while i < boundsA.count && j < boundsB.count {
        if boundsA[i] == boundsB[j] {
            if result == nil {
                // A fresh array: FloatHistogram.customValues has to be immutable.
                result = []
                result!.reserveCapacity(min(boundsA.count, boundsB.count))
            }
            result!.append(boundsA[i])
            i += 1
            j += 1
        } else if boundsA[i] < boundsB[j] {
            i += 1
        } else {
            j += 1
        }
    }

    return result
}

/// Go: `addCustomBucketsWithMismatches` — adds or subtracts two NHCBs whose
/// bounds differ, by mapping both onto the intersected layout. Also carries the
/// Kahan compensation term when one is given.
func addCustomBucketsWithMismatches(
    negative: Bool,
    spansA: [Span], bucketsA: [Double], boundsA: [Double],
    spansB: [Span], bucketsB: [Double], boundsB: [Double],
    bucketsC: [Double]?,
    intersectedBounds: [Double]?
) -> ([Span], [Double], [Double]) {
    let intersectedBounds = intersectedBounds ?? []
    var targetBuckets = [Double](repeating: 0, count: intersectedBounds.count + 1)
    var cTargetBuckets = [Double](repeating: 0, count: intersectedBounds.count + 1)

    func mapBuckets(
        _ spans: [Span], _ buckets: [Double], _ bounds: [Double],
        _ negative: Bool, _ withCompensation: Bool
    ) {
        var srcIdx = 0
        var bucketIdx = 0
        var intersectIdx = 0

        for span in spans {
            srcIdx += Int(span.offset)
            for _ in 0..<Int(span.length) {
                if bucketIdx < buckets.count {
                    let value = buckets[bucketIdx]

                    // Find the target bucket index.
                    var targetIdx = targetBuckets.count - 1  // Default to the +Inf bucket.
                    if srcIdx < bounds.count {
                        let srcBound = bounds[srcIdx]
                        // Both arrays are sorted, so continue from where we left off.
                        while intersectIdx < intersectedBounds.count {
                            if intersectedBounds[intersectIdx] >= srcBound {
                                targetIdx = intersectIdx
                                break
                            }
                            intersectIdx += 1
                        }
                    }

                    if negative {
                        (targetBuckets[targetIdx], cTargetBuckets[targetIdx]) = Kahan.dec(
                            value, targetBuckets[targetIdx], cTargetBuckets[targetIdx])
                    } else {
                        (targetBuckets[targetIdx], cTargetBuckets[targetIdx]) = Kahan.inc(
                            value, targetBuckets[targetIdx], cTargetBuckets[targetIdx])
                        if withCompensation, let bucketsC {
                            (targetBuckets[targetIdx], cTargetBuckets[targetIdx]) = Kahan.inc(
                                bucketsC[bucketIdx], targetBuckets[targetIdx],
                                cTargetBuckets[targetIdx])
                        }
                    }
                }
                srcIdx += 1
                bucketIdx += 1
            }
        }
    }

    // Map both histograms onto the intersected layout.
    mapBuckets(spansA, bucketsA, boundsA, false, true)
    mapBuckets(spansB, bucketsB, boundsB, negative, false)

    // Build spans and buckets, excluding zero-valued buckets from the result.
    var destSpans = [Span]()
    var destBuckets = [Double]()
    var cDestBuckets = [Double]()
    var lastIdx: Int32 = -1

    for i in targetBuckets.indices {
        if targetBuckets[i] == 0 && cTargetBuckets[i] == 0 { continue }

        destBuckets.append(targetBuckets[i])
        cDestBuckets.append(cTargetBuckets[i])
        let idx = Int32(i)

        if !destSpans.isEmpty && idx == lastIdx + 1 {
            // Consecutive bucket: extend the last span.
            destSpans[destSpans.count - 1].length += 1
        } else {
            // A new span is needed. Go leaves small gaps unoptimised here.
            var offset = idx
            if !destSpans.isEmpty {
                // Convert to a relative offset from the end of the last span.
                offset = idx - lastIdx - 1
            }
            destSpans.append(Span(offset: offset, length: 1))
        }
        lastIdx = idx
    }

    return (destSpans, destBuckets, cDestBuckets)
}

// MARK: - Kahan resolution reduction

/// Go: `kahanReduceResolution` — `reduceResolution` for `kahanAdd`, carrying the
/// compensation buckets. Float buckets only.
///
/// Note that unlike `reduceResolution` this validates nothing: it indexes the
/// bucket arrays directly, so inconsistent spans trap rather than throw. Go has
/// the same contract.
func kahanReduceResolution(
    originSpans: [Span],
    originReceivingBuckets: [Double],
    originCompensationBuckets: [Double],
    originSchema: Int32,
    targetSchema: Int32
) -> (newSpans: [Span], newReceivingBuckets: [Double], newCompensationBuckets: [Double]) {
    var targetSpans = [Span]()
    var targetReceivingBuckets = [Double]()
    var targetCompensationBuckets = [Double]()
    var bucketIdx: Int32 = 0
    var bucketCountIdx = 0
    var lastTargetBucketIdx: Int32 = 0

    for span in originSpans {
        bucketIdx += span.offset
        for _ in 0..<Int(span.length) {
            let targetBucketIdx = targetIdx(bucketIdx, originSchema, targetSchema)

            if targetSpans.isEmpty {
                targetSpans.append(Span(offset: targetBucketIdx, length: 1))
                targetReceivingBuckets.append(originReceivingBuckets[bucketCountIdx])
                lastTargetBucketIdx = targetBucketIdx
                targetCompensationBuckets.append(originCompensationBuckets[bucketCountIdx])
            } else if lastTargetBucketIdx == targetBucketIdx {
                // Merges into the same target bucket as the previous one.
                let last = targetReceivingBuckets.count - 1
                (targetReceivingBuckets[last], targetCompensationBuckets[last]) = Kahan.inc(
                    originReceivingBuckets[bucketCountIdx],
                    targetReceivingBuckets[last],
                    targetCompensationBuckets[last])
                (targetReceivingBuckets[last], targetCompensationBuckets[last]) = Kahan.inc(
                    originCompensationBuckets[bucketCountIdx],
                    targetReceivingBuckets[last],
                    targetCompensationBuckets[last])
            } else if lastTargetBucketIdx + 1 == targetBucketIdx {
                // Next target bucket, adjacent: extend the current target span.
                targetSpans[targetSpans.count - 1].length += 1
                lastTargetBucketIdx += 1
                targetReceivingBuckets.append(originReceivingBuckets[bucketCountIdx])
                targetCompensationBuckets.append(originCompensationBuckets[bucketCountIdx])
            } else if lastTargetBucketIdx + 1 < targetBucketIdx {
                // Next target bucket, separated by a gap: start a new span.
                targetSpans.append(
                    Span(offset: targetBucketIdx - lastTargetBucketIdx - 1, length: 1))
                lastTargetBucketIdx = targetBucketIdx
                targetReceivingBuckets.append(originReceivingBuckets[bucketCountIdx])
                targetCompensationBuckets.append(originCompensationBuckets[bucketCountIdx])
            }

            bucketIdx += 1
            bucketCountIdx += 1
        }
    }

    return (targetSpans, targetReceivingBuckets, targetCompensationBuckets)
}
