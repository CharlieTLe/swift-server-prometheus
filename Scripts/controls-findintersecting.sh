#!/usr/bin/env bash
# Negative controls for `FindIntersectingPostings` and its non-popping heap.
#
# **This sweep is the reason the corpus has the shape it does, and the story is worth reading before adding
# to it.** The first version of `index/findintersecting.jsonl` had 32 cases covering what looked like every
# interesting shape: ties, reversed orders, shared values, heap sizes at every power of two. The control that
# replaces `heap.Init` with a push loop SURVIVED all 32.
#
# The equivalence argument was easy to write and would have been WRONG. A brute-force search over small random
# inputs found a distinguishing case in 15 trials — several candidates tying on their first value, where the
# initial layout is the only tie-break there is. Three such cases are now in the corpus and the control breaks
# on all three.
#
# The lesson, recorded in PORTING.md: a SURVIVED verdict is a HYPOTHESIS, not a proof. When the perturbation
# is a plausible alternative implementation rather than an obvious bug, search for a distinguishing input
# before writing the argument. Reasoning about heap layouts is exactly the kind that feels rigorous and is not.
set -uo pipefail
cd "$(dirname "$0")/.."
F=Sources/PromIndex/FindIntersecting.swift
H=Sources/GoCompat/GoHeap.swift
cp "$F" /tmp/fi.orig && cp "$H" /tmp/fih.orig
restore() { cp /tmp/fi.orig "$F"; cp /tmp/fih.orig "$H"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'FindIntersecting' 56
  restore
}

echo "=== heap construction ==="
perl -0pi -e 's/        GoHeap\.initialized\(\n            count: items\.count,\n            less: \{ self\.less\(\$0, \$1\) \},\n            swap: \{ items\.swapAt\(\$0, \$1\) \}\)/        for k in 1...max(items.count, 1) {\n            GoHeap.pushed(\n                count: k, less: { self.less(\$0, \$1) }, swap: { items.swapAt(\$0, \$1) })\n        }/' "$F"; run "heap.Init replaced by a push loop"
perl -0pi -e 's/    mutating func initialize\(\) \{\n        GoHeap\.initialized\(/    mutating func initialize() {\n        if items.isEmpty { return }\n        _ = GoHeap.initialized(/' "$F"; run "(no-op control: a guard that changes nothing)"
perl -0pi -e 's/        var i = count \/ 2 - 1/        var i = count - 1/' "$H"; run "Init sifts from the LAST index, not the last internal node"
# ^ SURVIVES, ARGUED as a PROOF about the tree rather than about order: `down(i)` computes `2*i + 1` and
# returns immediately when that is >= count, so every index in the leaf half is a no-op. Starting at
# `count - 1` therefore performs `count/2` no-op iterations and then does exactly what starting at
# `count/2 - 1` does. Go's bound is the tightest correct one, not a different algorithm.
perl -0pi -e 's/        var i = count \/ 2 - 1\n        while i >= 0 \{\n            _ = down\(i, count, less, swap\)\n            i -= 1\n        \}/        for i in 0..<max(count \/ 2, 0) {\n            _ = down(i, count, less, swap)\n        }/' "$H"; run "Init sifts FORWARD instead of backwards"

echo "=== Less: popped elements to the bottom ==="
perl -0pi -e 's/            return items\[j\]\.popped/            return items[i].popped/' "$F"; run "the popped comparison is inverted"
perl -0pi -e 's/        if items\[i\]\.popped != items\[j\]\.popped \{\n            return items\[j\]\.popped\n        \}//' "$F"; run "popped is not considered at all"
perl -0pi -e 's/        return items\[i\]\.p\.at\(\) < items\[j\]\.p\.at\(\)/        return items[i].p.at() > items[j].p.at()/' "$F"; run "the heap is a MAX-heap"
perl -0pi -e 's/        return items\[i\]\.p\.at\(\) < items\[j\]\.p\.at\(\)/        return items[i].p.at() <= items[j].p.at()/' "$F"; run "Less is not strict (<= instead of <)"

echo "=== empty() is not isEmpty ==="
perl -0pi -e 's/    var isEmptyHeap: Bool \{ items\.isEmpty \|\| items\[0\]\.popped \}/    var isEmptyHeap: Bool { items.isEmpty }/' "$F"; run "empty() ignores the popped root (Len > 0 means non-empty)"
perl -0pi -e 's/    var isEmptyHeap: Bool \{ items\.isEmpty \|\| items\[0\]\.popped \}/    var isEmptyHeap: Bool { items.isEmpty || items.allSatisfy { \$0.popped } }/' "$F"; run "empty() waits for EVERY element to be popped"
# ^ SURVIVES, ARGUED from the heap invariant plus `Less`: a popped element compares GREATER than every live
# one, so if the root is popped there can be no live element anywhere — `items[0].popped` implies
# `allSatisfy { popped }`, and the converse is trivial. The two predicates are equivalent for any array that
# satisfies the invariant, which `fix` maintains at every mutation. Upstream's version is O(1) and this is
# O(n) per iteration; that is the whole difference.
#
# Note the OTHER direction broke, and broke by HANGING: `items.isEmpty` alone never becomes true, because
# nothing is ever removed, so the loop spins forever. The 120s budget reported it as `broke (hung)` instead
# of stalling the sweep — the second time that guard has paid for itself.

echo "=== popIndex marks and re-sinks, it does not remove ==="
perl -0pi -e 's/        items\[0\]\.popped = true\n        fix\(0\)\n        return index/        items.removeFirst()\n        if !items.isEmpty { fix(0) }\n        return index/' "$F"; run "popIndex actually removes the element"
perl -0pi -e 's/        items\[0\]\.popped = true\n        fix\(0\)\n        return index/        items[0].popped = true\n        return index/' "$F"; run "popIndex does not re-sink the popped root"

echo "=== the loop's asymmetric branches ==="
perl -0pi -e 's/        if p\.at\(\) == h\.at\(\) \{\n            indexes\.append\(h\.popIndex\(\)\)\n        \} else \{\n            try h\.seekHead\(p\.at\(\)\)\n        \}/        if p.at() == h.at() {\n            indexes.append(h.popIndex())\n        } else {\n            _ = h.popIndex()\n        }/' "$F"; run "an overshoot POPS the candidate instead of seeking it"
perl -0pi -e 's/        if p\.at\(\) == h\.at\(\) \{/        if p.at() >= h.at() {/' "$F"; run "the match test accepts an overshoot"
perl -0pi -e 's/        if !p\.seek\(h\.at\(\)\) \{/        if !p.next() {/' "$F"; run "the query advances by next instead of seeking the heap minimum"

echo "=== seekHead touches the ROOT only ==="
perl -0pi -e 's/        if items\[0\]\.p\.seek\(val\) \{\n            fix\(0\)\n            return\n        \}/        if items[0].p.seek(val) {\n            return\n        }/' "$F"; run "seekHead does not re-fix after a successful seek"
perl -0pi -e 's/        if items\[0\]\.p\.seek\(val\) \{/        if items[0].p.next() {/' "$F"; run "seekHead steps instead of seeking"
# ^ Expected to break: a single `next()` need not reach `val`, so the loop can spin on a value below it.
perl -0pi -e 's/        _ = popIndex\(\)\n    \}\n\}/        \/\/ removed\n    }\n}/' "$F"; run "an exhausted candidate is never popped"

echo "=== construction: the pre-heap Next(), and the early return ==="
perl -0pi -e 's/        if it\.next\(\) \{\n            h\.items\.append\(PostingsWithIndex\(index: idx, p: it\)\)/        if true {\n            h.items.append(PostingsWithIndex(index: idx, p: it))/' "$F"; run "candidates are not advanced once before heaping"
perl -0pi -e 's/    if h\.isEmptyHeap \{\n        \/\/ Go returns `nil, nil` here — an empty result, not an error\.\n        return \[\]\n    \}\n    h\.initialize\(\)/    h.initialize()/' "$F"; run "the all-empty short-circuit is gone"
# ^ SURVIVES or traps depending on the case; either way it is reported. `initialize()` over an empty array is
# a no-op and the `while !h.isEmptyHeap` loop then does not run, so the answer is the same — the guard is
# upstream's clarity, not a behaviour. Recorded rather than removed.
perl -0pi -e 's/            return indexes\n        \}/            return []\n        }/' "$F"; run "the early return DISCARDS the partial result"
