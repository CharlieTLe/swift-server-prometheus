#!/usr/bin/env bash
# Negative controls for `PostingsForMatchers` and the index reader's predicate walk.
#
# This is the densest reasoning in `tsdb/querier.go`, and almost all of it is about ONE distinction: a
# matcher that can match the empty string means something different from one that cannot, because the index
# only records series that HAVE a label. So the controls are grouped by the four places that distinction is
# spent — `labelMustBeSet`, the `.*`/`.+` special cases, the isNot/matchesEmpty quadrants, and the
# short-circuits — plus the traversal underneath.
#
# Every control here is checked by BOTH corpora: `index/pfm.jsonl` (72 queries against Go's own answers on
# Go's own index files) and `index/reader.jsonl` (61 predicate queries). The filter runs both.
set -uo pipefail
cd "$(dirname "$0")/.."
P=Sources/PromBlock/PostingsForMatchers.swift
R=Sources/PromIndex/IndexReader.swift
cp "$P" /tmp/pfm.orig && cp "$R" /tmp/pfmr.orig
restore() { cp /tmp/pfm.orig "$P"; cp /tmp/pfmr.orig "$R"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'PostingsForMatchers|IndexReader' 56
  restore
}

echo "=== labelMustBeSet — the per-NAME fact ==="
perl -0pi -e 's/    for m in ms where !m\.matches\(""\) \{\n        labelMustBeSet\[m\.name\] = true\n    \}//' "$P"; run "labelMustBeSet is never populated"
perl -0pi -e 's/    for m in ms where !m\.matches\(""\) \{/    for m in ms where m.matches("") {/' "$P"; run "labelMustBeSet is inverted"
# Keyed by the matcher rather than the name, which breaks the `{l=~".", l!="1"}` optimisation while leaving
# every single-matcher query right — the exact shape a hand-written test would miss.
perl -0pi -e 's/        labelMustBeSet\[m\.name\] = true/        labelMustBeSet[m.name + m.value] = true/' "$P"; run "labelMustBeSet is keyed per MATCHER, not per name"
perl -0pi -e 's/        if labelMustBeSet\[m\.name\] != true \{\n            return true\n        \}//' "$P"; run "isSubtractingMatcher ignores labelMustBeSet"
perl -0pi -e 's/        return \(m\.type == \.notEqual \|\| m\.type == \.notRegexp\) && m\.matches\(""\)/        return m.type == .notEqual || m.type == .notRegexp/' "$P"; run "isSubtractingMatcher drops the matchesEmpty test"
# ^ SURVIVES, ARGUED, and it is the SAME proof as the two base controls below. `isSubtractingMatcher` does
# not decide any branch of the main loop — that switches on `labelMustBeSet[m.name]` — so it can only affect
# (a) whether the all-postings base is added and (b) the partition order. Dropping the `matchesEmpty` test
# turns `{l!=""}` into an only-subtracting query, which adds `allPostings` to `its`; since `allPostings` is a
# SUPERSET of every other postings list, intersecting with it cannot change the answer. Cost, not
# correctness — and the concurrency argument in the file header is why upstream still avoids it.
perl -0pi -e 's/        if labelMustBeSet\[m\.name\] == true \{/        if labelMustBeSet[m.name] != true {/' "$P"; run "the main loop's labelMustBeSet branch is inverted"

echo "=== the all-postings base, and the partition ==="
perl -0pi -e 's/    if hasSubtractingMatchers && !hasIntersectingMatchers \{/    if false {/' "$P"; run "an only-subtracting query gets no base"
perl -0pi -e 's/    if hasSubtractingMatchers && !hasIntersectingMatchers \{/    if hasSubtractingMatchers {/' "$P"; run "the base is added whenever anything subtracts"
# ^ SURVIVES, ARGUED as above: an extra `allPostings` member in `its` is a superset intersection and
# therefore a no-op on a static index. Note the OTHER direction broke — removing the base entirely is a
# genuine bug, because then an only-subtracting query has nothing to subtract from.
perl -0pi -e 's/    let sorted = ms\.filter \{ !isSubtractingMatcher\(\$0\) \} \+ ms\.filter \{ isSubtractingMatcher\(\$0\) \}/    let sorted = ms/' "$P"; run "the matchers are not partitioned at all"
# ^ SURVIVES, ARGUED, and the argument is the reason the corpus has order-permuted cases. On a STATIC index
# file the partition cannot change the result: `its` is intersected and `notIts` subtracted after the loop,
# and both are order-insensitive. Upstream's own comment says the sort is about a CONCURRENT appender adding
# series between two `ix.Postings` calls — a race this port cannot stage, because `PostingsIndex` here reads
# an immutable byte array. It is kept because the Head (Phase 7) is mutable and will make it load-bearing,
# and because a reader diffing the two files should not have to rediscover why one is missing.
perl -0pi -e 's/    let sorted = ms\.filter \{ !isSubtractingMatcher\(\$0\) \} \+ ms\.filter \{ isSubtractingMatcher\(\$0\) \}/    let sorted = ms.filter { isSubtractingMatcher(\$0) } + ms.filter { !isSubtractingMatcher(\$0) }/' "$P"; run "the partition is REVERSED (subtracting first)"
# ^ SURVIVES, for the same proof. Listed separately because "reversed" is the mistake a reader would make,
# and it is worth having both directions on the record as unobservable-here rather than only one.

echo "=== the four .* / .+ cases, which are not symmetric ==="
perl -0pi -e 's/        if m\.type == \.regexp && m\.value == "\.\*" \{\n            \/\/ Matches any string, including the empty one: contributes NO constraint\. Not the same as\n            \/\/ intersecting with everything — see the file header\.\n            continue\n        \}//' "$P"; run "l=~\".*\" is not special-cased"
# ^ SURVIVES, ARGUED — and this one was checked rather than reasoned about, because the reasoning is exactly
# the kind that is wrong half the time. Falling through, `l=~".*"` lands in one of two places: if nothing
# makes the name required it becomes `notIts.append(inverse(.*))`, and the inverse of `.*` matches NOTHING,
# so it is an empty subtraction; if the name IS required it becomes an intersection with "every series having
# the label", which every other matcher on a required name already implies. Both are no-ops.
#
# The corpus was WIDENED for this survivor: ten `.*`-plus-same-name queries were added covering all four
# quadrants of `labelMustBeSet` x isNot (`{l=~".*", l="a"}`, `{l=~".*", l!=""}`, `{l=~".*", l=""}`, …). It
# still survives against them, so the equivalence is evidence-backed. Kept anyway: relying on that
# composition is fragile, and upstream's `continue` says the intent outright.
perl -0pi -e 's/        if m\.type == \.notRegexp && m\.value == "\.\*" \{\n            return emptyPostings\(\)\n        \}//' "$P"; run "l!~\".*\" does not return empty"
# ^ SURVIVES, ARGUED as a different path to the same answer. `l!~".*"` does not match the empty string, so
# the name becomes required and the matcher takes the `isNot && !matchesEmpty` branch:
# `inversePostingsForMatcher(l=~".*")` walks the values with `!m.matches(v)`, which is false for every value,
# yielding empty — and the branch's own `isEmptyPostingsType` check then returns empty. Upstream's early
# return skips a whole traversal to reach the same place.
perl -0pi -e 's/        if m\.type == \.regexp && m\.value == "\.\+" \{/        if m.type == .regexp && m.value == ".*" {/' "$P"; run "the .+ intersecting case triggers on .*"
perl -0pi -e 's/            notIts\.append\(try ix\.postingsForAllLabelValues\(name: m\.name\)\)\n            continue//' "$P"; run "l!~\".+\" does not subtract"
perl -0pi -e 's/            let it = try ix\.postingsForAllLabelValues\(name: m\.name\)\n            if isEmptyPostingsType\(it\) \{\n                return emptyPostings\(\)\n            \}\n            its\.append\(it\)/            its.append(try ix.postingsForAllLabelValues(name: m.name))/' "$P"; run "l=~\".+\" does not short-circuit on empty"
# ^ SURVIVES, ARGUED: `intersect()` with an empty member yields empty anyway (its own short-circuit,
# pinned by `controls-postings.sh`), so the early return saves work rather than changing the answer.
# Upstream has it because building the remaining iterators is wasted; kept for that shape.

echo "=== the isNot / matchesEmpty quadrants ==="
perl -0pi -e 's/            if isNot && matchesEmpty \{/            if isNot \&\& !matchesEmpty {/' "$P"; run "the two isNot quadrants are swapped"
perl -0pi -e 's/                let it = try postingsForMatcher\(ix, m\.inverse\(\)\)\n                notIts\.append\(it\)/                notIts.append(try postingsForMatcher(ix, m))/' "$P"; run "l!=\"foo\" subtracts WITHOUT inverting"
perl -0pi -e 's/                let it = try inversePostingsForMatcher\(ix, m\.inverse\(\)\)/                let it = try postingsForMatcher(ix, m.inverse())/' "$P"; run "l!=\"\" uses postingsForMatcher not the inverse"
perl -0pi -e 's/            notIts\.append\(try inversePostingsForMatcher\(ix, m\)\)/            its.append(try inversePostingsForMatcher(ix, m))/' "$P"; run "l=\"\" INTERSECTS instead of subtracting"
perl -0pi -e 's/            notIts\.append\(try inversePostingsForMatcher\(ix, m\)\)/            notIts.append(try postingsForMatcher(ix, m))/' "$P"; run "l=\"\" does not use the inverse walk (issue 3575)"

echo "=== the final combination ==="
perl -0pi -e 's/    var it = intersect\(its\)/    var it = merge(its)/' "$P"; run "the intersecting matchers are MERGED not intersected"
perl -0pi -e 's/    for n in notIts \{\n        it = without\(it, n\)\n    \}//' "$P"; run "the subtractions are never applied"
perl -0pi -e 's/        it = without\(it, n\)/        it = without(n, it)/' "$P"; run "without's arguments are swapped"

echo "=== postingsForMatcher / inversePostingsForMatcher ==="
perl -0pi -e 's/    if m\.type == \.equal \{\n        return try ix\.postings\(name: m\.name, values: \[m\.value\]\)\n    \}//' "$P"; run "the equality fast path is gone"
# ^ SURVIVES, ARGUED as pure cost: the fallback `postingsForLabelMatching(name, { m.matches($0) })` calls an
# equality matcher against every value of the name and keeps the one that matches — the same postings list
# the direct lookup returns, after a full traversal instead of a binary search. This is the single biggest
# performance branch in the function and the corpus cannot see it, which is worth knowing before someone
# "simplifies" it.
# ^ expected to SURVIVE: the fallback predicate walk gives the same set, more slowly.
perl -0pi -e 's/        let setMatches = m\.setMatches\n        if !setMatches\.isEmpty \{\n            return try ix\.postings\(name: m\.name, values: setMatches\)\n        \}\n    \}\n    return try ix\.postingsForLabelMatching\(name: m\.name, match: \{ m\.matches\(\$0\) \}\)/        let setMatches = m.setMatches\n        if !setMatches.isEmpty {\n            return try ix.postings(name: m.name, values: setMatches)\n        }\n    }\n    return try ix.postingsForLabelMatching(name: m.name, match: { !m.matches(\$0) })/' "$P"; run "postingsForMatcher's predicate is negated"
perl -0pi -e 's/    if m\.value\.isEmpty && \(m\.type == \.regexp \|\| m\.type == \.equal\) \{\n        return try ix\.postingsForAllLabelValues\(name: m\.name\)\n    \}//' "$P"; run "inverting =~\"\" walks a predicate instead of taking all values"
perl -0pi -e 's/    return try ix\.postingsForLabelMatching\(name: m\.name, match: \{ !m\.matches\(\$0\) \}\)/    return try ix.postingsForLabelMatching(name: m.name, match: { m.matches(\$0) })/' "$P"; run "the inverse walk's predicate is not negated"
perl -0pi -e 's/    if m\.type == \.notRegexp \{\n        let setMatches = m\.setMatches\n        if !setMatches\.isEmpty \{\n            return try ix\.postings\(name: m\.name, values: setMatches\)\n        \}\n    \}\n    if m\.type == \.notEqual \{/    if m.type == .notEqual {/' "$P"; run "the inverse's notRegexp set fast path is gone"
# ^ SURVIVES, ARGUED as cost again, and the double negation is why: for a `!~` matcher, `m.matches(v)` is
# true exactly when `v` is NOT in the set, so the fallback's `!m.matches(v)` keeps exactly the set members —
# the same list `postings(name, setMatches...)` returns. Every set-matching branch in this file has this
# property, which is the general shape of the survivors here: upstream's fast paths are reachable by the
# slow path, so a corpus can pin the ANSWER but never the plan.

echo "=== the predicate walk underneath (index reader) ==="
perl -0pi -e 's/        return val != lastVal/        return true/' "$R"; run "the traversal has no stop sentinel"
perl -0pi -e 's/        return val != lastVal/        return false/' "$R"; run "the traversal stops after the first value"
perl -0pi -e 's/        if match == nil \|\| match!\(val\) \{/        if match != nil \&\& match!(val) {/' "$R"; run "a nil predicate matches nothing"
perl -0pi -e 's/        if match == nil \|\| match!\(val\) \{/        if match == nil \|\| !match!(val) {/' "$R"; run "the predicate's sense is inverted"
perl -0pi -e 's/    let lastVal = e\[e\.count - 1\]\.value/    let lastVal = e[0].value/' "$R"; run "lastVal comes from the FIRST sparse entry"
perl -0pi -e 's/    guard let e = sparse\[name\], !e\.isEmpty else \{\n        return emptyPostings\(\)\n    \}/    guard let e = sparse[name], !e.isEmpty else { return emptyPostings() }\n    _ = e/' "$R"; run "(no-op control: the harness must report SURVIVED here)"
# ^ A DELIBERATE no-op — reformatting with no behaviour change. It must report SURVIVED, and it is here
# because a sweep in which everything breaks is indistinguishable from a sweep whose build is broken. This
# is the control that says the other SURVIVED verdicts mean something.
perl -0pi -e 's/    return merge\(its\)\n\}\n\n\/\/ MARK: - Label values/    return intersect(its)\n}\n\n\/\/ MARK: - Label values/' "$R"; run "the matching postings are INTERSECTED not merged"
