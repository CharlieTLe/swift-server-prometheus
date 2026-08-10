#!/usr/bin/env bash
# Negative controls for the vector binary operators (Engine+VectorBinop.swift, the signature
# machinery in Engine+Eval.swift, and the two byte-signature encoders in PromLabels).
set -uo pipefail
cd "$(dirname "$0")/.."

FILES=(
  Sources/PromQL/Engine+VectorBinop.swift
  Sources/PromQL/Engine+Eval.swift
  Sources/PromLabels/Labels+GoEncoding.swift
)
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

# --- the signature machinery
run "sigf's ignoring branch does not prepend __name__" \
  'names = [LabelName.metricName] + names' \
  '()' \
  1

run "sigf uses bytesWithLabels for ignoring too" \
  'sigf = { $0.bytesWithoutLabels(names) }' \
  'sigf = { $0.bytesWithLabels(names) }' \
  1

run "signature ordinals are per-side rather than shared across both" \
  'var signatureToOrdinal: [[UInt8]: Int] = [:]
            for i in matrixes.indices {' \
  'for i in matrixes.indices {
                var signatureToOrdinal: [[UInt8]: Int] = [:]' \
  1

run "the buffered helpers are parallel to the input matrix, not to the gathered vector" \
  'if !seriesHelpers.isEmpty {
                bufHelpers.append(seriesHelpers[i])
            }
            currentSamples += 1' \
  'currentSamples += 1' \
  1

run "bytesWithLabels omits the value separator, so two labels can run together" \
  '                b.append(contentsOf: l.value.utf8)
                b.append(Self.sep)
            }
        }
        return b
    }' \
  '                b.append(contentsOf: l.value.utf8)
            }
        }
        return b
    }' \
  2

# --- the set operators
run "VectorAnd short-circuits only on an empty left" \
  'if lhs.isEmpty || rhs.isEmpty {
            return Vector()
        }
        var present = enh.resetSigsPresent()
        for sh in rhsh {' \
  'if lhs.isEmpty {
            return Vector()
        }
        var present = enh.resetSigsPresent()
        for sh in rhsh {'

run "VectorOr returns nothing when the left is empty rather than the right" \
  'if lhs.isEmpty {
            out.samples.append(contentsOf: rhs.samples)
            return out
        }' \
  'if lhs.isEmpty {
            return out
        }'

run "VectorOr adds every right-hand sample rather than only the unmatched ones" \
  'for (j, rs) in rhs.samples.enumerated() where !present[rhsh[j].sigOrdinal] {' \
  'for (j, rs) in rhs.samples.enumerated() where present[rhsh[j].sigOrdinal] || true {
            _ = j'

run "VectorUnless keeps the MATCHED left samples" \
  'for (i, ls) in lhs.samples.enumerated() where !present[lhsh[i].sigOrdinal] {
            out.append(ls)
        }
        return out
    }
}' \
  'for (i, ls) in lhs.samples.enumerated() where present[lhsh[i].sigOrdinal] {
            out.append(ls)
        }
        return out
    }
}'

# --- VectorBinop
run "one-to-many does not swap the sides" \
  'if matching.card == .oneToMany {
            swap(&lhs, &rhs)
            swap(&lhsh, &rhsh)
        }' \
  '()'

run "one-to-many does not swap the VALUES back" \
  'if matching.card == .oneToMany {
                swap(&fl, &fr)
                swap(&hl, &hr)
            }' \
  '()'

run "the duplicate-series error names the wrong side" \
  'let oneSide = matching.card == .oneToMany ? "left" : "right"' \
  'let oneSide = matching.card == .oneToMany ? "right" : "left"'

run "the many-to-one duplicate check keys on the INPUT rather than the result" \
  'let insertSig = metric.goHash()' \
  'let insertSig = ls.metric.goHash()'

run "the duplicate checks run after the keep filter" \
  'if matching.card == .oneToOne {
                if matchedSigsPresent[sigOrd] {' \
  'if !keep && !returnBool {
                return
            }
            if matching.card == .oneToOne {
                if matchedSigsPresent[sigOrd] {'

run "returnBool does not clear the histogram result" \
  'if returnBool {
                histogramValue = nil
                floatValue = keep ? 1.0 : 0.0
            }' \
  'if returnBool {
                floatValue = keep ? 1.0 : 0.0
            }'

run "the output sample never sets DropName" \
  'Sample(f: floatValue, h: histogramValue, metric: metric, dropName: returnBool))' \
  'Sample(f: floatValue, h: histogramValue, metric: metric))'

run "the empty-side short-circuit is dropped" \
  'if (lhsIn.isEmpty && rhsIn.isEmpty)
            || ((lhsIn.isEmpty || rhsIn.isEmpty) && matching.fillValues.rhs == nil
                && matching.fillValues.lhs == nil)
        {
            return (Vector(), nil)
        }' \
  '()'

# --- resultMetric
run "resultMetric drops the join labels for many-to-one too" \
  'if matching.card == .oneToOne {
            if matching.on {' \
  'if true {
            if matching.on {'

run "resultMetric keeps rather than deletes an empty include label" \
  'if !v.isEmpty {
                enh.lb.set(ln, v)
            } else {
                enh.lb.del([ln])
            }' \
  'if !v.isEmpty {
                enh.lb.set(ln, v)
            }'

run "resultMetric takes the include labels from the MANY side" \
  'let v = rhs[ln]' \
  'let v = lhs[ln]'

run "resultMetric's cache key uses only the left label set" \
  'var key = lhs.goEncodedBytes()
        key.append(contentsOf: rhs.goEncodedBytes())' \
  'let key = lhs.goEncodedBytes()'

run "changesMetricSchema also covers the comparisons" \
  'case .add, .sub, .div, .mul, .pow, .mod, .atan2:
        return true' \
  'case .add, .sub, .div, .mul, .pow, .mod, .atan2, .eqlc, .neq, .gtr, .lss, .gte, .lte:
        return true'

run "changesMetricSchema is never true" \
  'case .add, .sub, .div, .mul, .pow, .mod, .atan2:
        return true' \
  'case .add where false:
        return true'

# --- VectorscalarBinop
run "a scalar on the left of a comparison reports the scalar's value" \
  'if op.isComparisonOperator && swapSides {
                float = rf
                histogram = rh
            }' \
  '()'

run "returnBool does not force keep in the vector/scalar path" \
  'if returnBool {
                float = keep ? 1.0 : 0.0
                keep = true
            }' \
  'if returnBool {
                float = keep ? 1.0 : 0.0
            }'

run "the vector/scalar path does not swap the operands" \
  'if swapSides {
                swap(&lf, &rf)
                swap(&lh, &rh)
            }' \
  '()'

run "the vector/scalar path skips an element on a WARNING too" \
  'if let err, (err as? any AnnotationError)?.kind != .warning {' \
  'if err != nil {'

run "the vector/scalar path does not drop the name for a schema-changing op" \
  'if changesMetricSchema(op) || returnBool {
                    if !enableDelayedNameRemoval {
                        lhsSample.metric = lhsSample.metric.dropReserved(isMetadataLabel)
                    }
                    lhsSample.dropName = true
                }' \
  '()'

# --- vectorElemBinop
run "a comparison returns the RIGHT value rather than the left" \
  'case .gtr: return (lhs, nil, lhs > rhs, nil, nil)' \
  'case .gtr: return (rhs, nil, lhs > rhs, nil, nil)'

run "float * histogram is rejected rather than scaling" \
  'if op == .mul {
            var r = h.copy()
            _ = r.mul(lhs)
            return (0, r.compact(maxEmptyBuckets: 0), true, nil, nil)
        }' \
  '()'

run "the scalar-vector arms use the wrong operand for scaling" \
  'case .mul:
            var r = h.copy()
            _ = r.mul(rhs)' \
  'case .mul:
            var r = h.copy()
            _ = r.mul(lhs)'

# --- the BinaryExpr dispatch
run "the scalar/vector arm passes the vector as the right operand" \
  'e.op, v[1], Scalar(t: 0, v: v[0].samples[0].f), true, e.returnBool, enh,' \
  'e.op, v[0], Scalar(t: 0, v: v[1].samples[0].f), true, e.returnBool, enh,' \
  1

run "the vector/scalar arm passes swap: true" \
  'e.op, v[0], Scalar(t: 0, v: v[1].samples[0].f), false, e.returnBool, enh,' \
  'e.op, v[0], Scalar(t: 0, v: v[1].samples[0].f), true, e.returnBool, enh,' \
  1

run "the set operators are given no matching, so signatures are never computed" \
  'case .land:
                    return try rangeEval(ctx, matching, &ws, [e.lhs, e.rhs]) { v, sh, enh in' \
  'case .land:
                    return try rangeEval(ctx, nil, &ws, [e.lhs, e.rhs]) { v, sh, enh in' \
  1

restore
echo "--- controls done; files restored"
