#!/usr/bin/env bash
# Negative controls for the `matrixArg` half of the Call arm (Engine+CallMatrix.swift, plus the
# dispatch in Engine+Eval.swift and the two safe-function sets in FunctionTables.swift).
#
# Same harness as the other two, now shared: `Scripts/lib/control-run.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."

FILES=(
  Sources/PromQL/Engine+CallMatrix.swift
  Sources/PromQL/Engine+Eval.swift
  Sources/PromQL/FunctionTables.swift
)
BACKUPS=()
for f in "${FILES[@]}"; do b=$(mktemp); cp "$f" "$b"; BACKUPS+=("$b"); done
restore() { for i in "${!FILES[@]}"; do cp "${BACKUPS[$i]}" "${FILES[$i]}"; done; }
trap restore EXIT

# run <name> <old> <new> [file-index, default 0]

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
  control_verdict "$name" 'EngineExec|MatrixIterSlice' 56
}

# --- the window, per step
run "refetch is unconditional, so an @-pinned range moves with the step" \
  'let refetch = ts == startTimestamp || selVS.timestamp == nil' \
  'let refetch = true'

run "refetch happens only on step 0, so an unpinned range never moves" \
  'let refetch = ts == startTimestamp || selVS.timestamp == nil' \
  'let refetch = ts == startTimestamp'

run "stepRange is the range rather than min(range, interval)" \
  'stepRange = Swift.min(selRange, interval)' \
  'stepRange = selRange'

run "stepRange is the interval rather than min(range, interval)" \
  'stepRange = Swift.min(selRange, interval)' \
  'stepRange = interval'

run "the buffer's delta is never reduced" \
  'it.reduceDelta(stepRange)' \
  '()'

run "an empty window is passed to the function instead of skipped" \
  'if (floats?.count ?? 0) + (histograms?.count ?? 0) == 0 {
                    ts += interval
                    continue
                }' \
  '()'

run "anchored does not widen the Call arm's buffer" \
  'stepRange = Swift.min(selRange + lookback, interval)
            bufferRange += lookback' \
  'stepRange = Swift.min(selRange + lookback, interval)'

run "smoothed moves mint but not maxt in the per-step window" \
  'mint -= lookback
                        maxt += lookback' \
  'mint -= lookback'

# --- the scalar arguments
run "a scalar argument is read at index 0 rather than at the step number" \
  'Sample(f: evalVals[j]!.series[0].floats[step].f)' \
  'Sample(f: evalVals[j]!.series[0].floats[0].f)'

run "the matrix argument is the LAST range argument rather than the first" \
  'let matrixArgIndex = e.args.firstIndex {
                $0 is MatrixSelector || $0 is SubqueryExpr
            }' \
  'let matrixArgIndex = e.args.lastIndex {
                $0 is MatrixSelector || $0 is SubqueryExpr
            }' \
  1

# --- the output
run "the LAST sample of the output vector is taken rather than the first" \
  'if let first = outVec.samples.first {' \
  'if let first = outVec.samples.last {'

run "the reuse buffer keeps the previous step's output" \
  'enh.out = Vector()
                if let first = outVec.samples.first {' \
  'if let first = outVec.samples.first {'

# --- dropName
run "dropName is inverted for last_over_time/first_over_time" \
  'let dropName = funcName != "last_over_time" && funcName != "first_over_time"' \
  'let dropName = funcName == "last_over_time" || funcName == "first_over_time"'

run "dropName is unconditional" \
  'let dropName = funcName != "last_over_time" && funcName != "first_over_time"' \
  'let dropName = true'

run "the metadata labels are not stripped when dropName is set" \
  'if !enableDelayedNameRemoval && seriesDropName {
                metric = metric.dropReserved(isMetadataLabel)
            }' \
  '()'

run "dropName ignores the input series' own flag" \
  'let seriesDropName = dropName || inputDropName' \
  'let seriesDropName = dropName'

# --- the sample accounting
run "the per-series sample limit check is dropped" \
  'if currentSamples + ss.floats.count + histSamples > maxSamples {
                    throw QueryError.tooManySamples(evaluationEnv)
                }' \
  '()'

run "the per-series limit is >= rather than >" \
  'if currentSamples + ss.floats.count + histSamples > maxSamples {' \
  'if currentSamples + ss.floats.count + histSamples >= maxSamples {'

run "the previous series' window is not released before reuse" \
  'currentSamples -= (floats?.count ?? 0) + totalHPointSize(histograms ?? [])
            if floats != nil {' \
  'if floats != nil {'

run "the final window is not released after the last series" \
  "        currentSamples -= (floats?.count ?? 0) + totalHPointSize(histograms ?? [])

        if funcName ==" \
  "
        if funcName =="

run "the output series is counted before the limit check rather than after" \
  'mat.series.append(ss)
                currentSamples += ss.floats.count + histSamples' \
  'currentSamples += ss.floats.count + histSamples
                mat.series.append(ss)'

# --- absent_over_time
run "absent_over_time drops its complete-series early exit" \
  'for s in mat.series where s.floats.count + s.histograms.count == steps {
            return Matrix()
        }' \
  '()'

run "absent_over_time drops the i > 0 guard on its second early exit" \
  'if i > 0 && found.count == steps {' \
  'if found.count == steps {'

run "absent_over_time does not carry dropName onto its synthetic series" \
  'metric: createLabelsForAbsentFunction(e.args[0]), floats: newp,
                dropName: dropName)' \
  'metric: createLabelsForAbsentFunction(e.args[0]), floats: newp)'

run "absent_over_time counts steps with the wrong fencepost" \
  'let steps = Int(1 + (endTimestamp - startTimestamp) / interval)' \
  'let steps = Int((endTimestamp - startTimestamp) / interval)'

# --- the rate/increase possible-non-counter info
run "the non-counter info reads the OUTPUT's metric name" \
  'let metricName = inMatrix.series[0].metric[LabelName.metricName]' \
  'let metricName = ss.metric[LabelName.metricName]'

run "the non-counter info fires for a series with no float output" \
  'if !metricName.isEmpty && !ss.floats.isEmpty {' \
  'if !metricName.isEmpty {'

run "the non-counter info accepts only the _total suffix" \
  '} else if !metricName.hasSuffix("_total") && !metricName.hasSuffix("_sum")
                        && !metricName.hasSuffix("_count") && !metricName.hasSuffix("_bucket")' \
  '} else if !metricName.hasSuffix("_total")'

run "the non-counter info also fires for delta" \
  'if funcName == "rate" || funcName == "increase" {' \
  'if funcName == "rate" || funcName == "increase" || funcName == "delta" {'

# --- the extended-modifier validation
run "the permitted-function list is not sorted" \
  'permitted: anchoredSafeFunctions.sorted(),' \
  'permitted: anchoredSafeFunctions.reversed().sorted().reversed().map { $0 },'

run "smoothed accepts everything anchored does" \
  'public let smoothedSafeFunctions: Set<String> = [
    "rate", "increase", "delta",
]' \
  'public let smoothedSafeFunctions: Set<String> = [
    "resets", "changes", "rate", "increase", "delta",
]' \
  2

restore
echo "--- controls done; files restored"
