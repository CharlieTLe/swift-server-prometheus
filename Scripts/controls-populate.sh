#!/usr/bin/env bash
# Negative controls for the populate iterators.
#
# The controls this file needs were identified in §6t and are written here rather than left to memory. The
# cluster that matters is the PER-CHUNK interval rebuild (quirk 167): hoisting the list out of the loop deletes
# correctly on the first chunk and silently under-deletes on every later one, which is the failure quirk 164
# describes reached from the other side. That control needs a series with MORE THAN ONE chunk to break, which
# `block/seriesset.jsonl` has.
set -uo pipefail
cd "$(dirname "$0")/.."
P=Sources/PromBlock/PopulateIterators.swift
cp "$P" /tmp/pop.orig
restore() { cp /tmp/pop.orig "$P"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'BlockSeriesSet' 56
  restore
}

echo "=== the interval list is rebuilt PER CHUNK (quirk 167) ==="
# Hoist the list: build it once from every interval and reuse the same array across chunks. The array is a
# value type in Swift, so the visible effect is the missing overlap filter; the CONSUMPTION leak that bites Go
# needs a shared reference, which the control below reaches by reusing one DeletedIterator.
perl -0pi -e 's/        var chunkIntervals: \[DeletionInterval\] = \[\]\n        for interval in intervals\n        where overlapsClosedInterval\(meta\.minTime, meta\.maxTime, interval\.mint, interval\.maxt\) \{\n            chunkIntervals = chunkIntervals\.addingInterval\(interval\)\n        \}/        var chunkIntervals: [DeletionInterval] = []\n        for interval in intervals {\n            chunkIntervals = chunkIntervals.addingInterval(interval)\n        }/' "$P"; run "the per-chunk overlap filter is dropped"
# ^ SURVIVES, ARGUED as an optimisation (quirk 167): an interval entirely before the chunk is consumed by
# `DeletedIterator.next`'s `ts > tr.maxt` branch, one entirely after keeps the sample via `ts <= tr.maxt`, and
# the list is rebuilt per chunk so the consumption cannot leak. Same samples, more work.
#
# **The control that DOES catch the hoist is the next one**: reuse a single `DeletedIterator` across chunks, so
# the consumed list actually persists. That is the shape Go would produce if `bufIter.Intervals` were not
# reset — and it is the real content of quirk 167.
perl -0pi -e 's/            let del = DeletedIterator\(iter: it, intervals: chunkIntervals\)\n            bufIter = del/            let del = bufIter ?? DeletedIterator(iter: it, intervals: chunkIntervals)\n            del.iter = it\n            bufIter = del/' "$P"; run "one DeletedIterator is REUSED, so its list is not reset"

echo "=== currDelIter's nil-ness IS the decision ==="
perl -0pi -e 's/            if chunkIntervals\.isEmpty \{\n                \/\/ No overlap and a single chunk: take it as it is\.\n                currDelIter = nil\n                return true\n            \}//' "$P"; run "a chunk with no deletions still goes through bufIter"
# ^ Expect SURVIVED: routing an undeleted chunk through an empty-interval `DeletedIterator` yields the same
# samples. Upstream's branch avoids the wrapper, and — the part that is not merely cost —
# `populateWithDelChunkSeriesIterator` uses the nil-ness to decide whether to RE-ENCODE, so it becomes
# load-bearing in the slice that ports it. Declared, with the closing slice named.
perl -0pi -e 's/                currDelIter = nil\n                return true/                currDelIter = nil\n                return false/' "$P"; run "an undeleted chunk ends the iteration"

echo "=== the exhaustion bound and its -1 start ==="
perl -0pi -e 's/        if error != nil \|\| i >= metas\.count - 1 \{/        if error != nil || i >= metas.count {/' "$P"; run "the bound is metas.count, not count - 1"
perl -0pi -e 's/    private var i = -1/    private var i = 0/' "$P"; run "the index starts at 0 rather than -1"
perl -0pi -e 's/        if error != nil \|\| i >= metas\.count - 1 \{/        if error != nil || i > metas.count - 1 {/' "$P"; run "the bound is > count-1 rather than >= count-1"
# ^ BREAKS, and the label above it used to read "(equivalence probe)" with a comment claiming a tautology. That
# comment was wrong: `i > n-1` IS the same predicate as `i >= n`, but this control replaces `>= n-1`, which
# differs from `> n-1` at exactly `i == n-1` — one extra chunk per series. Renamed to what it is. The mistake is
# left on the record because it is the failure mode quirk 160 warns about, made in the opposite direction:
# labelling a real control a tautology would have excused a break rather than a survival.
perl -0pi -e 's/        i \+= 1\n        let meta = metas\[i\]/        let meta = metas[i]\n        i += 1/' "$P"; run "the increment happens after the read"

echo "=== Next resumes before advancing; Seek uses the exported next ==="
perl -0pi -e 's/        if let curr \{\n            let vt = curr\.next\(\)\n            if vt != \.none \{ return vt \}\n        \}\n        while generic\.next/        while generic.next/' "$P"; run "Next does not resume the current chunk"
perl -0pi -e 's/        if let curr \{\n            let vt = curr\.seek\(t\)\n            if vt != \.none \{ return vt \}\n        \}\n        while next\(\)/        while next()/' "$P"; run "Seek does not resume the current chunk"
# ^ SURVIVES, and so does the control below it, for ONE reason: **the corpus never calls `seek`.** Both the
# Go side and the port drain the sample iterator with `Next` only, so every `Seek` path in
# `PopulateWithDelSeriesIterator` is unexercised. A DECLARED corpus gap, and a precise one — closing it means
# adding a seek op-script to `block/seriesset.jsonl`'s sample pass, exactly the shape
# `block/deletediter.jsonl` already uses (`"n"` and `"sN"` ops on one iterator). That is the cheapest
# outstanding coverage win in Phase 6 and it should be taken before `blockQuerier.Select`.
perl -0pi -e 's/        while next\(\) != \.none \{\n            if let vt = curr\?\.seek\(t\), vt != \.none \{ return vt \}\n        \}/        while generic.next(copyHeadChunk: false) {\n            if let vt = curr?.seek(t), vt != .none { return vt }\n        }/' "$P"; run "Seek advances CHUNKS instead of samples"

echo "=== error handling and ordering ==="
perl -0pi -e 's/        if let e = generic\.err\(\) \{ return e \}\n        return curr\?\.err\(\)/        if let e = curr?.err() { return e }\n        return generic.err()/' "$P"; run "Err reports the chunk iterator's error first"
# ^ Expect SURVIVED: no corpus case errors, since every chunk in a written block decodes. A DECLARED gap, and
# the same one §6r left — closed by the slice that adds malformed chunk bytes to a fixture input.
perl -0pi -e 's/            guard let it = iteratorFor\(chunk\) else \{\n                self\.error = PopulateError\.neitherChunkNorIterable\(ref: meta\.ref\)\n                return false\n            \}/            let it = iteratorFor(chunk)!/' "$P"; run "an undecodable encoding traps instead of erroring"
# ^ Expect SURVIVED: every chunk here is EncXOR. Declared gap — the histogram encodings are Phase 7's, and
# until they exist no block the port writes contains anything else.
perl -0pi -e 's/            \/\/ No overlap and a single chunk: take it as it is\./            \/\/ no-op reformat/' "$P"; run "(no-op control: a comment change)"
# ^ MUST survive. The control that says the other SURVIVED verdicts in this sweep mean something.
