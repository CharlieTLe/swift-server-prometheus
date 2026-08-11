#!/usr/bin/env bash
# Negative controls for aggregationK / count_values (Engine+AggregationK.swift, the K dispatch in
# Engine+Aggregation.swift, and GoHeap).
set -uo pipefail
cd "$(dirname "$0")/.."

FILES=(
  Sources/PromQL/Engine+AggregationK.swift
  Sources/PromQL/Engine+Aggregation.swift
  Sources/GoCompat/GoHeap.swift
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

# --- GoHeap
run "heap up uses the wrong parent formula" \
  'let i = (j - 1) / 2' \
  'let i = j / 2' \
  2

run "heap down prefers the right child on a tie" \
  'if j2 < n && less(j2, j1) {' \
  'if j2 < n && !less(j1, j2) {' \
  2

run "heap Fix always sifts up as well as down" \
  'if !down(i, count, less, swap) {
            up(i, less, swap)
        }' \
  '_ = down(i, count, less, swap)
        up(i, less, swap)' \
  2

run "heap down does not report whether it moved" \
  'return i > i0' \
  'return true' \
  2

# --- the comparators
run "the heap comparator drops its NaN clause" \
  'func vectorHeapLess(_ a: Sample, _ b: Sample) -> Bool {
    if a.f.isNaN {
        return true
    }
    return a.f < b.f
}' \
  'func vectorHeapLess(_ a: Sample, _ b: Sample) -> Bool {
    return a.f < b.f
}'

run "the reverse comparator is a strict reversal, NaN clause included" \
  'func vectorReverseHeapLess(_ a: Sample, _ b: Sample) -> Bool {
    if a.f.isNaN {
        return true
    }
    return a.f > b.f
}' \
  'func vectorReverseHeapLess(_ a: Sample, _ b: Sample) -> Bool {
    if b.f.isNaN {
        return true
    }
    return a.f > b.f
}'

# --- k clamping and the early returns
run "k is not clamped to the input size" \
  'k = Swift.min(GoConv.int64(fParam), Int64(inputMatrix.series.count))' \
  'k = GoConv.int64(fParam)'

run "k < 1 returns without advancing the remaining series" \
  'if k < 1 {
                    if enh.ts != endTimestamp {
                        advanceRemainingSeries(enh.ts, si + 1)
                    }
                    return (Matrix(), annos)
                }' \
  'if k < 1 {
                    return (Matrix(), annos)
                }'

run "limitk breaks without advancing the remaining series" \
  'if groupsRemaining == 0 {
                        if enh.ts != endTimestamp {
                            advanceRemainingSeries(enh.ts, si + 1)
                        }
                        break seriesLoop
                    }' \
  'if groupsRemaining == 0 {
                        break seriesLoop
                    }'

run "limitk never breaks early" \
  'if !groups[idx].groupAggrComplete
                    && Int64(groups[idx].heapSamples.count) == k
                {' \
  'if false {'

run "advanceRemainingSeries starts at the current series rather than the next" \
  'advanceRemainingSeries(enh.ts, si + 1)
                    }
                    return (Matrix(), annos)' \
  'advanceRemainingSeries(enh.ts, si)
                    }
                    return (Matrix(), annos)'

run "limit_ratio does not clamp its ratio" \
  '} else if fParam < -1.0 {
                    r = -1.0
                } else if fParam > 1.0 {
                    r = 1.0
                } else {
                    r = fParam
                }' \
  '} else {
                    r = fParam
                }'

# --- the replacement tests
run "topk does not replace a NaN root" \
  '} else if groups[idx].heapSamples[0].f < s.f
                    || (groups[idx].heapSamples[0].f.isNaN && !s.f.isNaN)' \
  '} else if groups[idx].heapSamples[0].f < s.f'

run "bottomk does not replace a NaN root" \
  '} else if groups[idx].heapSamples[0].f > s.f
                    || (groups[idx].heapSamples[0].f.isNaN && !s.f.isNaN)' \
  '} else if groups[idx].heapSamples[0].f > s.f'

run "topk uses the reverse comparator for its heap" \
  'heapUp(&groups[idx].heapSamples, reverse: false)
                } else if groups[idx].heapSamples[0].f < s.f' \
  'heapUp(&groups[idx].heapSamples, reverse: true)
                } else if groups[idx].heapSamples[0].f < s.f'

run "the k == 1 guard on Fix is dropped" \
  '                    if k > 1 {
                        heapFix(&groups[idx].heapSamples, reverse: false)
                    }' \
  '                    heapFix(&groups[idx].heapSamples, reverse: false)'

# --- the output ordering
run "topk does not reverse its heap before emitting" \
  'less: { vectorHeapLess(samples[$1], samples[$0]) },' \
  'less: { vectorHeapLess(samples[$0], samples[$1]) },'

run "bottomk does not reverse its heap before emitting" \
  'less: { vectorReverseHeapLess(samples[$1], samples[$0]) },' \
  'less: { vectorReverseHeapLess(samples[$0], samples[$1]) },'

run "limitk sorts its heap before emitting" \
  'case .limitk, .limitRatio:
                // NO sort: emitted in HEAP order, which is why `GoHeap` has to be Go'"'"'s.
                for v in aggr.heapSamples {' \
  'case .limitk, .limitRatio:
                var sorted = aggr.heapSamples
                GoSort.sort(
                    count: sorted.count,
                    less: { vectorHeapLess(sorted[$0], sorted[$1]) },
                    swap: { sorted.swapAt($0, $1) })
                for v in sorted {'

run "the instant path accumulates into seriess like a range query" \
  'if endTimestamp == startTimestamp {
                if let h {' \
  'if false {
                if let h {'

# --- rangeEvalAgg's K dispatch
run "the instant shortcut for the k operators is dropped" \
  'if startTimestamp == endTimestamp {
                    _ = annos.merge(ws)
                    return (stepResult, annos)
                }' \
  '_ = stepResult' \
  1

run "the topk parameter guards are dropped" \
  'if params.min <= minInt64AsDouble {
                throw EvaluationError.scalarUnderflowsInt64(params.min)
            }
            if params.max >= maxInt64AsDouble {
                throw EvaluationError.scalarOverflowsInt64(params.max)
            }' \
  '()' \
  1

run "maxInt64AsDouble is Int64.max rather than the largest exactly representable" \
  'let maxInt64AsDouble: Double = 9_223_372_036_854_774_784' \
  'let maxInt64AsDouble: Double = 9_223_372_036_854_775_807' \
  1

run "the k operators return early only when max k is below one" \
  'if params.max < 1 {
                return (Matrix(), annos)
            }' \
  'if params.min < 1 {
                return (Matrix(), annos)
            }' \
  1

run "limit_ratio returns early on max == 0 alone" \
  'if params.max == 0 && params.min == 0 {' \
  'if params.max == 0 {' \
  1

# --- count_values
run "count_values does not add the value label to the by-grouping" \
  'if !e.without {
                    grouping.append(name)
                    grouping.sort()
                }' \
  '()' \
  3

run "count_values adds the value label for without too" \
  'if !e.without {
                    grouping.append(name)
                    grouping.sort()
                }' \
  'grouping.append(name)
                grouping.sort()' \
  3

run "count_values formats its value label with 'g' rather than 'f'" \
  'enh.lb.set(valueLabel, GoFloat.formatF(s.f))' \
  'enh.lb.set(valueLabel, GoFloat.formatG(s.f))'

run "count_values does not validate the label name" \
  'if !ValidationScheme.utf8.isValidLabelName(name) {' \
  'if false {' \
  3

run "count_values validates with the legacy scheme" \
  'if !ValidationScheme.utf8.isValidLabelName(name) {' \
  'if !ValidationScheme.legacy.isValidLabelName(name) {' \
  3

restore
echo "--- controls done; files restored"
