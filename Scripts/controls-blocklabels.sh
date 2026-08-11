#!/usr/bin/env bash
# Negative controls for `labelValuesWithMatchers`, `labelNamesWithMatchers` and the `blockIndexReader`
# dispatch above them.
#
# The corpus behind these is generated through `tsdb.OpenBlock` and `tsdb.NewBlockQuerier` — a real block,
# real upstream code paths — because both functions are unexported and the only other way in would be an
# oracle-side reimplementation of `blockIndexReader`. See `oracle/blockfixture.go`.
#
# One control in here is a TAUTOLOGY and is marked as such, kept as a worked example of the trap quirk 159
# describes from the other side: not every survivor is a corpus gap. "Stop appending at k" and "append all
# then take the first k" are the same operation on the same sequence, so a control comparing them can never
# break, and reading its survival as a gap would send someone looking for a case that cannot exist. The
# distinction is whether the perturbation changes the FUNCTION or only its spelling.
set -uo pipefail
cd "$(dirname "$0")/.."
B=Sources/PromBlock/BlockLabelQueries.swift
cp "$B" /tmp/blq.orig
restore() { cp /tmp/blq.orig "$B"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'BlockLabelQuery' 56
  restore
}

echo "=== the dispatch: matchers or no matchers ==="
perl -0pi -e 's/    if matchers\.isEmpty \{\n        var values = try ix\.labelValues\(name: name\)/    if false {\n        var values = try ix.labelValues(name: name)/' "$B"; run "the no-matcher path always goes through the filter"
# ^ SURVIVES, ARGUED as a PROOF: `labelValuesWithMatchers` with an EMPTY matcher list does exactly what the
# dispatch's other arm does. The filter loop body never runs, so `allValues` is untouched;
# `hasMatchersForOtherLabels` stays false, so it returns the values with the limit truncating them. Identical
# function, one extra call frame.
#
# Upstream's dispatch is not pointless, though, and the reason is a level down: `ir.LabelValues(ctx, name,
# hints)` pushes the limit INTO the index reader, which checks it before appending, while
# `labelValuesWithMatchers` calls `r.LabelValues(ctx, name, nil)` and truncates afterwards. Same answer, but
# the first stops reading the postings offset table early. On a label with a million values that is the
# difference the branch exists for.
perl -0pi -e 's/    return try labelValuesWithMatchers\(ix, name: name, limit: limit, matchers: matchers\)\n\}/    return try ix.labelValues(name: name)\n}/' "$B"; run "matchers are IGNORED for label values"
perl -0pi -e 's/    var res = matchers\.isEmpty \? try ix\.labelNames\(\) : try labelNamesWithMatchers\(ix, matchers: matchers\)/    var res = try ix.labelNames()/' "$B"; run "matchers are IGNORED for label names"
perl -0pi -e 's/    var st = try blockLabelValues\(ix, name: name, limit: limit, matchers: matchers\)\n    st\.sort \{ goStringLessBytes\(\$0, \$1\) \}\n    return st/    return try blockLabelValues(ix, name: name, limit: limit, matchers: matchers)/' "$B"; run "SortedLabelValues does not sort"
perl -0pi -e 's/        return try blockLabelValues\(ix, name: name, limit: limit\)\n    \}/        var v = try blockLabelValues(ix, name: name, limit: limit)\n        v.reverse()\n        return v\n    }/' "$B"; run "the no-matcher sorted path reverses"

echo "=== the queried name's own matchers prune first ==="
perl -0pi -e 's/        if m\.name != name \{\n            hasMatchersForOtherLabels = true\n            continue\n        \}/        if m.name != name {\n            hasMatchersForOtherLabels = true\n        }/' "$B"; run "an other-label matcher ALSO filters the values"
perl -0pi -e 's/        if m\.name != name \{/        if m.name == name {/' "$B"; run "the name comparison is inverted"
perl -0pi -e 's/        allValues = allValues\.filter \{ m\.matches\(\$0\) \}/        allValues = allValues.filter { !m.matches(\$0) }/' "$B"; run "the value filter is negated"
perl -0pi -e 's/            hasMatchersForOtherLabels = true\n            continue/            continue/' "$B"; run "hasMatchersForOtherLabels is never set"
perl -0pi -e 's/    var hasMatchersForOtherLabels = false/    var hasMatchersForOtherLabels = true/' "$B"; run "hasMatchersForOtherLabels is always true"

echo "=== the early return, and the no-postings return ==="
perl -0pi -e 's/    if allValues\.isEmpty \{\n        \/\/ EARLY, before `PostingsForMatchers`\. See the file header\.\n        return \[\]\n    \}//' "$B"; run "the empty-values early return is gone"
# ^ Expected to SURVIVE on values: with no values there are no candidate postings, so
# `findIntersectingPostings` returns nothing and the answer is the same empty list. Upstream's early return
# saves a `PostingsForMatchers` call — and, less obviously, means a broken postings layer cannot turn an
# already-empty answer into an ERROR. That second half is why it is not merely an optimisation.
perl -0pi -e 's/    if !hasMatchersForOtherLabels \{/    if false {/' "$B"; run "the filtered values always go through postings"
perl -0pi -e 's/    if !hasMatchersForOtherLabels \{/    if true {/' "$B"; run "postings are never consulted"

echo "=== the limit, and the order it acts over ==="
perl -0pi -e 's/    for idx in indexes \{/    for idx in indexes.sorted() {/' "$B"; run "the collected values are taken in SORTED index order"
perl -0pi -e 's/        values\.append\(allValues\[idx\]\)\n        if limit > 0 && values\.count >= limit \{\n            break\n        \}/        values.append(allValues[idx])/' "$B"; perl -0pi -e 's/    return values\n\}/    if limit > 0 \&\& values.count > limit { return Array(values[0..<limit]) }\n    return values\n}/' "$B"; run "(tautology: stop-at-k vs take-first-k)"
# ^ SURVIVES, and it CANNOT break: appending until `count >= limit` and appending everything then slicing to
# `limit` select the same prefix of the same sequence. Kept as the worked example this file's header
# describes — a survivor whose perturbation changed the spelling and not the function. Contrast the control
# directly above, which changes the ORDER and does break.
perl -0pi -e 's/        if limit > 0 && values\.count >= limit \{/        if limit > 0 \&\& values.count > limit {/' "$B"; run "the collecting limit is off by one"
perl -0pi -e 's/        if limit > 0 && allValues\.count > limit \{\n            return Array\(allValues\[0\.\.<limit\]\)\n        \}//' "$B"; run "the truncating limit is not applied"
perl -0pi -e 's/    if limit > 0 && res\.count > limit \{\n        res = Array\(res\[0\.\.<limit\]\)\n    \}//' "$B"; run "LabelNames ignores its limit"
perl -0pi -e 's/        if limit > 0 && values\.count > limit \{\n            return Array\(values\[0\.\.<limit\]\)\n        \}//' "$B"; run "(no-op control: a branch that does not exist)"

echo "=== labelNamesWithMatchers ==="
perl -0pi -e 's/    let p = try postingsForMatchers\(ix, matchers\)\n    return try ix\.labelNamesFor\(p\)/    return try ix.labelNames()/' "$B"; run "LabelNamesFor is replaced by all names"
perl -0pi -e 's/    return try ix\.labelNamesFor\(p\)/    return try ix.labelNamesFor(emptyPostings())/' "$B"; run "LabelNamesFor is given empty postings"
