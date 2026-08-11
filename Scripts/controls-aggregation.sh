#!/usr/bin/env bash
# Negative controls for the aggregations (Engine+Aggregation.swift and the AggregateExpr arm).
set -uo pipefail
cd "$(dirname "$0")/.."

FILES=(
  Sources/PromQL/Engine+Aggregation.swift
  Sources/PromQL/Engine+Eval.swift
)
BACKUPS=()
for f in "${FILES[@]}"; do b=$(mktemp); cp "$f" "$b"; BACKUPS+=("$b"); done
restore() { for i in "${!FILES[@]}"; do cp "${BACKUPS[$i]}" "${FILES[$i]}"; done; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  local name="$1" from="$2" to="$3" idx="${4:-0}"
  restore
  python3 - "${FILES[$idx]}" "$from" "$to" <<'PY2'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(old) != 1:
    sys.stderr.write("PATCH-NOT-UNIQUE (%d matches)\n" % s.count(old))
    sys.exit(3)
open(path, "w").write(s.replace(old, new))
PY2
  if [ $? -ne 0 ]; then printf '  %-56s SKIP (patch did not apply)\n' "$name"; return; fi
  control_verdict "$name" 'EngineExec|MatrixIterSlice|VectorElemBinop|VectorBinopBool' 56
}

# --- the grouping
run "the grouping labels are not sorted in place, so Statement() differs" \
  'e.grouping.sort()
            let sortedGrouping = e.grouping' \
  'let sortedGrouping = e.grouping.sorted()' \
  1

run "the grouping is not sorted at all" \
  'e.grouping.sort()' \
  '()' \
  1

run "by () with no labels hashes the metric instead of returning 0" \
  'if grouping.isEmpty {
        return 0
    }
    return metric.goHash(forNames: grouping)' \
  'return metric.goHash(forNames: grouping)'

run "without uses the forNames hash" \
  'if without {
        return metric.goHash(withoutNames: grouping)
    }' \
  'if without {
        return metric.goHash(forNames: grouping)
    }'

run "generateGroupingLabels does not delete __name__ for without" \
  'enh.lb.del(grouping)
        enh.lb.del([LabelName.metricName])' \
  'enh.lb.del(grouping)'

run "by () with no labels keeps the metric labels" \
  'if !grouping.isEmpty {
        enh.lb.keep(grouping)
        return enh.lb.labels()
    }
    return Labels.empty' \
  'enh.lb.keep(grouping)
    return enh.lb.labels()'

run "by and without are swapped in generateGroupingLabels" \
  'func generateGroupingLabels(
    _ enh: EvalNodeHelper, _ metric: Labels, _ without: Bool, _ grouping: [String]
) -> Labels {
    enh.resetBuilder(metric)
    if without {' \
  'func generateGroupingLabels(
    _ enh: EvalNodeHelper, _ metric: Labels, _ without: Bool, _ grouping: [String]
) -> Labels {
    enh.resetBuilder(metric)
    if !without {'

# --- seen / per-step reset
run "seen is not reset between steps" \
  'for i in groups.indices {
            groups[i].seen = false
        }' \
  '()'

run "a group that was not seen still emits a point" \
  'if !aggr.seen {
                continue
            }' \
  '()'

run "the empty output rows are not removed" \
  'result.series = result.series.filter { !$0.floats.isEmpty || !$0.histograms.isEmpty }' \
  '()'

# --- sum / avg
run "sum does not add the Kahan compensation at the end" \
  'aggr.floatValue += aggr.floatKahanC' \
  '()'

run "sum accumulates without compensation" \
  '(groups[idx].floatValue, groups[idx].floatKahanC) = Kahan.inc(
                        f, groups[idx].floatValue, groups[idx].floatKahanC)' \
  'groups[idx].floatValue += f'

run "avg divides the sum of value and compensation rather than each separately" \
  'aggr.floatValue =
                        aggr.floatValue / aggr.groupCount + aggr.floatKahanC / aggr.groupCount' \
  'aggr.floatValue = (aggr.floatValue + aggr.floatKahanC) / aggr.groupCount'

run "avg never switches to the incremental mean" \
  'if !newV.isInfinite {' \
  'if true {'

run "avg switches to the incremental mean immediately" \
  'if !groups[idx].floatIncrementalMean {
                        let (newV, newC) = Kahan.inc(' \
  'if false {
                        let (newV, newC) = Kahan.inc('

run "the incremental mean divides by groupCount rather than groupCount - 1" \
  'groups[idx].floatMean =
                            groups[idx].floatValue / (groups[idx].groupCount - 1)
                        groups[idx].floatKahanC /= groups[idx].groupCount - 1' \
  'groups[idx].floatMean = groups[idx].floatValue / groups[idx].groupCount
                        groups[idx].floatKahanC /= groups[idx].groupCount'

run "the incremental mean does not scale the compensation by q" \
  '(groups[idx].floatMean, groups[idx].floatKahanC) = Kahan.inc(
                        f / groups[idx].groupCount,
                        qq * groups[idx].floatMean,
                        qq * groups[idx].floatKahanC)' \
  '(groups[idx].floatMean, groups[idx].floatKahanC) = Kahan.inc(
                        f / groups[idx].groupCount,
                        qq * groups[idx].floatMean,
                        groups[idx].floatKahanC)'

run "the incremental mean result drops the compensation" \
  'aggr.floatValue = aggr.floatMean + aggr.floatKahanC' \
  'aggr.floatValue = aggr.floatMean'

# --- min / max
run "max does not replace a NaN seed" \
  'if groups[idx].floatValue < f || groups[idx].floatValue.isNaN {' \
  'if groups[idx].floatValue < f {'

run "min does not replace a NaN seed" \
  'if groups[idx].floatValue > f || groups[idx].floatValue.isNaN {' \
  'if groups[idx].floatValue > f {'

run "min and max are swapped" \
  'if groups[idx].floatValue < f || groups[idx].floatValue.isNaN {
                    groups[idx].floatValue = f
                }

            case .min:' \
  'if groups[idx].floatValue > f || groups[idx].floatValue.isNaN {
                    groups[idx].floatValue = f
                }

            case .min:'

# --- stdvar / stddev
run "Welford's second subtraction reads the OLD mean" \
  'groups[idx].floatMean += delta / groups[idx].groupCount
                    groups[idx].floatValue = groups[idx].floatValue.addingProduct(
                        delta, f - groups[idx].floatMean)' \
  'groups[idx].floatValue = groups[idx].floatValue.addingProduct(
                        delta, f - groups[idx].floatMean)
                    groups[idx].floatMean += delta / groups[idx].groupCount'

run "Welford's product is not fused" \
  'groups[idx].floatValue = groups[idx].floatValue.addingProduct(
                        delta, f - groups[idx].floatMean)' \
  'groups[idx].floatValue += delta * (f - groups[idx].floatMean)'

run "a NaN or infinite first sample does not seed the variance with NaN" \
  '} else if f.isNaN || f.isInfinite {
                        // A NaN or infinite FIRST sample poisons the whole variance, so `stddev`
                        // over a series containing an infinity is NaN and not an infinity.
                        group.floatValue = Double(bitPattern: GoFloat.goNaNBits)
                    } else {
                        group.floatValue = 0
                    }' \
  '} else {
                        group.floatValue = 0
                    }'

run "stddev forgets the square root" \
  'aggr.floatValue = (aggr.floatValue / aggr.groupCount).squareRoot()' \
  'aggr.floatValue = aggr.floatValue / aggr.groupCount'

run "stdvar does not divide by the count" \
  'case .stdvar:
                aggr.floatValue /= aggr.groupCount' \
  'case .stdvar:
                break'

# --- count / group / quantile
run "count reports the value rather than the count" \
  'case .count:
                aggr.floatValue = aggr.groupCount' \
  'case .count:
                break'

run "group does not seed its value to 1" \
  'case .group:
                    group.floatValue = 1' \
  'case .group:
                    break'

run "quantile does not seed its heap with the first sample" \
  'group.heap = [f]' \
  'group.heap = []'

run "the three quantile warnings are exclusive" \
  'if params.hasAnyNaN {
                _ = annos.add(
                    newInvalidQuantileWarning(Double(bitPattern: GoFloat.goNaNBits), aggExpr.param!.positionRange))
            }
            if params.max > 1 {' \
  'if params.hasAnyNaN {
                _ = annos.add(
                    newInvalidQuantileWarning(Double(bitPattern: GoFloat.goNaNBits), aggExpr.param!.positionRange))
            } else if params.max > 1 {'

# --- fParams
run "a constant parameter is consumed like a series" \
  '        if isConstant {
            return constValue
        }' \
  '        if false {
            return constValue
        }'

run "an exhausted parameter series repeats its last value" \
  'if !series.floats.isEmpty {
            let v = series.floats[0].f
            series.floats.removeFirst()
            return v
        }
        return 0' \
  'if !series.floats.isEmpty, series.floats.count > 1 {
            let v = series.floats[0].f
            series.floats.removeFirst()
            return v
        }
        if let v = series.floats.first { return v.f }
        return 0'

run "newFParams uses Swift's max/min rather than Go's" \
  'fp.maxValue = GoMath.max(fp.maxValue, v.f)
            fp.minValue = GoMath.min(fp.minValue, v.f)' \
  'fp.maxValue = Swift.max(fp.maxValue, v.f)
            fp.minValue = Swift.min(fp.minValue, v.f)'

# --- nextValues
run "nextValues prefers the histogram at an equal timestamp" \
  'if let f = series.floats.first, f.t == ts {
            series.floats.removeFirst()
            return (f.f, nil, true)
        }
        if let h = series.histograms.first, h.t == ts {' \
  'if let h = series.histograms.first, h.t == ts {
            series.histograms.removeFirst()
            return (0, h.h, true)
        }
        if let f = series.floats.first, f.t == ts {
            series.floats.removeFirst()
            return (f.f, nil, true)
        }
        if false, let h = series.histograms.first, h.t == ts {'

run "nextValues does not consume the point" \
  '            series.floats.removeFirst()
            return (f.f, nil, true)' \
  '            return (f.f, nil, true)'

# --- the arm's sample accounting
run "the aggregation result does not reset currentSamples" \
  'currentSamples = originalNumSamples + result.totalSamples' \
  '()' \
  1

run "rangeEvalAgg does not reset currentSamples per step" \
  'currentSamples = tempNumSamples
            enh.ts = ts' \
  'enh.ts = ts'

run "dropName is not carried onto the output series" \
  'outputMatrix.series[ri].dropName = aggr.dropName' \
  '()'

restore
echo "--- controls done; files restored"
