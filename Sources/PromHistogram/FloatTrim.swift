//===----------------------------------------------------------------------===//
// Ported from model/histogram/float_histogram.go @ v3.13.2 — TrimBuckets and the
// interpolation helpers behind it.
//
// This is what PromQL's `histogram </ float` and `histogram >/ float` operators
// use to keep only the observations below or above a trim point. Buckets wholly
// on the kept side survive intact, the bucket containing the trim point is
// interpolated, and the rest are dropped. Sum is re-estimated from bucket
// midpoints, so every midpoint rule matters.
//
// Interpolation is linear for custom buckets and exponential (geometric mean) for
// exponential ones, and the ±Inf cases are deliberately conservative: an infinite
// bucket has no known distribution, so it is usually dropped whole.
//
// Every `updatedSum` accumulation is a FUSED multiply-add. Go writes
// `updatedSum += bucketMidpoint * count`, which its arm64 backend compiles to
// FMADDD — verified by disassembling TrimBuckets, where all nine of these
// statements fuse and none of the helper functions do. Using an unfused `+=`
// mismatches Go on 574 of the 9,048 committed trim cases. The same applies to
// GoMath.log2's final step, which this file depends on through computeSplit.
//===----------------------------------------------------------------------===//

private import GoCompat

extension FloatHistogram {

    /// Go: `TrimBuckets` — returns a copy holding only the observations on one
    /// side of `rhs`. With `isUpperTrim` true, observations below `rhs` are kept
    /// (PromQL's `</`); with it false, observations above `rhs` are kept (`>/`).
    public func trimBuckets(rhs: Double, isUpperTrim: Bool) -> FloatHistogram {
        var trimmedHist = copy()

        var updatedCount: Double = 0
        var updatedSum: Double = 0
        var trimmedBuckets = false
        let isCustomBucket = trimmedHist.usesCustomBuckets
        var hasPositive = false
        var hasNegative = false

        if isUpperTrim {
            // For TRIM_UPPER, keep the observations below the trim point.
            var i = 0
            var iter = trimmedHist.positiveBucketIterator()
            while iter.next() {
                defer { i += 1 }
                let bucket = iter.at()
                if bucket.count == 0 { continue }
                hasPositive = true

                if bucket.upper <= rhs {
                    // Entirely below the trim point: keep all of it.
                    updatedCount += bucket.count
                    let bucketMidpoint = computeMidpoint(
                        bucket.lower, bucket.upper, true, isCustomBucket)
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, bucket.count)
                } else if bucket.lower < rhs {
                    // Contains the trim point: interpolate.
                    let (keepCount, bucketMidpoint) = computeBucketTrim(
                        bucket, rhs, isUpperTrim, true, isCustomBucket)

                    updatedCount += keepCount
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, keepCount)
                    if trimmedHist.positiveBuckets[i] != keepCount {
                        trimmedHist.positiveBuckets[i] = keepCount
                        trimmedBuckets = true
                    }
                } else {
                    // Entirely above the trim point: discard.
                    trimmedHist.positiveBuckets[i] = 0
                    trimmedBuckets = true
                }
            }

            i = 0
            var negIter = trimmedHist.negativeBucketIterator()
            while negIter.next() {
                defer { i += 1 }
                let bucket = negIter.at()
                if bucket.count == 0 { continue }
                hasNegative = true

                if bucket.upper <= rhs {
                    updatedCount += bucket.count
                    let bucketMidpoint = computeMidpoint(
                        bucket.lower, bucket.upper, false, isCustomBucket)
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, bucket.count)
                } else if bucket.lower < rhs {
                    let (keepCount, bucketMidpoint) = computeBucketTrim(
                        bucket, rhs, isUpperTrim, false, isCustomBucket)

                    updatedCount += keepCount
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, keepCount)
                    if trimmedHist.negativeBuckets[i] != keepCount {
                        trimmedHist.negativeBuckets[i] = keepCount
                        trimmedBuckets = true
                    }
                } else {
                    trimmedHist.negativeBuckets[i] = 0
                    trimmedBuckets = true
                }
            }
        } else {
            // For TRIM_LOWER, keep the observations above the trim point.
            var i = 0
            var iter = trimmedHist.positiveBucketIterator()
            while iter.next() {
                defer { i += 1 }
                let bucket = iter.at()
                if bucket.count == 0 { continue }
                hasPositive = true

                if bucket.lower >= rhs {
                    updatedCount += bucket.count
                    let bucketMidpoint = computeMidpoint(
                        bucket.lower, bucket.upper, true, isCustomBucket)
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, bucket.count)
                } else if bucket.upper > rhs {
                    let (keepCount, bucketMidpoint) = computeBucketTrim(
                        bucket, rhs, isUpperTrim, true, isCustomBucket)

                    updatedCount += keepCount
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, keepCount)
                    if trimmedHist.positiveBuckets[i] != keepCount {
                        trimmedHist.positiveBuckets[i] = keepCount
                        trimmedBuckets = true
                    }
                } else {
                    trimmedHist.positiveBuckets[i] = 0
                    trimmedBuckets = true
                }
            }

            i = 0
            var negIter = trimmedHist.negativeBucketIterator()
            while negIter.next() {
                defer { i += 1 }
                let bucket = negIter.at()
                if bucket.count == 0 { continue }
                hasNegative = true

                if bucket.lower >= rhs {
                    updatedCount += bucket.count
                    let bucketMidpoint = computeMidpoint(
                        bucket.lower, bucket.upper, false, isCustomBucket)
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, bucket.count)
                } else if bucket.upper > rhs {
                    let (keepCount, bucketMidpoint) = computeBucketTrim(
                        bucket, rhs, isUpperTrim, false, isCustomBucket)

                    updatedCount += keepCount
                    updatedSum = updatedSum.addingProduct(bucketMidpoint, keepCount)
                    if trimmedHist.negativeBuckets[i] != keepCount {
                        trimmedHist.negativeBuckets[i] = keepCount
                        trimmedBuckets = true
                    }
                } else {
                    trimmedHist.negativeBuckets[i] = 0
                    trimmedBuckets = true
                }
            }
        }

        // Handle the zero bucket.
        if trimmedHist.zeroCount > 0 {
            let (keepCount, bucketMidpoint) = computeZeroBucketTrim(
                trimmedHist.zeroBucket(), rhs, hasNegative, hasPositive, isUpperTrim)

            if trimmedHist.zeroCount != keepCount {
                trimmedHist.zeroCount = keepCount
                trimmedBuckets = true
            }
            updatedSum = updatedSum.addingProduct(bucketMidpoint, keepCount)
            updatedCount += keepCount
        }

        if trimmedBuckets {
            // Only update the totals if some bucket was fully or partially trimmed.
            trimmedHist.count = updatedCount
            trimmedHist.sum = updatedSum

            trimmedHist.compact(maxEmptyBuckets: 0)
        }

        return trimmedHist
    }
}

/// Go: `handleInfinityBuckets` — the conservative treatment of a bucket with an
/// infinite bound, whose distribution is unknown.
func handleInfinityBuckets(
    _ isUpperTrim: Bool, _ b: Bucket<Double>, _ rhs: Double
) -> (underCount: Double, bucketMidpoint: Double) {
    func zeroIfInf(_ x: Double) -> Double { x.isInfinite ? 0 : x }

    // Case 1: a bucket with a lower bound of -Inf.
    if b.lower == -.infinity {
        if isUpperTrim {
            // TRIM_UPPER: remove values greater than rhs.
            if rhs >= b.upper {
                // rhs is above the upper bound, so the whole bucket is kept.
                return (b.count, 0)
            }
            if rhs > 0 && b.upper > 0 && b.upper != .infinity {
                // A finite positive upper bound, so treat lower as 0 despite it
                // being -Inf. Only possible with NHCB, so linear interpolation.
                return (b.count * rhs / b.upper, rhs / 2)
            }
            if b.upper <= 0 {
                return (b.count, rhs)
            }
            // A valid trim, but the distribution inside an infinite bucket is
            // unknown, so remove the whole bucket.
            return (0, zeroIfInf(b.upper))
        }
        // TRIM_LOWER: remove values less than rhs.
        if rhs <= b.lower {
            // Impossible, since the lower bound is -Inf. Keep the whole bucket.
            return (b.count, 0)
        }
        if rhs >= 0 && b.upper > rhs && b.upper != .infinity {
            // As above: treat lower as 0 and interpolate linearly.
            return (b.count * (1 - rhs / b.upper), (rhs + b.upper) / 2)
        }
        return (0, zeroIfInf(b.upper))
    }

    // Case 2: a bucket with an upper bound of +Inf.
    if b.upper == .infinity {
        if isUpperTrim {
            // TRIM_UPPER. The lower bound does not matter: if rhs >= lower some
            // values in this bucket could exceed rhs, so it goes conservatively;
            // and if rhs < lower everything here is above rhs anyway.
            return (0, zeroIfInf(b.lower))
        }
        // TRIM_LOWER.
        if rhs >= b.lower {
            return (b.count, rhs)
        }
        // Inside the infinity bucket with an unknown distribution: drop it.
        return (0, zeroIfInf(b.lower))
    }

    preconditionFailure(
        "one of the bounds must be infinite for handleInfinityBuckets, got \(b)")
}

/// Go: `computeSplit` — the portion of the bucket's count at or below `rhs`.
func computeSplit(_ b: Bucket<Double>, _ rhs: Double, _ isPositive: Bool, _ isLinear: Bool) -> Double
{
    if rhs <= b.lower { return 0 }
    if rhs >= b.upper { return b.count }

    var fraction: Double
    if isLinear {
        fraction = (rhs - b.lower) / (b.upper - b.lower)
    } else {
        // Exponential interpolation.
        let logLower = GoMath.log2(abs(b.lower))
        let logUpper = GoMath.log2(abs(b.upper))
        let logV = GoMath.log2(abs(rhs))

        if isPositive {
            fraction = (logV - logLower) / (logUpper - logLower)
        } else {
            fraction = 1 - ((logV - logUpper) / (logLower - logUpper))
        }
    }

    return b.count * fraction
}

/// Go: `computeZeroBucketTrim`.
///
/// The zero bucket straddles zero, so which half is meaningful depends on whether
/// the histogram has observations on the other side at all.
func computeZeroBucketTrim(
    _ zeroBucket: Bucket<Double>, _ rhs: Double,
    _ hasNegative: Bool, _ hasPositive: Bool, _ isUpperTrim: Bool
) -> (Double, Double) {
    var lower = zeroBucket.lower
    var upper = zeroBucket.upper
    if hasNegative && !hasPositive {
        upper = 0
    }
    if hasPositive && !hasNegative {
        lower = 0
    }

    var fraction: Double
    var midpoint: Double

    if isUpperTrim {
        if rhs <= lower { return (0, 0) }
        if rhs >= upper { return (zeroBucket.count, (lower + upper) / 2) }

        fraction = (rhs - lower) / (upper - lower)
        midpoint = (lower + rhs) / 2
    } else {
        // Lower trim.
        if rhs <= lower { return (zeroBucket.count, (lower + upper) / 2) }
        if rhs >= upper { return (0, 0) }

        fraction = (upper - rhs) / (upper - lower)
        midpoint = (rhs + upper) / 2
    }

    return (zeroBucket.count * fraction, midpoint)
}

/// Go: `computeBucketTrim` — the kept count and the midpoint of the surviving
/// interval, for the bucket that contains the trim point.
func computeBucketTrim(
    _ b: Bucket<Double>, _ rhs: Double,
    _ isUpperTrim: Bool, _ isPositive: Bool, _ isCustomBucket: Bool
) -> (Double, Double) {
    if b.lower == -.infinity || b.upper == .infinity {
        return handleInfinityBuckets(isUpperTrim, b, rhs)
    }

    let underCount = computeSplit(b, rhs, isPositive, isCustomBucket)

    if isUpperTrim {
        return (underCount, computeMidpoint(b.lower, rhs, isPositive, isCustomBucket))
    }

    return (b.count - underCount, computeMidpoint(rhs, b.upper, isPositive, isCustomBucket))
}

/// Go: `computeMidpoint` — the representative value of the surviving interval:
/// the arithmetic mean for custom buckets, the geometric mean for exponential
/// ones.
func computeMidpoint(
    _ survivingIntervalLowerBound: Double, _ survivingIntervalUpperBound: Double,
    _ isPositive: Bool, _ isLinear: Bool
) -> Double {
    if survivingIntervalLowerBound.isInfinite {
        if survivingIntervalUpperBound.isInfinite {
            return 0
        }
        if survivingIntervalUpperBound > 0 {
            return survivingIntervalUpperBound / 2
        }
        return survivingIntervalUpperBound
    } else if survivingIntervalUpperBound.isInfinite {
        return survivingIntervalLowerBound
    }

    if isLinear {
        return (survivingIntervalLowerBound + survivingIntervalUpperBound) / 2
    }

    let geoMean = (abs(survivingIntervalLowerBound * survivingIntervalUpperBound)).squareRoot()

    if isPositive {
        return geoMean
    }
    return -geoMean
}
