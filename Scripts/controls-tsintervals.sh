#!/usr/bin/env bash
# Negative controls for the deletion-interval arithmetic.
#
# Small surface, but it is on the hot path of every range query against a block — `blockBaseSeriesSet.Next`
# trims by ADDING intervals — so the perturbations that matter are the off-by-ones in the adjacency bounds and
# the two overflow guards, which are the trimming case rather than an edge case.
#
# Two of these are expected to TRAP rather than fail: removing an overflow guard makes Swift evaluate
# `Int64.min - 1`, which traps where Go wraps. The shared harness reports that as `broke (trapped)` — and that
# distinction is the reason the verdict rules were unified (see `lib/control-run.sh`), since a grep for ✘
# alone would have read a trap as SURVIVED.
set -uo pipefail
cd "$(dirname "$0")/.."
D=Sources/PromBlock/DeletionIntervals.swift
cp "$D" /tmp/di.orig
restore() { cp /tmp/di.orig "$D"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'DeletionInterval' 56
  restore
}

echo "=== adjacency: the two off-by-ones that decide whether neighbours merge ==="
perl -0pi -e 's/`in`\[\$0\]\.maxt >= n\.mint - 1/`in`[\$0].maxt >= n.mint/' "$D"; run "the lower bound does not merge adjacent intervals"
perl -0pi -e 's/`in`\[\$0\]\.maxt >= n\.mint - 1/`in`[\$0].maxt >= n.mint - 2/' "$D"; run "the lower bound merges across a one-element gap"
perl -0pi -e 's/`in`\[mini \+ \$0\]\.mint > n\.maxt \+ 1/`in`[mini + \$0].mint > n.maxt/' "$D"; run "the upper bound does not merge adjacent intervals"
perl -0pi -e 's/`in`\[mini \+ \$0\]\.mint > n\.maxt \+ 1/`in`[mini + \$0].mint >= n.maxt + 1/' "$D"; run "the upper bound is >= not >"
perl -0pi -e 's/`in`\[\$0\]\.maxt >= n\.mint - 1/`in`[\$0].mint >= n.mint - 1/' "$D"; run "the lower search compares mint instead of maxt"

echo "=== the overflow guards, which ARE the trimming path ==="
perl -0pi -e 's/        if n\.mint != Int64\.min \{  \/\/ Avoid overflow — and in Swift, avoid a TRAP\. See the file header\./        if true {/' "$D"; run "the MinInt64 guard is gone (Swift traps)"
perl -0pi -e 's/        if n\.maxt != Int64\.max \{/        if true {/' "$D"; run "the MaxInt64 guard is gone (Swift traps)"
perl -0pi -e 's/        if n\.mint != Int64\.min \{  \/\/ Avoid overflow — and in Swift, avoid a TRAP\. See the file header\./        if false {/' "$D"; run "the lower search is ALWAYS skipped"
perl -0pi -e 's/        if n\.maxt != Int64\.max \{/        if false {/' "$D"; run "the upper search is ALWAYS skipped"

echo "=== the asymmetric searches: maxi is RELATIVE to mini ==="
perl -0pi -e 's/        maxi = goSearch\(`in`\.count - mini\) \{ `in`\[mini \+ \$0\]\.mint > n\.maxt \+ 1 \}/        maxi = goSearch(`in`.count) { `in`[\$0].mint > n.maxt + 1 }/' "$D"; run "the upper search is over the WHOLE array (maxi absolute)"
perl -0pi -e 's/        `in`\[mini\]\.maxt = Swift\.max\(n\.maxt, `in`\[maxi \+ mini - 1\]\.maxt\)/        `in`[mini].maxt = Swift.max(n.maxt, `in`[maxi - 1].maxt)/' "$D"; run "the merged maxt reads maxi - 1, not maxi + mini - 1"
perl -0pi -e 's/        return Array\(`in`\[0\.\.\.mini\]\) \+ Array\(`in`\[\(maxi \+ mini\)\.\.\.\]\)/        return Array(`in`[0...mini]) + Array(`in`[maxi...])/' "$D"; run "the tail is spliced from maxi, not maxi + mini"
perl -0pi -e 's/        `in`\[mini\]\.maxt = Swift\.max\(n\.maxt, `in`\[maxi \+ mini - 1\]\.maxt\)/        `in`[mini].maxt = n.maxt/' "$D"; run "the merged maxt ignores the swallowed intervals"

echo "=== the insertion cases ==="
# The `mini == 0` insertion, made to append instead of prepend. An INERT control sat here first — its perl
# never matched, so it reported SURVIVED while testing nothing, which is the failure mode a sweep must not
# have. If a control survives, check that its patch applied before reasoning about why.
perl -0pi -e 's/                if mini == 0 \{\n                    return \[n\] \+ `in`\n                \}/                if mini == 0 {\n                    return `in` + [n]\n                }/' "$D"; run "the mini == 0 insertion APPENDS instead of prepending"
perl -0pi -e 's/            if maxi == 0 \{/            if maxi == -1 {/' "$D"; run "the maxi == 0 insertion never fires"
perl -0pi -e 's/            if mini == `in`\.count \{\n                return `in` \+ \[n\]\n            \}//' "$D"; run "the past-the-end append is gone"
perl -0pi -e 's/        if `in`\.isEmpty \{\n            return \[n\]\n        \}//' "$D"; run "the empty-receiver case is gone"
perl -0pi -e 's/        if n\.mint < `in`\[mini\]\.mint \{\n            `in`\[mini\]\.mint = n\.mint\n        \}//' "$D"; run "the merged mint is never lowered"

echo "=== IsSubrange and InBounds ==="
perl -0pi -e 's/        for r in dranges where r\.inBounds\(mint\) && r\.inBounds\(maxt\) \{/        for r in dranges where r.inBounds(mint) \|\| r.inBounds(maxt) {/' "$D"; run "IsSubrange accepts a partial overlap"
perl -0pi -e 's/        t >= mint && t <= maxt/        t > mint \&\& t < maxt/' "$D"; run "InBounds is open rather than closed"
perl -0pi -e 's/        t >= mint && t <= maxt/        t >= mint \&\& t < maxt/' "$D"; run "InBounds is half-open"

echo "=== sort.Search's boundary behaviour ==="
perl -0pi -e 's/        if !f\(h\) \{\n            i = h \+ 1\n        \} else \{\n            j = h\n        \}/        if f(h) {\n            i = h + 1\n        } else {\n            j = h\n        }/' "$D"; run "goSearch's predicate sense is inverted"
perl -0pi -e 's/            i = h \+ 1/            i = h/' "$D"; run "goSearch does not advance past h"
# ^ Expected to break by HANGING: `i = h` with `h == i` makes no progress.
perl -0pi -e 's/        let h = Int\(UInt\(i \+ j\) >> 1\)/        let h = (i + j) \/ 2/' "$D"; run "(no-op control: the midpoint without the overflow trick)"
