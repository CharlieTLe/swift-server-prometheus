#!/usr/bin/env bash
# Negative controls for `DeletedIterator`.
#
# The behaviour under test is STATEFULNESS, so the controls that matter are the ones that turn the interval
# cursor back into a filter. `it.Intervals = it.Intervals[1:]` is what makes a second pass over the same
# iterator delete nothing — and the corpus records that second pass precisely so a filter-style port fails
# rather than passing on the first pass alone.
#
# The other cluster is `Next`'s three exits and their ORDER. `ts <= tr.Maxt` is reached only when `InBounds`
# was false, so it means `ts < tr.Mint`; a port that reorders those two drops intervals it should keep.
set -uo pipefail
cd "$(dirname "$0")/.."
D=Sources/PromBlock/DeletedIterator.swift
cp "$D" /tmp/dit.orig
restore() { cp /tmp/dit.orig "$D"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'DeletedIterator' 56
  restore
}

echo "=== the interval list is a CURSOR, not a filter ==="
perl -0pi -e 's/                \/\/ Past this interval — drop it and look at the next\. CONSUMED\.\n                intervals\.removeFirst\(\)/                \/\/ perturbed: no consumption/' "$D"; run "Next never consumes an interval"
perl -0pi -e 's/                \/\/ CONSUMED\. See the file header\.\n                intervals\.removeFirst\(\)\n                continue/                continue/' "$D"; run "Seek never consumes an interval"
perl -0pi -e 's/                intervals\.removeFirst\(\)/                intervals.removeLast()/' "$D"; run "consumption drops from the BACK"

echo "=== Next's three exits, and their order ==="
perl -0pi -e 's/                if tr\.inBounds\(ts\) \{\n                    \/\/ Deleted: fetch the next sample\.\n                    deleted = true\n                    break\n                \}\n                if ts <= tr\.maxt \{/                if ts <= tr.maxt {/' "$D"; run "the before-interval test comes FIRST"
perl -0pi -e 's/                if ts <= tr\.maxt \{/                if ts < tr.maxt {/' "$D"; run "the before-interval test is < not <="
# ^ BREAKS — but only after the corpus was widened twice, and the search is worth recording because it is
# quirk 159's discipline applied to a two-character change.
#
# The test is reached only when `inBounds(ts)` was false, so `ts < tr.mint || ts > tr.maxt`. `<=` and `<`
# differ only at `ts == tr.maxt`, which then forces `ts < tr.mint` — an INVERTED interval whose Maxt lands
# exactly on a sample. Adding inverted intervals was not enough: both spellings still KEEP the sample, one by
# returning and one by falling out of the loop with nothing left to check. The distinguishing shape is an
# inverted interval whose Maxt is on a sample FOLLOWED by an interval containing that sample:
#
#   t=30, intervals [{50,30}, {25,35}]   `<=` keeps 30;  `<` drops {50,30}, then {25,35} deletes 30
#
# Three such cases are in the corpus and this control now breaks on all three. Reasoning found them; more
# random inverted intervals would not have.
perl -0pi -e 's/                if ts <= tr\.maxt \{/                if ts < tr.mint {/' "$D"; run "(equivalence probe: ts < tr.mint instead of ts <= tr.maxt)"
# ^ Expected to SURVIVE and PROVABLY so: the test is reached only when `inBounds(ts)` was false, i.e. when
# `ts < tr.mint || ts > tr.maxt`. Combined with `ts <= tr.maxt` that is exactly `ts < tr.mint`. Upstream's
# spelling is the one that reads as "we have not reached this interval yet"; both compute the same set. This
# is a quirk-160-style tautology, kept deliberately as the contrast to the control above it, which changes
# the predicate and does break.
perl -0pi -e 's/                    deleted = true\n                    break/                    deleted = false\n                    break/' "$D"; run "an in-bounds sample is KEPT"
perl -0pi -e 's/            if deleted \{\n                continue outer\n            \}\n            return valueType/            return valueType/' "$D"; run "the deleted sample is returned anyway"

echo "=== Seek's shape ==="
perl -0pi -e 's/        if iter\.err\(\) != nil \{\n            return \.none\n        \}//' "$D"; run "Seek does not check the wrapped error first"
# ^ SURVIVES, and it is a KNOWN CORPUS GAP rather than an equivalence — recorded as such instead of argued
# away, per quirk 159. No case here has an ERRORING wrapped iterator, because every chunk is built through
# `XORChunk.appender()` and therefore well-formed. `Seek` checks `it.Iter.Err()` first and `Next` does not, so
# the asymmetry is real and unpinned.
#
# To close it: hand the iterator a chunk whose 2-byte sample count exceeds its data, which makes the XOR
# decoder error part-way. That means raw chunk bytes in the fixture input rather than an appender-built chunk,
# which is a corpus-shape change and belongs with the slice that needs it — `populateWithDel*`, whose error
# wrapping (`cannot populate chunk %d from block %s`) needs erroring chunks anyway.
perl -0pi -e 's/            \/\/ Inside an interval: delegate the skipping to `next\(\)`\.\n            return next\(\)/            return valueType/' "$D"; run "Seek into a deleted region returns the deleted sample"
perl -0pi -e 's/            if ts < itv\.mint \{\n                return valueType\n            \}/            if ts <= itv.mint {\n                return valueType\n            }/' "$D"; run "Seek's before-interval test is <= not <"
perl -0pi -e 's/            if ts > itv\.maxt \{/            if ts >= itv.maxt {/' "$D"; run "Seek's past-interval test is >= not >"
# Keep the declaration and drop ONLY the early return — the first version of this control deleted both and
# reported COMPILE, which measures nothing.
perl -0pi -e 's/        if valueType == \.none \{\n            return \.none\n        \}//' "$D"; run "Seek does not stop when the wrapped iterator is exhausted"
perl -0pi -e 's/        \/\/ Past every deleted interval\.\n        return valueType/        return next()/' "$D"; run "Seek past every interval calls next anyway"

echo "=== the forwarding accessors ==="
perl -0pi -e 's/    public func atT\(\) -> Int64 \{ iter\.atT\(\) \}/    public func atT() -> Int64 { iter.at().0 + 1 }/' "$D"; run "atT is off by one"
perl -0pi -e 's/        let ts = atT\(\)\n        for itv in intervals \{/        let ts = at().0\n        for itv in intervals {/' "$D"; run "(no-op control: Seek reads at().0 rather than atT())"
# ^ SURVIVES, ARGUED: `atT()` forwards to `iter.atT()`, and `BoxedXORIterator.atT()` is `it.at.0` — the same
# value by construction for a float chunk. It would NOT be equivalent for a histogram chunk, where `at()` is
# meaningless; the corpus is float-only, so this is a corpus limit and is recorded as one rather than as an
# equivalence. The histogram chunk encodings are Phase 7's.
