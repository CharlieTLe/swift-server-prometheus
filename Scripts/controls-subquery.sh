#!/usr/bin/env bash
# Negative controls for subqueries (Engine+Subquery.swift and the two arms in Engine+Eval.swift).
set -uo pipefail
cd "$(dirname "$0")/.."

FILES=(Sources/PromQL/Engine+Subquery.swift Sources/PromQL/Engine+Eval.swift)
BACKUPS=()
for f in "${FILES[@]}"; do b=$(mktemp); cp "$f" "$b"; BACKUPS+=("$b"); done
restore() { for i in "${!FILES[@]}"; do cp "${BACKUPS[$i]}" "${FILES[$i]}"; done; }
trap restore EXIT

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
  if ! timeout 900 swift build >/dev/null 2>&1; then echo "COMPILE   $name"; return; fi
  out=$(timeout 900 swift test --filter "EngineExec|MatrixIterSlice|VectorElemBinop|VectorBinopBool" 2>&1)
  if grep -q "Test run with .* passed" <<<"$out"; then
    echo "SURVIVED  $name"
  elif grep -q "Test run with" <<<"$out"; then
    echo "broke     $name"
  else
    echo "broke     $name (trapped)"
  fi
}

# --- the grid alignment
run "the subquery start is not snapped up" \
  'if subqStart <= target {
            subqStart += subqInterval
        }' \
  '()'

run "the snap-up test is < rather than <=" \
  'if subqStart <= target {' \
  'if subqStart < target {'

run "the subquery start is the raw target" \
  'var subqStart = subqInterval * (target / subqInterval)' \
  'var subqStart = target'

run "the parent end is not snapped down to the parent grid" \
  'var parentEnd = endTimestamp
        if interval > 0 {
            parentEnd = startTimestamp + ((endTimestamp - startTimestamp) / interval) * interval
        }' \
  'let parentEnd = endTimestamp'

run "the parent snap-down guard is interval >= 0" \
  'if interval > 0 {
            parentEnd = startTimestamp' \
  'if interval >= 0 {
            parentEnd = startTimestamp'

run "the subquery end ignores the offset" \
  'let subqEnd = parentEnd - offsetMillis' \
  'let subqEnd = parentEnd'

run "the subquery start ignores the range" \
  'let target = startTimestamp - offsetMillis - rangeMillis' \
  'let target = startTimestamp - offsetMillis'

run "a subquery with no step uses the parent's interval" \
  'subqInterval = noStepSubqueryIntervalFn?(rangeMillis) ?? 0' \
  'subqInterval = interval'

# --- the @ re-rewrite
run "setOffsetForAtModifier is not re-run for the subquery's start" \
  'if subqStart != startTimestamp {
            // The `@` rewrite is measured from the evaluator'"'"'s start time, and this evaluator has
            // a different one. The GUARD is a pure optimisation — the rewrite recomputes `Offset`
            // from `originalOffset`, so re-running it with the same start is idempotent — but the
            // call itself is required.
            setOffsetForAtModifier(subqStart, e.expr)
        }' \
  '()'

run "setOffsetForAtModifier is re-run unconditionally" \
  'if subqStart != startTimestamp {
            // The `@` rewrite is measured from the evaluator'"'"'s start time, and this evaluator has
            // a different one. The GUARD is a pure optimisation — the rewrite recomputes `Offset`
            // from `originalOffset`, so re-running it with the same start is idempotent — but the
            // call itself is required.
            setOffsetForAtModifier(subqStart, e.expr)
        }' \
  'setOffsetForAtModifier(subqStart, e.expr)'

run "setOffsetForAtModifier is re-run against the parent's start" \
  'setOffsetForAtModifier(subqStart, e.expr)' \
  'setOffsetForAtModifier(startTimestamp, e.expr)'

# --- the synthetic selector
run "the synthetic selector's offset is not recomputed for @" \
  'if let t = subq.timestamp {
            // "The offset of subquery is not modified in case of @ modifier. Hence we take care of
            // that here for the result."
            vs.offset = GoDuration(
                nanoseconds: subq.originalOffset.nanoseconds + (startTimestamp - t) * 1_000_000)
        }' \
  '()'

run "the recomputed offset drops the original offset" \
  'nanoseconds: subq.originalOffset.nanoseconds + (startTimestamp - t) * 1_000_000)' \
  'nanoseconds: (startTimestamp - t) * 1_000_000)'

run "the synthetic selector does not carry the subquery's timestamp" \
  'vs.timestamp = subq.timestamp' \
  '()'

run "the synthetic selector does not carry the original offset" \
  'vs.originalOffset = subq.originalOffset' \
  '()'

run "the synthetic matrix selector uses the parent's range" \
  'let ms = MatrixSelector(vectorSelector: vs, range: subq.range)' \
  'let ms = MatrixSelector(vectorSelector: vs, range: GoDuration(nanoseconds: 0))'

# --- the counter reset erasure
run "the counter reset hints are not erased" \
  'case .notCounterReset, .counterReset:
                    // Go shallow-copies to avoid mutating the shared pointer; a Swift struct
                    // assignment already is that copy.
                    mat.series[si].histograms[i].h.counterResetHint = .unknownCounterReset' \
  'case .notCounterReset, .counterReset:
                    break'

run "the erasure also flattens gauge hints" \
  'case .notCounterReset, .counterReset:' \
  'case .notCounterReset, .counterReset, .gaugeType:'

# --- the Call arm's AST replacement
run "the subquery result is not written back into the AST" \
  'e.args[i] = ms' \
  '()' \
  1

run "the subquery's samples are never released" \
  'subqueryCleanup = {
                    (ms.vectorSelector as? VectorSelector)?.series = []
                    self.currentSamples -= totalSamples
                }' \
  '_ = totalSamples' \
  1

run "the subquery's series are not cleared on the way out" \
  '(ms.vectorSelector as? VectorSelector)?.series = []' \
  '()' \
  1

run "a top-level subquery goes through evalSubquery rather than runSubquery" \
  'return try runSubquery(ctx, e, &ws)' \
  'return try evalSubquery(ctx, e, &ws).0.vectorSelector as! Matrix' \
  1

restore
echo "--- controls done; files restored"
