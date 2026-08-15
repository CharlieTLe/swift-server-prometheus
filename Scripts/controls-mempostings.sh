#!/usr/bin/env bash
# Negative controls for `index.MemPostings`.
#
# Every case passed on the first run, which the HANDOFF is explicit is when to be suspicious: "a passing
# differential test proves nothing until you have seen it fail." So the question this sweep answers is which
# of these lines the corpus can actually see.
#
# Six clusters: the `allPostingsKey` handling, `labelValues`' order and limit, `symbols`/`sortedKeys`,
# `addFor`'s one-pass repair, `ensureOrder`, and `delete`'s three cleanups.
set -uo pipefail
cd "$(dirname "$0")/.."
MP=Sources/PromIndex/MemPostings.swift
PG=Sources/PromIndex/Postings.swift
cp "$MP" /tmp/mp-mp.orig
cp "$PG" /tmp/mp-pg.orig
restore() {
  cp /tmp/mp-mp.orig "$MP"
  cp /tmp/mp-pg.orig "$PG"
}
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  if cmp -s "$MP" /tmp/mp-mp.orig && cmp -s "$PG" /tmp/mp-pg.orig
  then
    printf "  %-62s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'MemPostingsTests' 62
  restore
}

echo "=== allPostingsKey ==="
perl -0pi -e 's/public func allPostingsKey\(\) -> \(name: String, value: String\) \{ \("", ""\) \}/public func allPostingsKey() -> (name: String, value: String) { ("__all__", "") }/' "$PG"; run "allPostingsKey is a sentinel name rather than the empty pair"
perl -0pi -e 's/        addFor\(id: id, Label\(allPostingsKey\(\)\.name, allPostingsKey\(\)\.value\)\)//' "$MP"; run "add does not index under allPostingsKey"
perl -0pi -e 's/        process\(Label\(allPostingsKey\(\)\.name, allPostingsKey\(\)\.value\)\)//' "$MP"; run "delete does not process allPostingsKey"
perl -0pi -e 's/        for name in m\.keys where name != allPostingsKey\(\)\.name \{/        for name in m.keys {/' "$MP"; run "labelNames includes the empty name"

echo "=== labelValues' order and limit ==="
perl -0pi -e 's/        var values = lvs\[name\] \?\? \[\]/        var values = (lvs[name] ?? []).sorted()/' "$MP"; run "labelValues sorts before truncating"
perl -0pi -e 's/        if limit > 0 && values\.count > limit \{\n            values = Array\(values\[0\.\.<limit\]\)\n        \}//' "$MP"; run "the limit is ignored"
perl -0pi -e 's/        if limit > 0 && values\.count > limit \{/        if limit >= 0 \&\& values.count > limit {/' "$MP"; run "a zero limit truncates to nothing"
perl -0pi -e 's/            values = Array\(values\[0\.\.<limit\]\)/            values = Array(values.suffix(limit))/' "$MP"; run "the limit keeps the LAST values"
perl -0pi -e 's/        var values = lvs\[name\] \?\? \[\]/        var values = Array((m[name] ?? [:]).keys)/' "$MP"; run "labelValues reads m's keys rather than lvs"
perl -0pi -e 's/            lvs\[l\.name, default: \[\]\]\.append\(l\.value\)/            lvs[l.name, default: []].insert(l.value, at: 0)/' "$MP"; run "lvs prepends rather than appends"

echo "=== lvs's append-on-new-value rule ==="
perl -0pi -e 's/        if m\[l\.name\]!\[l\.value\] == nil \{\n            \/\/ A value seen for the first time joins `lvs` — which is what makes `lvs` insertion-ordered\.\n            lvs\[l\.name, default: \[\]\]\.append\(l\.value\)\n        \}/        lvs[l.name, default: []].append(l.value)/' "$MP"; run "lvs gains a duplicate for every add"

echo "=== symbols and sortedKeys ==="
perl -0pi -e 's/        for \(n, labelValues\) in lvs \{\n            symbols\.insert\(n\)/        for (n, labelValues) in lvs {\n            _ = n/' "$MP"; run "symbols omits the label names"
perl -0pi -e 's/            for v in labelValues \{ symbols\.insert\(v\) \}//' "$MP"; run "symbols omits the label values"
perl -0pi -e 's/        return symbols\.sorted\(\)/        return Array(symbols)/' "$MP"; run "symbols is not sorted"
perl -0pi -e 's/        keys\.sort\(\)\n        return keys/        return keys/' "$MP"; run "sortedKeys is not sorted"
perl -0pi -e 's/        for \(n, e\) in m \{\n            for v in e\.keys \{\n                keys\.append\(Label\(n, v\)\)/        for (n, e) in m {\n            for v in e.keys {\n                keys.append(Label(v, n))/' "$MP"; run "sortedKeys swaps name and value"

echo "=== addFor's one-pass repair ==="
perl -0pi -e 's/            if list\[i\]\.rawValue >= list\[i - 1\]\.rawValue \{ break \}/            if list[i].rawValue > list[i - 1].rawValue { break }/' "$MP"; run "the repair loop compares with > rather than >="
perl -0pi -e 's/        var i = list\.count - 1\n        while i >= 1 \{/        var i = list.count - 1\n        while i >= 2 {/' "$MP"; run "the repair stops one element early"
perl -0pi -e 's/            if list\[i\]\.rawValue >= list\[i - 1\]\.rawValue \{ break \}\n            list\.swapAt\(i, i - 1\)\n            i -= 1//' "$MP"; run "there is no repair at all"
perl -0pi -e 's/            if list\[i\]\.rawValue >= list\[i - 1\]\.rawValue \{ break \}\n            list\.swapAt\(i, i - 1\)\n            i -= 1\n        \}/            list.swapAt(i, i - 1)\n            i -= 1\n        }/' "$MP"; run "the repair reverses the whole list instead of stopping"
perl -0pi -e 's/        if !ordered \{ return \}/        if ordered { return }/' "$MP"; run "the ordered flag is inverted"
perl -0pi -e 's/        if !ordered \{ return \}//' "$MP"; run "an unordered MemPostings repairs on insert anyway"
perl -0pi -e 's/        var list = m\[l\.name\]!\[l\.value\]!\n        var i = list\.count - 1/        var list = m[l.name]![l.value]!.sorted { \$0.rawValue < \$1.rawValue }\n        var i = list.count - 1/' "$MP"; run "insertion sorts the whole list rather than repairing"

echo "=== ensureOrder ==="
perl -0pi -e 's/        if ordered \{ return \}\n        for \(n, e\) in m \{/        for (n, e) in m {/' "$MP"; run "ensureOrder re-sorts an already ordered index"
perl -0pi -e 's/                m\[n\]!\[v\] = list\.sorted \{ \$0\.rawValue < \$1\.rawValue \}/                m[n]![v] = list/' "$MP"; run "ensureOrder does not sort"
perl -0pi -e 's/                m\[n\]!\[v\] = list\.sorted \{ \$0\.rawValue < \$1\.rawValue \}/                m[n]![v] = list.sorted { \$0.rawValue > \$1.rawValue }/' "$MP"; run "ensureOrder sorts descending"
perl -0pi -e 's/        ordered = true\n    \}\n\n    \/\/\/ Go: `Delete`/    \}\n\n    \/\/\/ Go: `Delete`/' "$MP"; run "ensureOrder does not set the ordered flag"

echo "=== delete's three cleanups ==="
perl -0pi -e 's/            for id in orig where !deleted\.contains\(id\) \{/            for id in orig where deleted.contains(id) {/' "$MP"; run "delete keeps the deleted ids and drops the rest"
perl -0pi -e 's/            if !repl\.isEmpty \{\n                m\[l\.name\]!\[l\.value\] = repl\n            \} else \{\n                m\[l\.name\]!\.removeValue\(forKey: l\.value\)\n                affectedLabelNames\.insert\(l\.name\)\n            \}/            m[l.name]![l.value] = repl/' "$MP"; run "an emptied value keeps an empty list rather than being removed"
perl -0pi -e 's/                affectedLabelNames\.insert\(l\.name\)//' "$MP"; run "an emptied value does not mark its name for rebuild"
perl -0pi -e 's/            if \(m\[name\] \?\? \[:\]\)\.isEmpty \{\n                m\.removeValue\(forKey: name\)\n                lvs\.removeValue\(forKey: name\)\n                continue\n            \}//' "$MP"; run "a fully emptied name is not removed"
perl -0pi -e 's/                lvs\.removeValue\(forKey: name\)//' "$MP"; run "a fully emptied name is removed from m but not lvs"
perl -0pi -e 's/            lvs\[name\] = m\[name\]!\.keys\.sorted\(\)//' "$MP"; run "lvs is not rebuilt after a deletion"
perl -0pi -e 's/            guard let orig = m\[l\.name\]\?\[l\.value\] else \{ return \}/            guard let orig = m[l.name]?[l.value] else { return }\n            if orig.isEmpty { return }/' "$MP"; run "delete skips an already empty list"

echo "=== the postings readers ==="
perl -0pi -e 's/            if let list = forName\?\[value\] \{\n                res\.append\(ListPostings\(list\)\)\n            \}/            res.append(ListPostings(forName?[value] ?? []))/' "$MP"; run "postings contributes an empty list for a missing value"
perl -0pi -e 's/        for refs in \(m\[name\] \?\? \[:\]\)\.values where !refs\.isEmpty \{/        for refs in (m[name] ?? [:]).values {/' "$MP"; run "postingsForAllLabelValues does not skip empty lists"
perl -0pi -e 's/        if vals\.isEmpty \{ return emptyPostings\(\) \}/        if vals.isEmpty { return merge([]) }/' "$MP"; run "no match returns an empty merge rather than the sentinel"
perl -0pi -e 's/        let readOnlyLabelValues = lvs\[name\] \?\? \[\]/        let readOnlyLabelValues = Array((m[name] \?\? [:]).keys)/' "$MP"; run "postingsForLabelMatching matches over m's keys rather than lvs"
perl -0pi -e 's/        for v in readOnlyLabelValues where match\(v\) \{/        for v in readOnlyLabelValues where !match(v) {/' "$MP"; run "the matcher's sense is inverted"
perl -0pi -e 's/        postings\(name: allPostingsKey\(\)\.name, values: \[allPostingsKey\(\)\.value\]\)/        postingsForAllLabelValues(name: allPostingsKey().name)/' "$MP"; run "all() goes through postingsForAllLabelValues"

# ---------------------------------------------------------------------------------------------------
# 40 controls: 32 broke, 8 SURVIVED, 0 SKIP — and every survivor is a PROOF, which is unusual enough to
# be worth the space. `MemPostings` is a container, so most of its behaviour is its data structure, and
# the places where two spellings look different mostly turn out to be the same function.
#
#   * `the repair loop compares with > rather than >=` — swapping two EQUAL `SeriesRef`s is the IDENTITY.
#     `>` makes the loop walk further than `>=` does across a run of equals, but every extra swap it makes
#     is a no-op, so the resulting list is the same. `duplicate-ids` is the case that reaches it and it
#     cannot distinguish them.
#
#   * `insertion sorts the whole list rather than repairing` — a full sort and a one-pass repair agree on
#     any list whose first n-1 elements are already sorted, and that is upstream's stated invariant. It
#     holds whenever the repair runs: an ORDERED index maintains it inductively, and an UNORDERED one
#     skips the repair entirely until `ensureOrder` sorts. There is no public path to a list that violates
#     it while `ordered` is true.
#
#   * `ensureOrder re-sorts an already ordered index` — sorting a sorted list is the identity. The
#     `if ordered { return }` guard is a performance short-circuit, nothing more.
#
#   * `delete skips an already empty list` and `postingsForAllLabelValues does not skip empty lists` — the
#     SAME invariant, and it is worth naming: **an empty postings list never exists in `m`.** `delete`
#     removes a value whose list empties rather than storing `[]`, so neither an `orig.isEmpty` early
#     return nor a `!refs.isEmpty` filter can ever fire. Upstream's filter exists because its lock can be
#     released mid-`Delete` and a reader can see the intermediate state; the port has no lock, so the
#     window does not exist. Re-run both if a lock ever lands.
#
#   * `no match returns an empty merge rather than the sentinel` — `merge([])` already RETURNS
#     `emptyPostings()`, the same singleton, so the two spellings produce the identical object and
#     `isEmptyPostingsType` cannot tell them apart. Upstream's explicit `EmptyPostings()` is a
#     short-circuit that skips building the `lps` slice.
#
#   * `postingsForLabelMatching matches over m's keys rather than lvs` — `lvs[name]` and `m[name]`'s keys
#     hold the SAME set: `addFor` appends to `lvs` exactly when it creates the value in `m`, and `delete`
#     rebuilds `lvs` from `m`'s keys. Only the ORDER differs, and the result goes through `merge`, which
#     sorts. Upstream reads `lvs` to avoid holding the mutex across a potentially-huge regex, which is a
#     concurrency concern the port does not have.
#
#   * `all() goes through postingsForAllLabelValues` — `m[""]` has exactly one value, `""`, so merging
#     "the list for value ''" and "every list under name ''" are the same list. This one is conditional
#     rather than absolute: a label whose NAME is empty and whose value is not would give `m[""]` a second
#     entry and separate them. Prometheus does not admit such a label (`Labels` rejects an empty name), so
#     it is unreachable — but it is the one survivor here resting on a neighbouring type's guarantee
#     rather than on this file, which is quirk 65's shape.
