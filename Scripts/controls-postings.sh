#!/usr/bin/env bash
# Negative controls for the postings algebra and the loser tree under Merge.
#
# Unlike the chunkenc sweeps, everything under test here is exported upstream, so the corpus reaches it
# directly — there is no container to drive it through and no "pinned only via X" caveat.
set -uo pipefail
cd "$(dirname "$0")/.."
P=Sources/PromIndex/Postings.swift
L=Sources/GoCompat/GoLoserTree.swift
cp "$P" /tmp/p.orig && cp "$L" /tmp/l.orig
restore() { cp /tmp/p.orig "$P"; cp /tmp/l.orig "$L"; }
trap restore EXIT

# A perturbation can make an iterator NON-TERMINATING rather than wrong — `intersect.seek` loops until
# its target settles, so accepting an equal value means it never does. Without a timeout that hangs the
# whole sweep instead of reporting, which is how the first run of this script stalled for half an hour at
# `=== Intersect ===`. A control that never returns is a control that broke; time it out and say so.
#
# `timeout(1)` is GNU coreutils and not on a stock macOS, hence the background-and-poll.
run() {
  local name="$1"
  if ! swift build 2>/dev/null >/dev/null; then printf '  %-52s COMPILE\n' "$name"; restore; return; fi
  local log; log=$(mktemp)
  swift test --filter 'Postings' >"$log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 120 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    pkill -9 -f swiftpm-testing-helper 2>/dev/null
    wait "$pid" 2>/dev/null
    printf '  %-52s broke (hung)\n' "$name"
  elif grep -qE '✘|error:|signal' "$log"; then
    printf '  %-52s broke\n' "$name"
  else
    printf '  %-52s SURVIVED\n' "$name"
  fi
  rm -f "$log"
  restore
}

echo "=== Seek's idempotence ==="
perl -0pi -e 's/        if cur >= x \{ return true \}\n        if i >= list\.count \{ return false \}/        if i >= list.count { return false }/' "$P"; run "ListPostings.seek is not idempotent"
perl -0pi -e 's/    public func seek\(_ x: SeriesRef\) -> Bool \{\n        if cur >= x \{ return true \}/    public func seek(_ x: SeriesRef) -> Bool {\n        if cur > x { return true }/' "$P"; run "ListPostings.seek uses > not >="
perl -0pi -e 's/        if cur >= id \{ return true \}\n        fok = full\.seek\(id\)/        fok = full.seek(id)/' "$P"; run "Without.seek is not idempotent"
perl -0pi -e 's/        cur = SeriesRef\(rawValue: 0\)\n        return false\n    \}\n\n    public func seek/        return false\n    }\n\n    public func seek/' "$P"; run "ListPostings.next does not reset cur on exhaustion"

echo "=== the empty sentinel ==="
perl -0pi -e 's/    p === emptyPostingsSingleton/    false/' "$P"; run "isEmptyPostingsType always false"
perl -0pi -e 's/    if its\.contains\(where: \{ isEmptyPostingsType\(\$0\) \}\) \{ return emptyPostings\(\) \}//' "$P"; run "intersect does not short-circuit on empty"
perl -0pi -e 's/    if isEmptyPostingsType\(drop\) \{ return full \}//' "$P"; run "without does not short-circuit on an empty drop"
# ^ SURVIVES, ARGUED: with an empty `drop`, `RemovedPostings.next` takes its `!rok` branch immediately and
# passes all of `full` through, so the values are identical. Upstream's short-circuit avoids the wrapper
# allocation, not a wrong answer.
perl -0pi -e 's/    if isEmptyPostingsType\(full\) \{ return emptyPostings\(\) \}//' "$P"; run "without does not short-circuit on an empty full"

echo "=== Intersect ==="
perl -0pi -e 's/                if p\.at\(\) > target \{\n                    target = p\.at\(\)\n                    allEqual = false\n                \}/                if p.at() >= target {\n                    target = p.at()\n                    allEqual = false\n                }/' "$P"; run "intersect.seek advances on an equal value"
# Flipping the flag rather than deleting the branch: deleting it leaves the `else if` dangling and the
# control reports COMPILE instead of a result.
perl -0pi -e 's/            \} else if a < target \{\n                allEqual = false\n            \}/            } else if a < target {\n                allEqual = true\n            }/' "$P"; run "intersect.next ignores a lower value"

echo "=== Merge and de-duplication ==="
perl -0pi -e 's/            if newItem != cur \{\n                cur = newItem\n                return true\n            \}/            cur = newItem\n            return true/' "$P"; run "merge does not de-duplicate"
perl -0pi -e 's/        while !tree\.isEmpty\(\) && tree\.at\(\) < id \{/        while !tree.isEmpty() \&\& tree.at() <= id {/' "$P"; run "merge.seek advances past an equal value"
perl -0pi -e 's/            let finished = !\(tree\.winner\(\)\?\.p\.seek\(id\) \?\? false\)\n            tree\.fix\(finished\)/            _ = tree.next()/' "$P"; run "merge.seek uses tree.next instead of Fix"
# ^ SURVIVES, ARGUED as equivalent-but-slower. `tree.next()` advances the winner ONE step and re-settles;
# `winner().seek(id)` jumps. Either way the `while tree.at() < id` loop exits at the first value >= id, so
# the answer is the same and only the number of steps differs. `Fix` exists because the sequence moved
# behind the tree's back and its stored value must be refreshed — which `next()` also does. Kept because
# it is upstream's shape and because a sequence whose `seek` is cheaper than repeated `next` is the whole
# reason `Seek` is in the protocol.
perl -0pi -e 's/maxVal: SeriesRef\(rawValue: UInt64\.max\)/maxVal: SeriesRef(rawValue: 1000)/' "$P"; run "the loser tree's maxVal is not above every real value"

echo "=== Without ==="
perl -0pi -e 's/                rok = remove\.seek\(fcur\)/                rok = remove.next()/' "$P"; run "without advances the drop side by next not seek"
# ^ SURVIVES, ARGUED as equivalent-but-slower, the same shape as the `merge.seek` survivor above: the loop
# runs until `rcur >= fcur` whether the drop side jumps or steps.
perl -0pi -e 's/        \/\/ `next\(\)` is what actually applies the removal at the new position — see the file header\.\n        return next\(\)/        return fok/' "$P"; run "without.seek does not re-apply the removal"
perl -0pi -e 's/            if !rok \{\n                \/\/ Nothing left to remove, so the rest of `full` passes through\.\n                cur = full\.at\(\)\n                fok = full\.next\(\)\n                return true\n            \}//' "$P"; run "without stops when the drop side is exhausted"

echo "=== the loser tree ==="
perl -0pi -e 's/        if nodes\[left\]\.value < nodes\[right\]\.value \{/        if nodes[left].value <= nodes[right].value {/' "$L"; run "playGame breaks ties the other way"
# ^ SURVIVES, and so does its `replayGames` twin. ARGUED: `Merge` DE-DUPLICATES, so which of two equal
# values wins the tournament cannot be observed through postings — quirk 125. The tree is in `GoCompat`
# now, though, and the next user may not de-duplicate, which is why the strict `<` is commented in place
# rather than left as an accident.
perl -0pi -e 's/            if nodes\[n\]\.value < winningValue \{/            if nodes[n].value <= winningValue {/' "$L"; run "replayGames breaks ties the other way"
perl -0pi -e 's/        if nodes\[0\]\.index == -1 \{\n            initialize\(\)\n        \}\n        return nodes\[nodes\[0\]\.index\]\.index == -1/        return nodes[nodes[0].index].index == -1/' "$L"; run "isEmpty does not initialize the tree"
perl -0pi -e 's/            _ = moveNext\(i \+ n\)/            ()/' "$L"; run "sequences are not advanced once at construction"
