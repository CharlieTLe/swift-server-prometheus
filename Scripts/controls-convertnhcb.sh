#!/usr/bin/env bash
# Negative controls for util/convertnhcb (Sources/PromConvertNHCB/ConvertNHCB.swift) and the
# `load_with_nhcb` loader that consumes it.
#
# Each control perturbs ONE decision, rebuilds, runs the differential corpus AND the exit gate, then
# restores. A control that SURVIVES means no committed case distinguishes the behaviour — which must
# then be argued (proof, unreachable, or a corpus gap to fill), never shrugged at. See HANDOFF §4.
set -uo pipefail
cd "$(dirname "$0")/.."
F=Sources/PromConvertNHCB/ConvertNHCB.swift
L=Sources/PromQLTest/Commands.swift
cp "$F" /tmp/nhcb.orig && cp "$L" /tmp/nhcbload.orig
restore() { cp /tmp/nhcb.orig "$F"; cp /tmp/nhcbload.orig "$L"; }
trap restore EXIT

run() {
  local name="$1"
  if ! swift build 2>/dev/null >/dev/null; then printf '  %-46s COMPILE\n' "$name"; restore; return; fi
  local out; out=$(swift test --filter 'ConvertNHCB|ExitGate|NHCBLoaderEdge' 2>&1)
  if grep -qE '✘|error:' <<<"$out"; then printf '  %-46s broke\n' "$name"
  else printf '  %-46s SURVIVED\n' "$name"; fi
  restore
}

echo "=== convertnhcb negative controls ==="
# The two Compact arguments are asymmetric upstream; swap each.
perl -0pi -e 's/return \(rh\.compact\(maxEmptyBuckets: 2\), nil, nil\)/return (rh.compact(maxEmptyBuckets: 0), nil, nil)/' "$F"; run "integer path compacts with 0 not 2"
perl -0pi -e 's/return \(nil, rh\.compact\(maxEmptyBuckets: 0\), nil\)/return (nil, rh.compact(maxEmptyBuckets: 2), nil)/' "$F"; run "float path compacts with 2 not 0"
# The integer encoding is DOUBLE deltas.
perl -0pi -e 's/rh\.positiveBuckets\[i\] = delta - prevDelta/rh.positiveBuckets[i] = delta/' "$F"; run "integer path emits plain deltas"
# The float encoding is PLAIN deltas.
perl -0pi -e 's/rh\.positiveBuckets\[i\] = b\.count - prevCount/rh.positiveBuckets[i] = b.count/' "$F"; run "float path emits cumulative counts"
# CustomValues drops the last boundary.
perl -0pi -e 's/count: buckets\.count - 1\)/count: buckets.count)/g' "$F"; run "customValues keeps every boundary"
# +Inf synthesis and the derived count.
perl -0pi -e 's/h\.count = h\.buckets\[h\.buckets\.count - 1\]\.count/h.count = 0/' "$F"; run "count is not derived from the top bucket"
perl -0pi -e 's/h\.buckets\.append\(TempHistogramBucket\(le: Double\.infinity, count: h\.count\)\)/()/' "$F"; run "+Inf bucket is not synthesised"
# The integer/float decision is made AFTER +Inf is synthesised, and the overall count counts.
perl -0pi -e 's/if h\.count != Double\(intCount\) \{\n            return h\.convertToFloatHistogram\(\)\n        \}//' "$F"; run "fractional overall count still goes integer"
# A duplicate `le` is IGNORED, not an error. Note the perturbation has to make it an *error*:
# deleting the in-order early return is behaviour-preserving, because the out-of-order path below
# returns nil on `buckets[i].le == boundary` too. The first spelling of this control survived for
# that reason and not for want of a case.
perl -0pi -e 's/            \/\/ A duplicate sample; ignored\.\n            return nil/            error = ConvertNHCBError.naNBucket\n            return error/' "$F"; run "duplicate le is an error"
# ...and the out-of-order path's own duplicate tolerance, separately.
perl -0pi -e 's/        if buckets\[i\]\.le == boundary \{\n            return nil\n        \}/        if buckets[i].le == boundary { return ConvertNHCBError.naNBucket }/' "$F"; run "out-of-order duplicate le is an error"
# The out-of-order path checks BOTH neighbours, with two different messages.
perl -0pi -e 's/ConvertNHCBError\.countNotCumulativeAbove/ConvertNHCBError.countNotCumulative/' "$F"; run "successor check reuses the < message"
perl -0pi -e 's/if i > 0 && count < buckets\[i - 1\]\.count \{/if false {/' "$F"; run "out-of-order predecessor check removed"
# The error is sticky.
perl -0pi -e 's/if let error \{ return error \}//g' "$F"; run "errors are not sticky"
# Suffix stripping order.
perl -0pi -e 's/if s\.hasSuffix\("_bucket"\) \{ return \(\.bucket, String\(s\.dropLast\(7\)\)\) \}//' "$F"; run "_bucket suffix not stripped"
# The base metric must drop `le`.
perl -0pi -e 's/b\.del\(\["le"\]\)//' "$F"; run "base metric keeps its le label"

echo "=== load_with_nhcb controls ==="
# A malformed `le` skips the series silently rather than erroring.
perl -0pi -e 's/guard let le = try\? GoFloat\.parse\(d\.metric\["le"\]\), !le\.isNaN else \{ continue \}/let le = (try? GoFloat.parse(d.metric["le"])) ?? 0/' "$L"; run "malformed le is treated as 0"
# Histogram-valued samples in a classic series contribute nothing.
perl -0pi -e 's/guard s\.type == \.float else \{ continue \}//' "$L"; run "native samples feed the collation"
# The emitted samples are sorted by timestamp.
perl -0pi -e 's/for t in w\.order\.sorted\(\)/for t in w.order.sorted().reversed()/' "$L"; run "NHCB samples appended newest-first"
# The integer result is validated and converted, never stored as-is.
perl -0pi -e 's/try out\.validate\(\)//' "$L"; run "the result is not validated"
# ^ SURVIVES, and is ARGUED rather than covered. `validate()` is a pure check that either throws or
# does nothing — it never mutates the histogram — so removing it can only turn a thrown error into a
# stored sample. For it to be observable, `convert()` would have to produce a structurally invalid
# NHCB from valid classic input, which it cannot: the spans it emits are a single run of exactly
# `buckets.count` buckets, the schema is always `customBuckets`, and `customValues` is strictly
# increasing because `setBucketCount` maintains that order. The call is kept because upstream makes
# it and because it will start earning its keep in Phase 8, when a real scrape can deliver a classic
# histogram this loader never sees.
