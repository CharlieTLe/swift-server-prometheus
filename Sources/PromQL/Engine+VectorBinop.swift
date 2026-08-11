//===----------------------------------------------------------------------===//
// Ported from promql/engine.go @ v3.13.2 — the vector binary operators: `VectorAnd` (:3234),
// `VectorOr` (:3260), `VectorUnless` (:3288), `VectorBinop` (:3162), `resultMetric` (:3331),
// `VectorscalarBinop` (:3375), `vectorElemBinop` (:3452), `changesMetricSchema` (:4407),
// `handleVectorBinopError`, and the four vector arms of `eval`'s `BinaryExpr` case.
//
// ## Signature ORDINALS, not signature strings
//
// The join key is a byte string — `BytesWithLabels` under `on`, `BytesWithoutLabels` under
// `ignoring` with `__name__` prepended — but it is only ever used to assign each series a small
// integer, `EvalSeriesHelper.sigOrdinal`. `rangeEval` does that **once**, before the step loop,
// across *both* sides at once; every per-step lookup is then array indexing.
//
// That is why `EvalNodeHelper` has four `reset*` helpers rather than four maps, and why
// `numSigs` has to be computed before any of them is sized. It also means two series on
// opposite sides with the same join key share an ordinal, which is the whole mechanism.
//
// Note `sigf`'s `ignoring` branch prepends `labels.MetricName` to the exclusion list itself.
// That is not redundant: `BytesWithoutLabels` — unlike `HashWithoutLabels` — does **not** drop
// `__name__` of its own accord.
//
// ## Cardinality is implemented by SWAPPING, and the swap is undone twice
//
// `VectorBinop` handles one-to-one and many-to-one. For `group_right` (one-to-many) it swaps
// `lhs`/`rhs` *and* their helper arrays at the top, so the rest of the function can always treat
// the right as the "one" side. `doBinOp` then swaps the **values** back before computing, so the
// arithmetic still sees the operands in written order. Two swaps, in different places, for
// different reasons — dropping either one produces a plausible wrong answer rather than a crash.
//
// The `oneSide` string in the duplicate-series error is decided by the *original* cardinality,
// so it says "left" for `group_right`. That reads backwards and is correct: with `group_right`
// the left side is the "one".
//
// ## Three different duplicate errors, for three different situations
//
//   * **many-to-many on the "one" side** — two right-hand samples with the same join signature.
//     Reported while building `rightSigs`, with both metrics and the matched labels.
//   * **one-to-one, two lefts matching one right** — `matchedSigsPresent[sigOrd]` already set.
//     "many-to-one matching must be explicit (group_left/group_right)".
//   * **many-to-one, two results with the same label set** — `matchedSigs[sigOrd]` already holds
//     this result's hash. "grouping labels must ensure unique matches". Note the key is the
//     *result* metric, not the input: several lefts sharing a right is legal, and only a
//     collision after `resultMetric` has dropped and included labels is not.
//
// The third check runs **before** the `!keep && !returnBool` filter, so a comparison that
// filters everything out can still fail for duplicate matches. That ordering is observable.
//
// ## `resultMetric`'s cache is keyed on the two INPUT label sets
//
// `lhs.Bytes() ++ rhs.Bytes()`, so it is shared across steps for a stable pair. The metadata
// drop happens when `dropMetricName || changesMetricSchema(op)`, and `changesMetricSchema` is
// true for the seven *arithmetic* operators and false for the comparisons — so `a + b` loses
// `__name__` while `a > b` keeps it. `returnBool` then drops it for comparisons too, which is
// what `dropMetricName` carries in.
//
// `Include` (the `group_x(...)` label list) is taken from the **"one"** side, and a label that is
// empty there is *deleted* rather than left alone.
//
// ## `VectorscalarBinop` keeps the VECTOR's value, even when the scalar is on the left
//
// For a comparison with `swap` — `1 < foo` — the result value is forced back to the vector
// element's. Without that, `1 < foo` would report 1 for every match. `keep` is then forced true
// under `returnBool`, so a `bool` comparison emits an output for every element rather than
// filtering.
//
// It also **ignores warnings**: `if err != nil && !errors.Is(err, annotations.PromQLWarning)`
// skips the element, so a warning-shaped error still produces output where an info-shaped one
// does not. `vectorElemBinop`'s incompatible-types results are infos, so a float-histogram
// scalar operation drops the element silently. That asymmetry is upstream's.
//
// ## `vectorElemBinop`'s four quadrants, and what each allows
//
//   * float ⊕ float — everything, except `trim_lower`/`trim_upper` (an info).
//   * float ⊕ histogram — only `*`, and only that way round because scaling is commutative.
//   * histogram ⊕ float — `*`, `/`, and the two `trim_*`s. No `+`/`-`: adding a scalar to a
//     histogram has no meaning.
//   * histogram ⊕ histogram — `+`, `-`, `==`, `!=`. `-` forces `GaugeType` on the result;
//     `==`/`!=` "expect that both histograms are compacted" and return `hlhs` as the value.
//
// Every rejected combination returns an **info**, not an error, so the query succeeds with an
// annotation and the element vanishes. `handleVectorBinopError` sorts the three cases: an
// info/warning becomes an annotation as-is, an incompatible-schema error becomes a *different*
// warning naming the operator, and anything else is swallowed entirely.
//
// ## Deliberately not here
//
//   * **`FillValues`** (`fill`, `fill_left`, `fill_right`) — the parser accepts them behind
//     `EnableBinopFillModifiers` and `VectorBinop` reads them, but they are a v3.13 addition with
//     their own semantics for unmatched groups; ported with their own corpus rather than folded
//     in here. A query using them throws by name.
//
// ## 34 negative controls, 29 break, and all five survivors are PROOFS
//
// `Scripts/controls-vectorbinop.sh` re-runs them. None of the five is a corpus gap:
//
//   * **`VectorAnd`'s `rhs.isEmpty` short-circuit is redundant.** With an empty right side no
//     ordinal is marked present, so the left loop emits nothing — which is what the
//     short-circuit returns. Same for `VectorBinop`'s combined empty-side test: with no fill
//     values, an empty right leaves `rightSigs` empty and every left is skipped.
//   * **`resultMetric`'s cache key could be the left label set alone.** Within one node each
//     left pairs with exactly one right — two rights for one left is many-to-many, which is an
//     error — and the pairing is by signature ordinal, so it is stable across steps. Concatenating
//     both is upstream's, and it is what makes the cache obviously correct rather than correct by
//     an argument about cardinality.
//   * **`bytesWithLabels`' trailing separator is redundant for well-formed labels.** Without it
//     the encoding is `n1 SEP v1 n2 SEP v2`, and the segment between two separators is `v1 n2`.
//     A different split would need either an empty value or an empty name, and `Labels` admits
//     neither. Kept because Go has it, and because the argument depends on an invariant of
//     `Labels` rather than on anything local.
//   * **`VectorscalarBinop`'s `!errors.Is(err, PromQLWarning)` can never be false.** The only
//     *warning* `vectorElemBinop` produces is the histogram⊕histogram counter-reset collision,
//     and a vector/scalar operation always has a nil right-hand histogram. Every error reachable
//     on this path is an info, so the guard is a no-op — and it is precisely the kind of guard
//     that would start mattering if a future operator gained a warning, so it stays.
//===----------------------------------------------------------------------===//

internal import GoCompat
internal import PromAnnotations
internal import PromHistogram
internal import PromLabels
internal import PromModel
internal import PromPosRange
internal import PromQLParser
internal import PromSchema

// MARK: - The set operators

extension Evaluator {
    /// Go: `VectorAnd` — the left-hand samples whose signature also appears on the right.
    ///
    /// Short-circuits on either side being empty, which matters because the result is the left's
    /// samples unchanged: no `resultMetric`, no label surgery, no `DropName`.
    func vectorAnd(
        _ lhs: Vector, _ rhs: Vector, _ matching: VectorMatching,
        _ lhsh: [EvalSeriesHelper], _ rhsh: [EvalSeriesHelper], _ enh: EvalNodeHelper
    ) throws -> Vector {
        guard matching.card == .manyToMany else {
            throw EvaluationError.setOperatorCardinality
        }
        if lhs.isEmpty || rhs.isEmpty {
            return Vector()
        }
        var present = enh.resetSigsPresent()
        for sh in rhsh {
            present[sh.sigOrdinal] = true
        }
        var out = enh.out
        for (i, ls) in lhs.samples.enumerated() where present[lhsh[i].sigOrdinal] {
            out.append(ls)
        }
        return out
    }

    /// Go: `VectorOr` — the left-hand samples, plus the right-hand ones whose signature the left
    /// did not have.
    ///
    /// The two empty short-circuits are *not* symmetric with `VectorAnd`'s: they return the other
    /// side rather than nothing.
    func vectorOr(
        _ lhs: Vector, _ rhs: Vector, _ matching: VectorMatching,
        _ lhsh: [EvalSeriesHelper], _ rhsh: [EvalSeriesHelper], _ enh: EvalNodeHelper
    ) throws -> Vector {
        guard matching.card == .manyToMany else {
            throw EvaluationError.setOperatorCardinality
        }
        var out = enh.out
        if lhs.isEmpty {
            out.samples.append(contentsOf: rhs.samples)
            return out
        }
        if rhs.isEmpty {
            out.samples.append(contentsOf: lhs.samples)
            return out
        }
        var present = enh.resetSigsPresent()
        for (i, ls) in lhs.samples.enumerated() {
            present[lhsh[i].sigOrdinal] = true
            out.append(ls)
        }
        for (j, rs) in rhs.samples.enumerated() where !present[rhsh[j].sigOrdinal] {
            out.append(rs)
        }
        return out
    }

    /// Go: `VectorUnless` — the left-hand samples whose signature does *not* appear on the right.
    func vectorUnless(
        _ lhs: Vector, _ rhs: Vector, _ matching: VectorMatching,
        _ lhsh: [EvalSeriesHelper], _ rhsh: [EvalSeriesHelper], _ enh: EvalNodeHelper
    ) throws -> Vector {
        guard matching.card == .manyToMany else {
            throw EvaluationError.setOperatorCardinality
        }
        // Neither side empty is a short-circuit here: an empty right means EVERY left survives,
        // and an empty left means nothing does. Both fall out of the loop, and Go only
        // short-circuits the second.
        if lhs.isEmpty {
            return Vector()
        }
        var present = enh.resetSigsPresent()
        for sh in rhsh {
            present[sh.sigOrdinal] = true
        }
        var out = enh.out
        for (i, ls) in lhs.samples.enumerated() where !present[lhsh[i].sigOrdinal] {
            out.append(ls)
        }
        return out
    }
}

// MARK: - The arithmetic and comparison operators

extension Evaluator {
    /// Go: `VectorBinop` — everything except the set operators.
    ///
    /// Returns the output vector and the *last* error or info any element produced;
    /// `handleVectorBinopError` turns that into annotations. "Last" is deliberate — Go keeps
    /// overwriting `lastErr` — so with several failing elements only one annotation survives.
    func vectorBinop(
        _ op: ItemType, _ lhsIn: Vector, _ rhsIn: Vector, _ matching: VectorMatching,
        _ returnBool: Bool, _ lhshIn: [EvalSeriesHelper], _ rhshIn: [EvalSeriesHelper],
        _ enh: EvalNodeHelper, _ pos: PositionRange
    ) throws -> (Vector, (any Error)?) {
        guard matching.card != .manyToMany else {
            throw EvaluationError.manyToManyOnlyForSetOperators
        }
        // Short-circuit: with both sides empty, or one side empty and no fill value, nothing
        // can match.
        if (lhsIn.isEmpty && rhsIn.isEmpty)
            || ((lhsIn.isEmpty || rhsIn.isEmpty) && matching.fillValues.rhs == nil
                && matching.fillValues.lhs == nil)
        {
            return (Vector(), nil)
        }

        // One-to-many becomes many-to-one by swapping sides; `doBinOp` swaps the values back.
        var lhs = lhsIn
        var rhs = rhsIn
        var lhsh = lhshIn
        var rhsh = rhshIn
        if matching.card == .oneToMany {
            swap(&lhs, &rhs)
            swap(&lhsh, &rhsh)
        }

        var rightSigs = enh.resetRightSigs()
        var rightSigsPresent = enh.resetSigsPresent()

        for (i, rs) in rhs.samples.enumerated() {
            let sigOrd = rhsh[i].sigOrdinal
            // The right side is the "one" side by construction, so a repeat here means the user
            // asked for many-to-many without saying so.
            if rightSigsPresent[sigOrd] {
                let dupl = rightSigs[sigOrd]
                // "left" for group_right, because the swap above moved the "one" side.
                let oneSide = matching.card == .oneToMany ? "left" : "right"
                let matchedLabels = rs.metric.matchLabels(
                    on: matching.on, matching.matchingLabels)
                throw EvaluationError.duplicateSeriesForMatchGroup(
                    matchedLabels: matchedLabels.description, oneSide: oneSide,
                    a: rs.metric.description, b: dupl.metric.description)
            }
            rightSigs[sigOrd] = rs
            rightSigsPresent[sigOrd] = true
        }

        // One-to-one needs a flag per ordinal; many-to-one needs the set of RESULT hashes,
        // because several lefts legitimately share one right.
        var matchedSigsPresent: [Bool] = []
        var matchedSigs: [Set<UInt64>?] = []
        if matching.card == .oneToOne {
            matchedSigsPresent = enh.resetMatchedSigsPresent()
        } else {
            matchedSigs = enh.resetMatchedSigs()
        }

        var lastErr: (any Error)? = nil
        var out = enh.out

        func doBinOp(_ ls: Sample, _ rs: Sample, _ sigOrd: Int) throws {
            // Undo the cardinality swap for the VALUES, so the arithmetic sees written order.
            var fl = ls.f
            var fr = rs.f
            var hl = ls.h
            var hr = rs.h
            if matching.card == .oneToMany {
                swap(&fl, &fr)
                swap(&hl, &hr)
            }
            let (fv, hv, keep, info, err) = vectorElemBinop(op, fl, fr, hl, hr, pos)
            if let err {
                lastErr = err
                return
            }
            var floatValue = fv
            var histogramValue = hv
            if let info {
                lastErr = info
            }
            if returnBool {
                histogramValue = nil
                floatValue = keep ? 1.0 : 0.0
            }

            let dropMetricName = !enableDelayedNameRemoval && returnBool
            let metric = resultMetric(ls.metric, rs.metric, op, matching, dropMetricName, enh)

            if matching.card == .oneToOne {
                if matchedSigsPresent[sigOrd] {
                    throw EvaluationError.multipleMatchesNeedExplicitGrouping
                }
                matchedSigsPresent[sigOrd] = true
            } else {
                // The RESULT's hash, not the input's: sharing a right-hand match is legal and
                // only a repeated output label set is not.
                let insertSig = metric.goHash()
                if matchedSigs[sigOrd] == nil {
                    matchedSigs[sigOrd] = []
                }
                if matchedSigs[sigOrd]!.contains(insertSig) {
                    throw EvaluationError.groupingLabelsMustEnsureUniqueMatches
                }
                matchedSigs[sigOrd]!.insert(insertSig)
            }

            // AFTER the duplicate checks: a comparison that filters everything can still fail
            // for duplicate matches.
            if !keep && !returnBool {
                return
            }

            out.append(
                Sample(f: floatValue, h: histogramValue, metric: metric, dropName: returnBool))
        }

        for (i, ls) in lhs.samples.enumerated() {
            let sigOrd = lhsh[i].sigOrdinal
            let rs: Sample
            if rightSigsPresent[sigOrd] {
                rs = rightSigs[sigOrd]
            } else {
                // No match: fall back to the fill value, if there is one. The synthesised sample's
                // metric is the JOIN LABELS ONLY — not the other side's full label set.
                guard let fill = matching.fillValues.rhs else {
                    continue
                }
                rs = Sample(
                    f: fill, metric: ls.metric.matchLabels(on: matching.on, matching.matchingLabels)
                )
            }
            try doBinOp(ls, rs, sigOrd)
        }

        // The right-hand groups the LEFT never had, filled from the left. Runs after the main
        // loop, and skips any ordinal already matched — so it only fires for genuine misses.
        if let fill = matching.fillValues.lhs {
            for (i, rs) in rhs.samples.enumerated() {
                let sigOrd = rhsh[i].sigOrdinal
                if (matching.card == .oneToOne && matchedSigsPresent[sigOrd])
                    || (matching.card != .oneToOne && !(matchedSigs[sigOrd]?.isEmpty ?? true))
                {
                    continue
                }
                let ls = Sample(
                    f: fill, metric: rs.metric.matchLabels(on: matching.on, matching.matchingLabels)
                )
                try doBinOp(ls, rs, sigOrd)
            }
        }

        return (out, lastErr)
    }

    /// Go: `resultMetric` — the output label set for one matched pair.
    ///
    /// Cached on the concatenation of the two inputs' encoded bytes, which is stable across steps
    /// for a stable pair.
    func resultMetric(
        _ lhs: Labels, _ rhs: Labels, _ op: ItemType, _ matching: VectorMatching,
        _ dropMetricName: Bool, _ enh: EvalNodeHelper
    ) -> Labels {
        var key = lhs.goEncodedBytes()
        key.append(contentsOf: rhs.goEncodedBytes())
        if let cached = enh.resultMetricCache[key] {
            return cached
        }

        enh.resetBuilder(lhs)
        if dropMetricName || changesMetricSchema(op) {
            // An empty Metadata DELETES the three schema labels rather than setting them.
            Metadata().setToLabels(&enh.lb)
        }

        // Only one-to-one strips the join labels. Many-to-one keeps the "many" side's labels,
        // which is the point of `group_left`/`group_right`.
        if matching.card == .oneToOne {
            if matching.on {
                enh.lb.keep(matching.matchingLabels)
            } else {
                enh.lb.del(matching.matchingLabels)
            }
        }
        for ln in matching.include {
            // From the "one" side, and an empty value DELETES rather than leaving the label.
            let v = rhs[ln]
            if !v.isEmpty {
                enh.lb.set(ln, v)
            } else {
                enh.lb.del([ln])
            }
        }

        let ret = enh.lb.labels()
        enh.resultMetricCache[key] = ret
        return ret
    }

    /// Go: `VectorscalarBinop` — a vector against a scalar, either way round.
    ///
    /// `swap` says the scalar was written on the left. Three things depend on it and only two are
    /// obvious: the operand order for the arithmetic, the *result value* for a comparison (which
    /// is forced back to the vector element's), and nothing else — the metric always comes from
    /// the vector.
    func vectorScalarBinop(
        _ op: ItemType, _ lhs: Vector, _ rhs: Scalar, _ swapSides: Bool, _ returnBool: Bool,
        _ enh: EvalNodeHelper, _ pos: PositionRange
    ) -> (Vector, (any Error)?) {
        var lastErr: (any Error)? = nil
        var out = enh.out
        for var lhsSample in lhs.samples {
            var lf = lhsSample.f
            var rf = rhs.v
            var lh = lhsSample.h
            var rh: FloatHistogram? = nil
            if swapSides {
                swap(&lf, &rf)
                swap(&lh, &rh)
            }
            let (fv, hv, keepIn, _, err) = vectorElemBinop(op, lf, rf, lh, rh, pos)
            // A WARNING does not skip the element; an info-shaped error does. Upstream's
            // asymmetry, and `vectorElemBinop`'s incompatible-type results are infos — so a
            // float-histogram scalar operation drops the element silently.
            // `!errors.Is(err, PromQLWarning)`: a warning-kinded annotation does NOT skip the
            // element, an info-kinded one does. Upstream's asymmetry.
            if let err, (err as? any AnnotationError)?.kind != .warning {
                lastErr = err
                continue
            }
            var float = fv
            var histogram = hv
            var keep = keepIn
            // A scalar on the LEFT of a comparison still reports the VECTOR's value.
            if op.isComparisonOperator && swapSides {
                float = rf
                histogram = rh
            }
            if returnBool {
                float = keep ? 1.0 : 0.0
                keep = true
            }
            if keep {
                lhsSample.f = float
                lhsSample.h = histogram
                if changesMetricSchema(op) || returnBool {
                    if !enableDelayedNameRemoval {
                        lhsSample.metric = lhsSample.metric.dropReserved(isMetadataLabel)
                    }
                    lhsSample.dropName = true
                }
                out.append(lhsSample)
            }
        }
        return (out, lastErr)
    }
}

/// Go: `vectorElemBinop` — one operator applied to one pair of elements.
///
/// Returns `(float, histogram, keep, info, err)`. `keep` false with no error is a *comparison
/// that did not match*, which is how comparisons filter. Every disallowed type combination
/// returns an **info** rather than an error, so the query succeeds with an annotation.
func vectorElemBinop(
    _ op: ItemType, _ lhs: Double, _ rhs: Double, _ hlhs: FloatHistogram?,
    _ hrhs: FloatHistogram?, _ pos: PositionRange
) -> (Double, FloatHistogram?, Bool, (any Error)?, (any Error)?) {
    switch (hlhs, hrhs) {
    case (nil, nil):
        switch op {
        case .add: return (lhs + rhs, nil, true, nil, nil)
        case .sub: return (lhs - rhs, nil, true, nil, nil)
        case .mul: return (lhs * rhs, nil, true, nil, nil)
        case .div: return (lhs / rhs, nil, true, nil, nil)
        case .pow: return (GoMath.pow(lhs, rhs), nil, true, nil, nil)
        case .mod: return (GoMath.mod(lhs, rhs), nil, true, nil, nil)
        // The comparisons return the LEFT value and use `keep` to filter.
        case .eqlc: return (lhs, nil, lhs == rhs, nil, nil)
        case .neq: return (lhs, nil, lhs != rhs, nil, nil)
        case .gtr: return (lhs, nil, lhs > rhs, nil, nil)
        case .lss: return (lhs, nil, lhs < rhs, nil, nil)
        case .gte: return (lhs, nil, lhs >= rhs, nil, nil)
        case .lte: return (lhs, nil, lhs <= rhs, nil, nil)
        case .atan2: return (GoMath.atan2(lhs, rhs), nil, true, nil, nil)
        case .trimLower, .trimUpper:
            return (
                0, nil, false, nil,
                newIncompatibleTypesInBinOpInfo("float", (itemTypeStr[op] ?? op.description), "float", pos)
            )
        default: break
        }
    case (nil, .some(let h)):
        // Only scaling, and only this way round.
        if op == .mul {
            var r = h.copy()
            _ = r.mul(lhs)
            return (0, r.compact(maxEmptyBuckets: 0), true, nil, nil)
        }
        return (
            0, nil, false, nil,
            newIncompatibleTypesInBinOpInfo("float", (itemTypeStr[op] ?? op.description), "histogram", pos)
        )
    case (.some(let h), nil):
        switch op {
        case .mul:
            var r = h.copy()
            _ = r.mul(rhs)
            return (0, r.compact(maxEmptyBuckets: 0), true, nil, nil)
        case .div:
            var r = h.copy()
            _ = r.div(rhs)
            return (0, r.compact(maxEmptyBuckets: 0), true, nil, nil)
        case .trimUpper:
            return (0, h.trimBuckets(rhs: rhs, isUpperTrim: true), true, nil, nil)
        case .trimLower:
            return (0, h.trimBuckets(rhs: rhs, isUpperTrim: false), true, nil, nil)
        default:
            return (
                0, nil, false, nil,
                newIncompatibleTypesInBinOpInfo("histogram", (itemTypeStr[op] ?? op.description), "float", pos)
            )
        }
    case (.some(let hl), .some(let hr)):
        switch op {
        case .add:
            var r = hl.copy()
            let outcome: FloatHistogram.AddResult
            do {
                outcome = try r.add(hr)
            } catch {
                return (0, nil, false, nil, error)
            }
            var err: (any Error)? = nil
            var info: (any Error)? = nil
            if outcome.counterResetCollision {
                err = newHistogramCounterResetCollisionWarning(pos, .add)
            }
            if outcome.nhcbBoundsReconciled {
                info = newMismatchedCustomBucketsHistogramsInfo(pos, .add)
            }
            return (0, r.compact(maxEmptyBuckets: 0), true, info, err)
        case .sub:
            var r = hl.copy()
            let outcome: FloatHistogram.AddResult
            do {
                outcome = try r.sub(hr)
            } catch {
                return (0, nil, false, nil, error)
            }
            // A difference is always a gauge, whatever the operands were.
            r.counterResetHint = .gaugeType
            var err: (any Error)? = nil
            var info: (any Error)? = nil
            if outcome.counterResetCollision {
                err = newHistogramCounterResetCollisionWarning(pos, .sub)
            }
            if outcome.nhcbBoundsReconciled {
                info = newMismatchedCustomBucketsHistogramsInfo(pos, .sub)
            }
            return (0, r.compact(maxEmptyBuckets: 0), true, info, err)
        // "This operation expects that both histograms are compacted" — upstream's comment.
        // The VALUE returned is `hlhs`, not a fresh histogram.
        case .eqlc: return (0, hl, hl.equals(hr), nil, nil)
        case .neq: return (0, hl, !hl.equals(hr), nil, nil)
        default:
            return (
                0, nil, false, nil,
                newIncompatibleTypesInBinOpInfo("histogram", (itemTypeStr[op] ?? op.description), "histogram", pos)
            )
        }
    }
    // Go panics with `operator %q not allowed for operations between Vectors`. The parser makes
    // this unreachable; returning "no output, no annotation" would be a silent wrong answer, so
    // it is an info naming the operator instead.
    return (
        0, nil, false, nil,
        newIncompatibleTypesInBinOpInfo("float", (itemTypeStr[op] ?? op.description), "float", pos)
    )
}

/// Go: `changesMetricSchema` — whether the operator invalidates the schema metadata labels.
///
/// The seven arithmetic operators do; the six comparisons and the set operators do not. So
/// `a + b` loses `__name__` and `a > b` keeps it, which is not symmetry anybody guesses.
func changesMetricSchema(_ op: ItemType) -> Bool {
    switch op {
    case .add, .sub, .div, .mul, .pow, .mod, .atan2:
        return true
    default:
        return false
    }
}

/// Go: `handleVectorBinopError` — turn `VectorBinop`'s last error into annotations.
///
/// Three outcomes, and the third is silence: an info or warning becomes an annotation verbatim,
/// an incompatible-schema histogram error becomes a *different* warning naming the operator, and
/// anything else is discarded.
func handleVectorBinopError(_ err: (any Error)?, _ e: BinaryExpr) -> Annotations {
    guard let err else {
        return Annotations()
    }
    if let anno = err as? any AnnotationError {
        // `errors.Is(err, PromQLInfo) || errors.Is(err, PromQLWarning)` — in the port, being an
        // `AnnotationError` at all is that test: the two sentinels are the only kinds.
        var a = Annotations()
        _ = a.add(anno)
        return a
    }
    if (err as? HistogramError) == .incompatibleSchema {
        var a = Annotations()
        _ = a.add(newIncompatibleBucketLayoutInBinOpWarning((itemTypeStr[e.op] ?? e.op.description), e.positionRange))
        return a
    }
    return Annotations()
}
