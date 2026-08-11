#!/usr/bin/env bash
# Negative controls for `blockBaseSeriesSet.Next`.
#
# What this slice claims is SELECTION and ORDER, so the controls are the three skip rules and the four
# boundary comparisons. The trimming half is computed here but observable only through the `populateWithDel*`
# iterators, so several controls below are expected to SURVIVE for that reason — declared as corpus gaps with
# the slice that closes them named, per quirk 159, rather than argued as equivalences.
set -uo pipefail
cd "$(dirname "$0")/.."
B=Sources/PromBlock/BlockSeriesSet.swift
cp "$B" /tmp/bss.orig
restore() { cp /tmp/bss.orig "$B"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'BlockSeriesSet' 56
  restore
}

echo "=== the boundary comparisons are STRICT (both ranges are closed) ==="
perl -0pi -e 's/                if chk\.maxTime < mint \{ continue \}/                if chk.maxTime <= mint { continue }/' "$B"; run "a chunk ending exactly at mint is dropped"
perl -0pi -e 's/                if chk\.minTime > maxt \{ continue \}/                if chk.minTime >= maxt { continue }/' "$B"; run "a chunk starting exactly at maxt is dropped"
perl -0pi -e 's/                if chk\.maxTime < mint \{ continue \}/                if chk.minTime < mint { continue }/' "$B"; run "the front filter compares minTime"
perl -0pi -e 's/                if chk\.minTime > maxt \{ continue \}/                if chk.maxTime > maxt { continue }/' "$B"; run "the back filter compares maxTime"
perl -0pi -e 's/                if chk\.maxTime < mint \{ continue \}\n/                /' "$B"; run "the front filter is gone"
perl -0pi -e 's/                if chk\.minTime > maxt \{ continue \}\n/                /' "$B"; run "the back filter is gone"

echo "=== the three skip rules ==="
perl -0pi -e 's/            if bufChks\.isEmpty \{\n                continue\n            \}//' "$B"; run "a series with no chunks is not skipped"
# ^ SURVIVES, and it is a PROOF rather than a gap — established after a corpus case was added specifically to
# close it and did not. Skip rules 2 and 3 are redundant for a chunk-less series: if `bufChks` is empty then
# the prefilter loop appends nothing, so `chks` is empty and rule 3 skips the series anyway. Rule 2 is a fast
# path that avoids the tombstone lookup and two loop passes.
#
# The corpus case (a block with two chunk-less series) is kept even so: it exercises the shape, and the
# CONTRAST matters — removing rule 3 does break, which is what says the redundancy runs in only one direction.
perl -0pi -e 's/            if chks\.isEmpty \{\n                continue\n            \}//' "$B"; run "a series whose chunks are all filtered out is not skipped"
perl -0pi -e 's/            guard let resolved else \{\n                \/\/ Go: `errors\.Is\(err, storage\.ErrNotFound\)` — "postings may be stale"\. A SKIP\.\n                continue\n            \}/            guard let resolved else { return false }/' "$B"; run "a stale postings ref stops the set"
# ^ SURVIVES: a written block has no stale refs, so `series(_:)` never returns nil here. A DECLARED corpus gap
# — closing it needs a postings list containing a ref the series section does not have, which means writing
# the index by hand rather than through `index.Writer`. That belongs with the Head (Phase 7), where stale
# postings are reachable by construction (garbage collection races the reader).

echo "=== the trimming flags ==="
perl -0pi -e 's/                if !disableTrimming \{/                if false {/' "$B"; run "trimming flags are never set"
# ^ SURVIVES: the flags only add synthetic intervals, and `SeriesData.intervals` is not observable through
# this suite's output. A DECLARED corpus gap, closed by the `populateWithDel*` slice — which is where the
# oracle already showed the difference ([100,120] with trimming off versus [120,120] with it on).
perl -0pi -e 's/                    if chk\.minTime < mint \{ trimFront = true \}/                    if chk.minTime <= mint { trimFront = true }/' "$B"; run "trimFront fires on an exact boundary"
# ^ SURVIVES, same reason.
perl -0pi -e 's/            if trimFront \{\n                intervals = intervals\.addingInterval\(\n                    DeletionInterval\(mint: Int64\.min, maxt: mint - 1\)\)\n            \}//' "$B"; run "the front trim interval is not added"
# ^ SURVIVES, same reason.
perl -0pi -e 's/                    DeletionInterval\(mint: maxt \+ 1, maxt: Int64\.max\)\)/                    DeletionInterval(mint: maxt, maxt: Int64.max))/' "$B"; run "the back trim interval starts at maxt not maxt+1"
# ^ SURVIVES, same reason. Four survivors in one group, all the same gap, all closed by one later slice — which
# is worth stating plainly rather than repeating the argument four times.

echo "=== the tombstone prefilter ==="
perl -0pi -e 's/                if DeletionInterval\(mint: chk\.minTime, maxt: chk\.maxTime\)\.isSubrange\(intervals\) \{\n                    continue\n                \}//' "$B"; run "the fully-deleted-chunk filter is gone"
# ^ SURVIVES: `tombstonesFor` always returns empty (exception 16), so `intervals` is empty before the
# synthetic ones are added and `isSubrange` is always false. DECLARED gap; unreachable until `Delete()` exists.
perl -0pi -e 's/                if DeletionInterval\(mint: chk\.minTime, maxt: chk\.maxTime\)\.isSubrange\(intervals\) \{/                if !DeletionInterval(mint: chk.minTime, maxt: chk.maxTime).isSubrange(intervals) {/' "$B"; run "the deleted-chunk filter is inverted"

echo "=== iteration and error propagation ==="
# `if postings.next() {` does not compile — the `continue`s inside lose their loop — so the first version of
# this control reported COMPILE and measured nothing. `&& current == nil` yields at most one series and keeps
# the loop intact.
perl -0pi -e 's/        while postings\.next\(\) \{/        while postings.next() \&\& current == nil {/' "$B"; run "the set yields at most one series"
perl -0pi -e 's/            let ref = postings\.at\(\)/            let ref = SeriesRef(rawValue: postings.at().rawValue + 1)/' "$B"; run "the ref is off by one"
perl -0pi -e 's/    public func err\(\) -> \(any Error\)\? \{\n        if let error \{ return error \}\n        return postings\.err\(\)\n    \}/    public func err() -> (any Error)? { nil }/' "$B"; run "Err never reports anything"
# ^ SURVIVES: no corpus case produces an error, because a written block resolves every ref. DECLARED gap; the
# erroring paths need a hand-built index, same prerequisite as the stale-ref control above.
perl -0pi -e 's/            var nChks = 0\n            for chk in bufChks where chk\.maxTime >= mint && chk\.minTime <= maxt \{\n                nChks \+= 1\n            \}\n            var chks: \[DecodedChunkMeta\] = \[\]\n            chks\.reserveCapacity\(nChks\)/            var chks: [DecodedChunkMeta] = []/' "$B"; run "(no-op control: the capacity pass is dropped)"
# ^ MUST survive. `nChks` sizes an allocation and nothing else — upstream's own comment says the count is
# "roughly - ignoring tombstones", i.e. deliberately approximate. This is the control that says the other
# SURVIVED verdicts in this sweep mean something.
