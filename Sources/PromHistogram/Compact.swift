//===----------------------------------------------------------------------===//
// Ported from model/histogram/generic.go @ v3.13.2 — compactBuckets and
// reduceResolution.
//
// Both are generic over the internal bucket representation and take a
// `deltaBuckets` flag, exactly as Go does: `Histogram` stores deltas between
// buckets while `FloatHistogram` stores absolute counts, and Go passes that
// distinction as a boolean rather than specialising. See ADR-7.
//===----------------------------------------------------------------------===//

/// Go: `compactBuckets`.
///
/// `compensationBuckets` carries Kahan compensation values for float histograms
/// and is processed in lock-step with `primaryBuckets`; it must be nil when
/// `deltaBuckets` is true.
func compactBuckets<IBC: InternalBucketCountValue>(
    primaryBuckets primaryIn: [IBC],
    compensationBuckets compensationIn: [Double]?,
    spans spansIn: [Span],
    maxEmptyBuckets: Int,
    deltaBuckets: Bool
) -> (primary: [IBC], compensation: [Double]?, spans: [Span]) {
    var primaryBuckets = primaryIn
    var compensationBuckets = compensationIn
    var spans = spansIn

    if deltaBuckets && compensationBuckets != nil {
        preconditionFailure(
            "histogram type mismatch: deltaBuckets cannot be true when compensationBuckets is provided"
        )
    }
    if let comp = compensationBuckets, primaryBuckets.count != comp.count {
        preconditionFailure(
            "primary buckets layout mismatch against associated compensation buckets layout")
    }

    // Fast path: nothing to do when no bucket is empty, no span offset is small
    // enough to merge, and no span has length 0. Checked first because it is cheap
    // and presumably common.
    var nothingToDo = true
    var currentBucketAbsolute = IBC.zero
    for bucket in primaryBuckets {
        if deltaBuckets {
            currentBucketAbsolute += bucket
        } else {
            currentBucketAbsolute = bucket
        }
        if currentBucketAbsolute == IBC.zero {
            nothingToDo = false
            break
        }
    }
    if nothingToDo {
        for span in spans where Int(span.offset) <= maxEmptyBuckets || span.length == 0 {
            nothingToDo = false
            break
        }
        if nothingToDo {
            return (primaryBuckets, compensationBuckets, spans)
        }
    }

    var iBucket = 0
    var iSpan = 0
    var posInSpan: UInt32 = 0
    currentBucketAbsolute = IBC.zero

    func emptyBucketsHere() -> Int {
        var i = 0
        var abs = currentBucketAbsolute
        var comp: Double = 0
        if let c = compensationBuckets { comp = c[iBucket] }
        while UInt32(i) + posInSpan < spans[iSpan].length && abs == IBC.zero && comp == 0 {
            i += 1
            if i + iBucket >= primaryBuckets.count { break }
            abs = primaryBuckets[i + iBucket]
            if let c = compensationBuckets { comp = c[i + iBucket] }
        }
        return i
    }

    // Merge zero-offset spans so later logic has fewer special cases.
    //
    // Both of these loops mutate `spans` while walking it, and Go's `range` reads
    // each element out of the slice at the top of its iteration — so an element
    // an earlier iteration wrote is seen in its updated form. Iterating with
    // `enumerated()` would snapshot the array instead and silently compact a
    // different histogram, so the index is explicit.
    if spans.count > 1 {
        for i in 0..<(spans.count - 1) {
            let span = spans[i + 1]
            if span.offset == 0 {
                spans[iSpan].length += span.length
                continue
            }
            iSpan += 1
            if i + 1 != iSpan { spans[iSpan] = span }
        }
        spans = Array(spans[0...iSpan])
        iSpan = 0
    }

    // Merge zero-length spans likewise.
    for i in 0..<spans.count {
        let span = spans[i]
        if span.length == 0 {
            if i + 1 < spans.count { spans[i + 1].offset += span.offset }
            continue
        }
        if i != iSpan { spans[iSpan] = span }
        iSpan += 1
    }
    spans = Array(spans[0..<iSpan])
    iSpan = 0

    // If every span was zero-length, no buckets remain valid.
    if spans.isEmpty {
        if compensationBuckets != nil { compensationBuckets = [] }
        return ([], compensationBuckets, spans)
    }

    // Cut empty buckets from the start and end of spans unconditionally, and from
    // the middle only when there are more than maxEmptyBuckets in a row.
    while iBucket < primaryBuckets.count && iSpan < spans.count {
        if deltaBuckets {
            currentBucketAbsolute += primaryBuckets[iBucket]
        } else {
            currentBucketAbsolute = primaryBuckets[iBucket]
        }
        let nEmpty = emptyBucketsHere()
        if nEmpty > 0 {
            if posInSpan > 0, nEmpty < Int(spans[iSpan].length - posInSpan),
                nEmpty <= maxEmptyBuckets
            {
                // Few enough empties mid-span to leave alone; fast-forward.
                iBucket += nEmpty
                if deltaBuckets { currentBucketAbsolute = IBC.zero }
                posInSpan += UInt32(nEmpty)
                continue
            }
            // Otherwise cut them out.
            if deltaBuckets && iBucket + nEmpty < primaryBuckets.count {
                currentBucketAbsolute = -primaryBuckets[iBucket]
                primaryBuckets[iBucket + nEmpty] += primaryBuckets[iBucket]
            }
            primaryBuckets.removeSubrange(iBucket..<(iBucket + nEmpty))
            if compensationBuckets != nil {
                compensationBuckets!.removeSubrange(iBucket..<(iBucket + nEmpty))
            }
            if posInSpan == 0 {
                // Start of a span.
                if nEmpty == Int(spans[iSpan].length) {
                    // The whole span is empty.
                    let offset = spans[iSpan].offset
                    spans.remove(at: iSpan)
                    if spans.count > iSpan {
                        spans[iSpan].offset += offset + Int32(nEmpty)
                    }
                    continue
                }
                spans[iSpan].length -= UInt32(nEmpty)
                spans[iSpan].offset += Int32(nEmpty)
                continue
            }
            // Middle or end of the span: split it.
            let newSpan = Span(
                offset: Int32(nEmpty),
                length: spans[iSpan].length - posInSpan - UInt32(nEmpty))
            spans[iSpan].length = posInSpan
            iSpan += 1
            posInSpan = 0
            if newSpan.length == 0 {
                // We were already at the end of a span; just fix the next offset.
                if iSpan < spans.count { spans[iSpan].offset += Int32(nEmpty) }
                continue
            }
            spans.insert(newSpan, at: iSpan)
            continue
        }
        iBucket += 1
        posInSpan += 1
        if posInSpan >= spans[iSpan].length {
            posInSpan = 0
            iSpan += 1
        }
    }
    if maxEmptyBuckets == 0 || primaryBuckets.isEmpty {
        return (primaryBuckets, compensationBuckets, spans)
    }

    // Finally, merge spans whose separating offset is small enough.
    iBucket = Int(spans[0].length)
    if deltaBuckets {
        currentBucketAbsolute = IBC.zero
        for bucket in primaryBuckets[0..<iBucket] { currentBucketAbsolute += bucket }
    }
    iSpan = 1
    while iSpan < spans.count {
        if Int(spans[iSpan].offset) > maxEmptyBuckets {
            let l = Int(spans[iSpan].length)
            if deltaBuckets {
                for bucket in primaryBuckets[iBucket..<(iBucket + l)] {
                    currentBucketAbsolute += bucket
                }
            }
            iBucket += l
            iSpan += 1
            continue
        }
        // Merge with the previous span, inserting the empty buckets explicitly.
        let offset = Int(spans[iSpan].offset)
        spans[iSpan - 1].length += UInt32(offset) + spans[iSpan].length
        spans.remove(at: iSpan)
        var newPrimary = [IBC](repeating: IBC.zero, count: primaryBuckets.count + offset)
        for i in 0..<iBucket { newPrimary[i] = primaryBuckets[i] }
        for i in iBucket..<primaryBuckets.count { newPrimary[i + offset] = primaryBuckets[i] }
        if deltaBuckets {
            newPrimary[iBucket] = -currentBucketAbsolute
            newPrimary[iBucket + offset] += currentBucketAbsolute
        }
        primaryBuckets = newPrimary
        if let comp = compensationBuckets {
            var newComp = [Double](repeating: 0, count: comp.count + offset)
            for i in 0..<iBucket { newComp[i] = comp[i] }
            for i in iBucket..<comp.count { newComp[i + offset] = comp[i] }
            compensationBuckets = newComp
        }
        iBucket += offset
        currentBucketAbsolute = primaryBuckets[iBucket]
    }

    return (primaryBuckets, compensationBuckets, spans)
}

/// Go: `reduceResolution`.
///
/// The `inplace` parameter Go takes is a slice-reuse optimisation only; Swift
/// arrays are value types, so it is dropped.
func reduceResolution<IBC: InternalBucketCountValue>(
    originSpans: [Span],
    originBuckets: [IBC],
    originSchema: Int32,
    targetSchema: Int32,
    deltaBuckets: Bool
) throws -> (spans: [Span], buckets: [IBC]) {
    var targetSpans = [Span]()
    var targetBuckets = [IBC]()
    var bucketIdx: Int32 = 0
    var bucketCountIdx = 0
    var lastBucketCount = IBC.zero
    var lastTargetBucketIdx: Int32 = 0
    var lastTargetBucketCount = IBC.zero

    for (n, span) in originSpans.enumerated() {
        if n > 0 && span.offset < 0 {
            throw HistogramError.spanNegativeOffset(span: n + 1, offset: span.offset)
        }
        bucketIdx += span.offset
        for _ in 0..<Int(span.length) {
            guard bucketCountIdx < originBuckets.count else {
                // generic.go:817 — this mid-span exhaustion reports the count it
                // HAS, not the count it needs; the message differs from the
                // spans/buckets mismatch reported after the loop.
                throw HistogramError.spansNeedMoreBuckets(have: originBuckets.count)
            }
            let targetBucketIdx = targetIdx(bucketIdx, originSchema, targetSchema)

            if targetSpans.isEmpty {
                targetSpans.append(Span(offset: targetBucketIdx, length: 1))
                targetBuckets.append(originBuckets[bucketCountIdx])
                lastTargetBucketIdx = targetBucketIdx
                lastBucketCount = originBuckets[bucketCountIdx]
                lastTargetBucketCount = originBuckets[bucketCountIdx]
            } else if lastTargetBucketIdx == targetBucketIdx {
                // Merges into the same target bucket as the previous one.
                if deltaBuckets {
                    lastBucketCount += originBuckets[bucketCountIdx]
                    targetBuckets[targetBuckets.count - 1] += lastBucketCount
                    lastTargetBucketCount += lastBucketCount
                } else {
                    targetBuckets[targetBuckets.count - 1] += originBuckets[bucketCountIdx]
                }
            } else if lastTargetBucketIdx + 1 == targetBucketIdx {
                // Next target bucket, adjacent: extend the current target span.
                targetSpans[targetSpans.count - 1].length += 1
                lastTargetBucketIdx += 1
                if deltaBuckets {
                    lastBucketCount += originBuckets[bucketCountIdx]
                    targetBuckets.append(lastBucketCount - lastTargetBucketCount)
                    lastTargetBucketCount = lastBucketCount
                } else {
                    targetBuckets.append(originBuckets[bucketCountIdx])
                }
            } else if lastTargetBucketIdx + 1 < targetBucketIdx {
                // Next target bucket, separated by a gap: start a new span.
                targetSpans.append(
                    Span(offset: targetBucketIdx - lastTargetBucketIdx - 1, length: 1))
                lastTargetBucketIdx = targetBucketIdx
                if deltaBuckets {
                    lastBucketCount += originBuckets[bucketCountIdx]
                    targetBuckets.append(lastBucketCount - lastTargetBucketCount)
                    lastTargetBucketCount = lastBucketCount
                } else {
                    targetBuckets.append(originBuckets[bucketCountIdx])
                }
            }
            bucketIdx += 1
            bucketCountIdx += 1
        }
    }
    if bucketCountIdx != originBuckets.count {
        throw HistogramError.spansBucketsMismatch(
            need: bucketCountIdx, have: originBuckets.count)
    }
    return (targetSpans, targetBuckets)
}
