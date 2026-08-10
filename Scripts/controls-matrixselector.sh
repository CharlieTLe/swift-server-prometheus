#!/usr/bin/env bash
# Negative controls for the matrix-selector slice (Engine+MatrixSelector.swift).
#
# Same harness as controls-rangequery.sh: build first so a non-compiling perturbation is not
# mistaken for a failing test, and require the "Test run with" line so a --filter matching
# nothing cannot pass for green.
#
# `matrixSelector` always passes nil slices in, so the RETENTION half of `matrixIterSlice` —
# the overlap/drop/`mintFloats` logic — has no caller yet and its controls are expected to
# survive. They are listed anyway, and marked, so the next slice (the `matrixArg` half of the
# `Call` arm) can re-run this file and watch them start breaking.
set -uo pipefail
cd "$(dirname "$0")/.."

# Two files: the slice itself, and the runtime-error text it reproduces.
FILES=(Sources/PromQL/Engine+MatrixSelector.swift Sources/PromQL/Engine+Errors.swift)
BACKUPS=()
for f in "${FILES[@]}"; do b=$(mktemp); cp "$f" "$b"; BACKUPS+=("$b"); done
restore() { for i in "${!FILES[@]}"; do cp "${BACKUPS[$i]}" "${FILES[$i]}"; done; }
trap restore EXIT

# run <name> <old> <new> [file-index, default 0]
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
  if [ $? -ne 0 ]; then echo "SKIP      $name (patch did not apply)"; return; fi
  if ! timeout 600 swift build >/dev/null 2>&1; then echo "COMPILE   $name"; return; fi
  out=$(timeout 600 swift test --filter "EngineExec|MatrixIterSlice" 2>&1)
  if grep -q "Test run with .* passed" <<<"$out"; then
    echo "SURVIVED  $name"
  elif grep -q "Test run with" <<<"$out"; then
    echo "broke     $name"
  else
    echo "broke     $name (trapped)"
  fi
}

# --- the window's bounds
run "the buffer loop includes points exactly on mint" \
  'if t > mintFloats {
                    currentSamples += 1' \
  'if t >= mintFloats {
                    currentSamples += 1'

run "the sought sample is taken at or past maxt rather than exactly on it" \
  'if t == maxt && !PromValue.isStaleNaN(f) {' \
  'if t >= maxt && !PromValue.isStaleNaN(f) {'

run "the mint == maxt early return is dropped" \
  'if mint == maxt {
            // Empty range: whatever the retention left is the answer.
            return
        }' \
  '()'

# --- anchored / smoothed
run "anchored does not widen the buffer" \
  'if vs.anchored {
            bufferRange += lookback
            mint -= lookback' \
  'if vs.anchored {
            mint -= lookback'

run "anchored does not move mint back" \
  'if vs.anchored {
            bufferRange += lookback
            mint -= lookback
        }' \
  'if vs.anchored {
            bufferRange += lookback
        }'

run "smoothed widens the buffer by one lookback instead of two" \
  'bufferRange += 2 * lookback' \
  'bufferRange += lookback'

run "smoothed does not move maxt forward" \
  'mint -= lookback
            maxt += lookback' \
  'mint -= lookback'

run "extendFloats is given the widened window rather than the original" \
  'ss.floats = try extendFloats(ss.floats, matrixMint, matrixMaxt, false)' \
  'ss.floats = try extendFloats(ss.floats, mint, maxt, false)'

run "smoothed passes false for the interpolation flag" \
  'ss.floats = try extendFloats(ss.floats, matrixMint, matrixMaxt, true)' \
  'ss.floats = try extendFloats(ss.floats, matrixMint, matrixMaxt, false)'

# --- extendFloats itself
run "extendFloats searches the whole slice rather than all but the last point" \
  'goSortSearch(lastSampleIndex) { floats[$0].t > mint } - 1)' \
  'goSortSearch(floats.count) { floats[$0].t > mint } - 1)'

run "extendFloats drops the -1 that steps back to the point before mint" \
  'goSortSearch(lastSampleIndex) { floats[$0].t > mint } - 1)' \
  'goSortSearch(lastSampleIndex) { floats[$0].t > mint })'

run "extendFloats' smoothed upper search is > rather than >=" \
  'lastSampleIndex = goSortSearch(lastSampleIndex) { floats[$0].t >= maxt }' \
  'lastSampleIndex = goSortSearch(lastSampleIndex) { floats[$0].t > maxt }'

run "extendFloats' empty-window test is < rather than <=" \
  'if floats[lastSampleIndex].t <= mint {
        return []
    }' \
  'if floats[lastSampleIndex].t < mint {
        return []
    }'

run "extendFloats keeps the real sample sitting on mint" \
  'if floats[firstSampleIndex].t <= mint {
        firstSampleIndex += 1
    }' \
  '()'

run "extendFloats keeps the real sample sitting on maxt" \
  'if floats[lastSampleIndex].t >= maxt {
        lastSampleIndex -= 1
    }' \
  '()'

run "goSortSearch converges from the wrong side" \
  'if !f(h) {
            i = h + 1
        } else {
            j = h
        }' \
  'if f(h) {
            i = h + 1
        } else {
            j = h
        }'

# --- matrixSelector's own bookkeeping
run "an empty series is kept rather than dropped" \
  'if totalSize > 0 {
                matrix.series.append(ss)
            }' \
  '_ = totalSize
            matrix.series.append(ss)'

run "the buffer is not reset between series" \
  'chkIter = s.iterator(chkIter)
            it.reset(chkIter!)' \
  'chkIter = s.iterator(chkIter)'

run "a stale float is tested after the timestamp instead of before" \
  'if PromValue.isStaleNaN(f) {
                    continue loop
                }
                if t > mintFloats {' \
  'if t > mintFloats {'

run "the anchored histogram guard is a length test rather than a nil test" \
  'if histograms != nil {
                    throw EvaluationError.anchoredWithHistograms' \
  'if !(histograms ?? []).isEmpty {
                    throw EvaluationError.anchoredWithHistograms'

run "the empty-slice panic is guarded instead of reproduced" \
  'guard lastSampleIndex >= 0 && lastSampleIndex < floats.count else {
        throw QueryError.unexpected(
            GoRuntimeError.indexOutOfRange(lastSampleIndex, length: floats.count))
    }' \
  'if lastSampleIndex < 0 || lastSampleIndex >= floats.count {
        return []
    }'

run "the runtime error prints a length for a negative index" \
  'if i < 0 {
                return "runtime error: index out of range [\(i)]"
            }' \
  'if false {
                return "runtime error: index out of range [\(i)]"
            }' \
  1

# --- the retention half, which matrixSelector now reaches only through the unit tests
run "[retention] the overlap test is >= rather than > mint" \
  'if let existing = floats, !existing.isEmpty, existing[existing.count - 1].t > mint {' \
  'if let existing = floats, !existing.isEmpty, existing[existing.count - 1].t >= mint {'

run "[retention] mintFloats is not advanced to the last retained timestamp" \
  'mintFloats = floats![floats!.count - 1].t' \
  '()'

run "[retention] the float overlap branch decrements by the retained count" \
  'currentSamples -= drop
            floats!.removeFirst(drop)' \
  'currentSamples -= floats!.count - drop
            floats!.removeFirst(drop)'

restore
echo "--- controls done; file restored"
