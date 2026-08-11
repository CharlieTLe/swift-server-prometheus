#!/usr/bin/env bash
# Negative controls for the range-query slice. Each perturbation is applied to
# Sources/PromQL/Engine+Eval.swift, the range-query suites are run, and the file is restored.
# A control that leaves the suite GREEN is either a corpus gap or a provably unobservable
# behaviour — and the point of running them is to tell which.
#
# The shared harness asserts that tests actually RAN (HANDOFF §4: a `--filter` matching nothing reports
# success), by requiring the "Test run with N tests" line.
set -uo pipefail
cd "$(dirname "$0")/.."

FILE=Sources/PromQL/Engine+Eval.swift
BACKUP=$(mktemp)
cp "$FILE" "$BACKUP"
restore() { cp "$BACKUP" "$FILE"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  local name="$1" from="$2" to="$3"
  restore
  python3 - "$FILE" "$from" "$to" <<'PY2'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(old) != 1:
    sys.stderr.write("PATCH-NOT-UNIQUE (%d matches)\n" % s.count(old))
    sys.exit(3)
open(path, "w").write(s.replace(old, new))
PY2
  if [ $? -ne 0 ]; then printf '  %-56s SKIP (patch did not apply)\n' "$name"; return; fi
  control_verdict "$name" 'EngineExecRange' 56
}

run "addToSeries puts histograms in the float slice" \
  'guard let h else {
        ss.floats.append(FPoint(t: ts, f: f))
        return
    }
    ss.histograms.append(HPoint(t: ts, h: h))' \
  'ss.floats.append(FPoint(t: ts, f: f))
    _ = h'

run "step duplication starts at startTimestamp, not startTimestamp + interval" \
  'var t = startTimestamp + interval' \
  'var t = startTimestamp'

run "the range tail does not sort the result matrix" \
  'mat.sort()
        return (mat, warnings)' \
  'return (mat, warnings)'

run "the inverted-range check is <= rather than <" \
  'if endTimestamp < startTimestamp {' \
  'if endTimestamp <= startTimestamp {'

run "gatherVector does not consume the point it took" \
  'input!.series[i].floats.removeFirst()' \
  '()'

run "the sort warning ignores the timestamp comparison" \
  'if startTimestamp != endTimestamp {
                    _ = warnings.add(newSortInRangeQueryWarning(e.positionRange))' \
  'if true {
                    _ = warnings.add(newSortInRangeQueryWarning(e.positionRange))'

run "the sort warning is not emitted at all" \
  'case "sort", "sort_desc", "sort_by_label", "sort_by_label_desc":' \
  'case "sort_never_matches_this":'

run "the multi-step result is not accumulated into tempNumSamples" \
  'tempNumSamples += vecNumSamples' \
  '()'

run "rangeEval does not reset currentSamples to the assembled total" \
  'currentSamples = originalNumSamples + mat.totalSamples
        return mat
    }' \
  'return mat
    }'

run "the duplicate-labelset check compares the wrong timestamp" \
  'if existing.ts == ts {' \
  'if false {'

run "the step-invariant duplication skips its own sample-limit check" \
  'if currentSamples > maxSamples {
                        throw QueryError.tooManySamples(evaluationEnv)
                    }
                    t += interval' \
  't += interval'

run "the range evaluator is built with interval 1 instead of the query step" \
  'interval: durationMilliseconds(s.interval),' \
  'interval: 1,'

run "the range evaluator reuses the start timestamp as its end" \
  'endTimestamp: Timestamp.fromTime(s.end),' \
  'endTimestamp: Timestamp.fromTime(s.start),'

run "the step duplication reads the last point rather than the first" \
  'mat.series[i].floats.append(
                            FPoint(t: t, f: mat.series[i].floats[0].f))' \
  'mat.series[i].floats.append(
                            FPoint(t: t, f: mat.series[i].floats.last!.f))'

run "the assembly emits series in label-hash order rather than insertion order" \
  'for h in order {
            mat.series.append(seriess[h]!.series)
        }' \
  'for h in order.sorted() {
            mat.series.append(seriess[h]!.series)
        }'

restore
echo "--- controls done; file restored"
