#!/usr/bin/env bash
# Negative controls for the chunk-metadata port: `appendable`, the header rules, the position-in-chunk
# hint rule, and MemStorage's use of them.
#
# Each control perturbs ONE decision, rebuilds, runs the chunkmeta corpus AND the exit gate (which is
# now the consumer), then restores. A SURVIVOR must be argued, never shrugged at. See HANDOFF §4.
set -uo pipefail
cd "$(dirname "$0")/.."
M=Sources/PromChunkEnc/HistogramMeta.swift
P=Sources/PromChunkEnc/ChunkPlan.swift
S=Sources/PromTestStorage/MemStorage.swift
cp "$M" /tmp/cm.orig && cp "$P" /tmp/cp.orig && cp "$S" /tmp/cs.orig
restore() { cp /tmp/cm.orig "$M"; cp /tmp/cp.orig "$P"; cp /tmp/cs.orig "$S"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'ChunkMeta|ExitGate|MatrixIterSlice' 52
  restore
}

echo "=== counterResetHint: the position rule ==="
perl -0pi -e 's/case numRead > 1:/case numRead > 0:/' "$M"; run "position rule fires on the FIRST sample too"
perl -0pi -e 's/case numRead > 1:/case numRead > 2:/' "$M"; run "position rule waits for the THIRD sample"
perl -0pi -e 's/case header == \.gaugeType:\n        \/\/ A gauge chunk contains gauge histograms only\.\n        return \.gaugeType/case false:\n        return .gaugeType/' "$M"; run "gauge chunks lose their gauge hint"

echo "=== appendable: the check ORDER, which is load-bearing ==="
# The explicit reset hint is honoured BEFORE staleness and the count.
perl -0pi -e 's/    if h\.counterResetHint == \.counterReset \{\n        \/\/ "Always honor the explicit counter reset hint\."\n        return \(false, true\)\n    \}//' "$M"; run "explicit counterReset hint not honoured"
# Staleness comes before the count, so a stale sample is never a reset.
perl -0pi -e 's/    if PromValue\.isStaleNaN\(h\.sum\) \{\n        \/\/ A stale sample.s buckets and spans do not matter\.\n        return \(true, false\)\n    \}//' "$M"; run "a stale sample is not exempt from the count check"
perl -0pi -e 's/    if PromValue\.isStaleNaN\(state\.sum\) \{\n        \/\/ After a stale sample the chunk accepts only stale samples\.\n        return \(false, false\)\n    \}//' "$M"; run "a chunk accepts non-stale samples after a stale one"
# A schema change is NOT a reset, which is what separates the two booleans.
perl -0pi -e 's/    if h\.schema != state\.schema \|\| h\.zeroThreshold != state\.zeroThreshold \{\n        \/\/ A layout the encoder cannot express — cut a chunk, but NOT a reset\.\n        return \(false, false\)\n    \}/    if h.schema != state.schema || h.zeroThreshold != state.zeroThreshold {\n        return (false, true)\n    }/' "$M"; run "a schema change counts as a reset"
# The count, the zero count and the custom bounds.
perl -0pi -e 's/    if h\.count < state\.count \{\n        return \(false, true\)\n    \}//' "$M"; run "a count going backwards is not a reset"
perl -0pi -e 's/    if h\.zeroCount < state\.zeroCount \{/    if false {/' "$M"; run "a zero count going backwards is not a reset"
perl -0pi -e 's/    if isCustomBucketsSchema\(h\.schema\)\n        && !customBucketBoundsMatch\(h\.customValues, state\.customValues\)\n    \{\n        return \(false, true\)\n    \}//' "$M"; run "changed custom bounds are not a reset"
# The gauge short-circuit.
perl -0pi -e 's/    if state\.numSamples > 0 && state\.header == \.gaugeType \{\n        return \(false, false\)\n    \}//' "$M"; run "a counter sample may join a gauge chunk"
perl -0pi -e 's/    if state\.numSamples > 0 && state\.header != \.gaugeType \{\n        return false\n    \}//' "$M"; run "a gauge sample may join a counter chunk"

echo "=== expandFloatSpansAndBuckets: the empty-vs-used distinction ==="
# A bucket vanishing is a reset only if it was IN USE.
perl -0pi -e 's/                if aCount == 0 \{\n                    addInsert\(&bInserts, &bInter, aIdx\)\n                    advanceA\(\)\n                    continue\n                \}\n                return \(\[\], \[\], false\)/                addInsert(\&bInserts, \&bInter, aIdx)\n                advanceA()\n                continue/' "$P.nonexistent" 2>/dev/null
perl -0pi -e 's/            \} else if aIdx < bIdx \{\n                \/\/ `b` is missing a bucket `a` has\. Fine only if `a`.s was empty\.\n                if aCount == 0 \{/            } else if aIdx < bIdx {\n                if true {/' "$M"; run "a vanished IN-USE bucket is not a reset (mid)"
perl -0pi -e 's/        \} else if aOK && !bOK \{\n            if aCount == 0 \{/        } else if aOK \&\& !bOK {\n            if true {/' "$M"; run "a vanished IN-USE bucket is not a reset (tail)"
# A bucket's own count dropping while the total rises.
perl -0pi -e 's/                if aCount > bCount \{\n                    return \(\[\], \[\], false\)\n                \}//' "$M"; run "a per-bucket count drop is not a reset"
# The iterator's zero-length-span handling.
perl -0pi -e 's/            if spans\[span\]\.length == 0 \{\n                idx -= 1\n                continue\n            \}//' "$M"; run "zero-length spans yield a bucket"
perl -0pi -e 's/        if let first = spans\.first \{\n            idx \+= Int\(first\.offset\)\n        \}//' "$M"; run "the first span's offset is ignored"

echo "=== ChunkPlan: which boundary sets which header ==="
perl -0pi -e 's/startChunk\(reset \? \.counterReset : \.unknownCounterReset\)/startChunk(reset ? .counterReset : .notCounterReset)/' "$P"; run "an internal cut sets notCounterReset"
perl -0pi -e 's/            startChunk\(\.gaugeType\)/            startChunk(.unknownCounterReset)/' "$P"; run "a gauge cut does not set the gauge header"
perl -0pi -e 's/            if h\.counterResetHint == \.gaugeType \{\n                header = \.gaugeType\n            \} else //' "$P"; run "a new chunk's gauge hint loses to prev"
# Swapped rather than deleted: deleting leaves `prev` unused, which is a build failure and not a
# behaviour change.
perl -0pi -e 's/                header = reset \? \.counterReset : \.notCounterReset/                header = reset ? .notCounterReset : .counterReset/' "$P"; run "a Head cut inverts the derived header"
perl -0pi -e 's/        if PromValue\.isStaleNaN\(h\.sum\) \{\n            return \.unknownCounterReset\n        \}//' "$P"; run "a stale sample reads back a positional hint"
# The stale sample must not overwrite the chunk's accumulated layout.
# ^ REMOVED. The control survived and the reason is a proof rather than a corpus gap: once a chunk
# holds a stale sample, `appendable`'s `isStaleNaN(state.sum)` branch cuts for every following
# non-stale sample and exempts every following stale one, so no comparison ever reads the layout a
# stale sample would have overwritten. The port therefore does not model the preservation at all —
# see the comment in ChunkPlan.swift where fifteen lines of it were deleted.

echo "=== MemStorage: the derivation ==="
perl -0pi -e 's/            let hint = entries\[idx\]\.planner\.plan\(fh\)\n            if fh\.counterResetHint != hint \{/            let hint = entries[idx].planner.plan(fh)\n            if false {/' "$S"; run "the storage carries hints instead of deriving them"
perl -0pi -e 's/        case \.float:\n            entries\[idx\]\.planner = FloatHistogramChunkPlanner\(\)//' "$S"; run "a float sample does not reset the planner"
