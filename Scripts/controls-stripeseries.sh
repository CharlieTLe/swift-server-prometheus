#!/usr/bin/env bash
# Negative controls for the Head's series index — `seriesHashmap` and `stripeSeries`.
#
# Not differential (nothing exported reaches these until §7g), but the expectations came from a Go probe of
# `seriesHashmap`'s three methods lifted verbatim — see the test file header. This sweep asks the separate
# question: can the tests SEE each line?
#
# Three clusters: `get`'s fall-through, `set`'s first-writer rule, and `del`'s three cases — plus the two
# shardings.
set -uo pipefail
cd "$(dirname "$0")/.."
SS=Sources/PromHead/StripeSeries.swift
cp "$SS" /tmp/ss-ss.orig
restore() { cp /tmp/ss-ss.orig "$SS"; }
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

run() {
  if cmp -s "$SS" /tmp/ss-ss.orig
  then
    printf "  %-62s SKIP (patch did not apply)\n" "$1"
    restore
    return
  fi
  control_verdict "$1" 'StripeSeriesTests' 62
  restore
}

echo "=== get's fall-through ==="
perl -0pi -e 's/        if let s = unique\[hash\], s\.labels\(\) == lset \{\n            return s\n        \}/        if let s = unique[hash] { return s }/' "$SS"; run "get trusts the unique slot without comparing labels"
perl -0pi -e 's/        for s in conflicts\?\[hash\] \?\? \[\] where s\.labels\(\) == lset \{\n            return s\n        \}//' "$SS"; run "get never looks in conflicts"
perl -0pi -e 's/        for s in conflicts\?\[hash\] \?\? \[\] where s\.labels\(\) == lset \{/        for s in conflicts?[hash] ?? [] where s.labels() != lset {/' "$SS"; run "get's conflict comparison is inverted"

echo "=== set's first-writer rule ==="
perl -0pi -e 's/            if existing\.labels\(\) == s\.labels\(\) \{\n                unique\[hash\] = s\n                return\n            \}/            unique[hash] = s\n            return/' "$SS"; run "set always overwrites the unique slot"
perl -0pi -e 's/            if existing\.labels\(\) == s\.labels\(\) \{/            if existing.labels() != s.labels() {/' "$SS"; run "set's unique-slot label test is inverted"
perl -0pi -e 's/        for i in l\.indices where l\[i\]\.labels\(\) == s\.labels\(\) \{\n            l\[i\] = s\n            conflicts!\[hash\] = l\n            return\n        \}//' "$SS"; run "set appends a duplicate instead of replacing in place"
perl -0pi -e 's/        for i in l\.indices where l\[i\]\.labels\(\) == s\.labels\(\) \{\n            l\[i\] = s\n            conflicts!\[hash\] = l\n            return\n        \}\n        l\.append\(s\)/        for i in l.indices where l[i].labels() == s.labels() {\n            l[i] = s\n            conflicts![hash] = l\n            return\n        }\n        l.insert(s, at: 0)/' "$SS"; run "set prepends to conflicts rather than appending"
perl -0pi -e 's/            l\[i\] = s\n            conflicts!\[hash\] = l\n            return/            conflicts![hash] = l\n            return/' "$SS"; run "set's in-place replacement is not written back"

echo "=== del's three cases ==="
perl -0pi -e 's/        guard let uniqueSeries = unique\[hash\] else \{\n            \/\/ The hash is not stored at all\.\n            return\n        \}/        guard let uniqueSeries = unique[hash] else {\n            conflicts?.removeValue(forKey: hash)\n            return\n        }/' "$SS"; run "del on an unknown hash still clears the conflicts"
perl -0pi -e 's/        if uniqueSeries\.ref == ref \{/        if uniqueSeries.ref != ref {/' "$SS"; run "del's unique-holder test is inverted"
perl -0pi -e 's/            unique\[hash\] = c\[0\]  \/\/ First remaining series goes in `unique`\.\n            rem = Array\(c\.dropFirst\(\)\)  \/\/ Keep the rest\./            unique.removeValue(forKey: hash)\n            rem = c/' "$SS"; run "del clears the unique slot instead of promoting a conflict"
perl -0pi -e 's/            unique\[hash\] = c\[0\]  \/\/ First remaining series goes in `unique`\.\n            rem = Array\(c\.dropFirst\(\)\)/            unique[hash] = c[c.count - 1]\n            rem = Array(c.dropLast())/' "$SS"; run "del promotes the LAST conflict rather than the first"
perl -0pi -e 's/            unique\[hash\] = c\[0\]  \/\/ First remaining series goes in `unique`\.\n            rem = Array\(c\.dropFirst\(\)\)/            unique[hash] = c[0]\n            rem = c/' "$SS"; run "del promotes a conflict but also keeps it in the list"
perl -0pi -e 's/            if c\.isEmpty \{\n                \/\/ Exactly one series with this hash was stored\.\n                unique\.removeValue\(forKey: hash\)\n                return\n            \}//' "$SS"; run "del does not handle a unique entry with no conflicts"
perl -0pi -e 's/            for s in conflicts\?\[hash\] \?\? \[\] where s\.ref != ref \{/            for s in conflicts?[hash] ?? [] where s.ref == ref {/' "$SS"; run "del keeps the matching conflict and drops the rest"
perl -0pi -e 's/            for s in conflicts\?\[hash\] \?\? \[\] where s\.ref != ref \{\n                rem\.append\(s\)\n            \}//' "$SS"; run "del drops every conflict regardless of ref"
perl -0pi -e 's/        if rem\.isEmpty \{\n            conflicts\?\.removeValue\(forKey: hash\)\n        \} else \{/        if false {\n            conflicts?.removeValue(forKey: hash)\n        } else {/' "$SS"; run "an emptied conflict list is stored rather than removed"
perl -0pi -e 's/        var rem: \[MemSeries\] = \[\]\n        guard let uniqueSeries = unique\[hash\]/        var rem: [MemSeries] = []\n        _ = rem\n        guard let uniqueSeries = unique[hash]/' "$SS"; run "harness check: a no-op perturbation is reported as surviving"

echo "=== the two shardings ==="
perl -0pi -e 's/        Int\(ref\.rawValue & UInt64\(size - 1\)\)/        Int(ref.rawValue % UInt64(size))/' "$SS"; run "refStripe uses a modulo rather than a mask"
perl -0pi -e 's/        Int\(hash & UInt64\(size - 1\)\)/        Int(hash \/ UInt64(size))/' "$SS"; run "hashStripe divides rather than masking"
perl -0pi -e 's/    func hashStripe\(_ hash: UInt64\) -> Int \{\n        Int\(hash & UInt64\(size - 1\)\)/    func hashStripe(_ hash: UInt64) -> Int {\n        refStripe(HeadSeriesRef(rawValue: hash))/' "$SS"; run "hashes are sharded through refStripe"
# Spelled so `i` stays used: deleting the guard outright leaves an unused binding and the control reports
# COMPILE, which measures nothing. That happened on the first run of this sweep.
perl -0pi -e 's/        if let prev = hashes\[i\]\.get\(hash: hash, labels: lset\) \{\n            return \(prev, false\)\n        \}/        _ = hashes[i].get(hash: hash, labels: lset)/' "$SS"; run "setUnlessAlreadySet overwrites an existing series"
perl -0pi -e 's/        let stripe = refStripe\(newSeries\.ref\)\n        series\[stripe\]\[newSeries\.ref\] = newSeries//' "$SS"; run "setUnlessAlreadySet never writes the ref map"
perl -0pi -e 's/        series\[refStripe\(id\)\]\[id\]/        series[0][id]/' "$SS"; run "getByID always reads stripe 0"
perl -0pi -e 's/        hashes\[hashStripe\(hash\)\]\.get\(hash: hash, labels: lset\)/        hashes[0].get(hash: hash, labels: lset)/' "$SS"; run "getByHash always reads stripe 0"
perl -0pi -e 's/    public func incMmapReady\(_ ref: HeadSeriesRef\) \{ mmapReady\[refStripe\(ref\)\] \+= 1 \}/    public func incMmapReady(_ ref: HeadSeriesRef) { mmapReady[refStripe(ref)] -= 1 }/' "$SS"; run "incMmapReady decrements"
perl -0pi -e 's/        seriesLifecycleCallback\.postCreation\(lset\)//' "$SS"; run "postCreation does not reach the callback"

# ---------------------------------------------------------------------------------------------------
# 27 controls: 23 broke, 4 SURVIVED, 0 SKIP, 0 COMPILE.
#
# One of the four survivors is DELIBERATE — `harness check: a no-op perturbation is reported as
# surviving` inserts a genuinely inert `_ = rem` and must survive. It is a control on the CONTROLS: it
# proves "broke" is not the harness's default answer, which is the failure mode that made five earlier
# sweeps report COMPILE for everything (see `lib/control-run.sh`). Keep it.
#
# The other three are proofs:
#
#   * `del on an unknown hash still clears the conflicts` — `conflicts[hash]` cannot be non-empty while
#     `unique[hash]` is absent, so the extra removal is a no-op. That is the type's central invariant,
#     stated in upstream's own comment: **each series is in exactly one of the two maps.** `set` only
#     creates a conflict when `unique` is occupied, and `del` promotes `conflicts[0]` whenever it vacates
#     the slot, so the two together maintain it.
#
#   * `refStripe uses a modulo rather than a mask` — identical for a power-of-two `size`, which the
#     `precondition` enforces. `x & (n-1) == x % n`.
#
#   * `hashes are sharded through refStripe` — and this one **corrected the source.** The two helpers
#     compute the SAME function; only the key differs. The file header had said the shardings were
#     "independent", which reads as different arithmetic, and this survivor is what showed it was
#     misleading. Both comments now say "same mask, different key". A survivor that fixes a comment
#     rather than a line is still worth the run.
#
# One control reported COMPILE on the first run — deleting `setUnlessAlreadySet`'s guard left an unused
# binding. Rewritten to keep `i` used; it now applies, compiles and breaks. A COMPILE measures nothing
# and is as misleading as a SKIP, which is why `lib/control-run.sh` reports them separately.
