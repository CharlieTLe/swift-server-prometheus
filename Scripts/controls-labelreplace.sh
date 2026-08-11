#!/usr/bin/env bash
# Negative controls for the capture-tracking Pike VM, `ExpandString`, and `label_replace`.
#
# The VM has a 66-case differential corpus; `label_replace` has `name_label_dropping.test` and
# `functions.test`. Both are in scope here because a capture bug shows up in either.
set -uo pipefail
cd "$(dirname "$0")/.."
C=Sources/PromRegex/RegexCapture.swift
L=Sources/PromQL/Functions+Sort.swift
cp "$C" /tmp/rc.orig && cp "$L" /tmp/lr.orig
restore() { cp /tmp/rc.orig "$C"; cp /tmp/lr.orig "$L"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'Submatch|ExitGate|LabelReplaceEdge' 50
  restore
}

echo "=== the VM: priority and the first-match cut ==="
perl -0pi -e 's/                runq\.truncate\(to: j\)//' "$C"; run "no first-match cut (leftmost-longest)"
# ^ SURVIVES, and it is ARGUED — for the only patterns this VM is given. `label_replace` compiles
# `^(?s:...)$`, so the `match` instruction is reachable only at end of text: every thread that matches
# does so at the SAME position, and `addThread`'s dedup-by-pc already keeps only the highest-priority
# one. The cut exists in Go for the unanchored case, where a lower-priority thread can go on to match
# further right and would otherwise overwrite a leftmost result. Kept for exactly that reason: the
# first unanchored caller of this VM needs it, and finding out the hard way would be a silent
# leftmost-longest answer rather than a crash.
perl -0pi -e 's/                addThread\(&q, Int\(i\.out\), pos, &caps, before, after\)\n                pc = Int\(i\.arg\)/                addThread(\&q, Int(i.arg), pos, \&caps, before, after)\n                pc = Int(i.out)/' "$C"; run "alt explores arg before out"
echo "=== the VM: capture save/restore ==="
perl -0pi -e 's/                    let old = caps\[slot\]\n                    caps\[slot\] = pos\n                    addThread\(&q, Int\(i\.out\), pos, &caps, before, after\)\n                    caps\[slot\] = old\n                    return/                    caps[slot] = pos\n                    addThread(\&q, Int(i.out), pos, \&caps, before, after)\n                    return/' "$C"; run "captures are not restored after the recursion"
perl -0pi -e 's/                if slot < caps\.count \{/                if false {/' "$C"; run "capture instructions are skipped entirely"
perl -0pi -e 's/                var t = caps\n                t\[1\] = pos/                var t = caps/' "$C"; run "the match end offset is not recorded"
perl -0pi -e 's/                matchcap\[0\] = pos/                matchcap[0] = 0/' "$C"; run "the match start is hard-coded to 0"
echo "=== the VM: byte offsets ==="
perl -0pi -e 's/UInt32\(b\[i \+ 1\] & 0x3F\)\), 2\)/UInt32(b[i + 1] \& 0x3F)), 1)/' "$C"; run "a 2-byte rune advances one byte"
perl -0pi -e 's/    return \(0xFFFD, 1\)/    return (0xFFFD, 2)/' "$C"; run "an invalid byte advances two"
echo "=== expand: the template language ==="
perl -0pi -e 's/        if t\.first == UInt8\(ascii: "\$"\) \{/        if false {/' "$C"; run "\$\$ is not a literal dollar"
perl -0pi -e 's/            out\.append\(UInt8\(ascii: "\$"\)\)\n            continue\n        \}\n        t = rest/            continue\n        }\n        t = rest/' "$C"; run "a malformed reference drops the dollar"
perl -0pi -e 's/    out\.append\(contentsOf: t\)\n    return out/    return out/' "$C"; run "the template tail after the last dollar is dropped"
echo "=== extract: names and numbers ==="
perl -0pi -e 's/    if nameBytes\[0\] == UInt8\(ascii: "0"\) && nameBytes\.count > 1 \{\n        num = -1\n    \}//' "$C"; run "a leading zero still parses as a number"
perl -0pi -e 's/    if i == 0 \{\n        \/\/ Go: "empty name is not okay"\.\n        return nil\n    \}//' "$C"; run "an empty name is accepted"
perl -0pi -e 's/        if i >= s\.count \|\| s\[i\] != UInt8\(ascii: "\}"\) \{\n            \/\/ Go: "missing closing brace"\.\n            return nil\n        \}//' "$C"; run "a missing closing brace is accepted"
perl -0pi -e 's/        if !isUnicodeLetterOrDigit\(r\) && r != Int32\(UInt8\(ascii: "_"\)\) \{/        if !isUnicodeLetterOrDigit(r) {/' "$C"; run "underscore is not a name character"
perl -0pi -e 's/        \|\| inUnicodeTable\(u, UnicodeTables\.categories\["Nd"\] \?\? \[\]\)//' "$C"; run "digits are not name characters"
echo "=== label_replace itself ==="
perl -0pi -e 's/        guard let indexes = regex\.findSubmatchIndex\(srcVal\) else \{ continue \}/        let indexes = regex.findSubmatchIndex(srcVal) ?? [0, 0, -1, -1]/' "$L"; run "a non-matching series is rewritten anyway"
perl -0pi -e 's/        matrix\.series\[i\]\.dropName = dst == LabelName\.metricName \? false : el\.dropName/        matrix.series[i].dropName = el.dropName/' "$L"; run "writing __name__ does not reset dropName"
perl -0pi -e 's/    let val = try ev\.evalNode\(ctx, args\[0\], &ws\)/    let (val, _) = try ev.eval(ctx, args[0])/' "$L"; run "the argument goes through the outer Eval"
perl -0pi -e 's/anchoredForLabelReplace: regexStr/pattern: regexStr/' "$L"; run "the regex is not anchored"
perl -0pi -e 's/    guard ValidationScheme\.utf8\.isValidLabelName\(stringLiteralBytes\(args\[1\]\)\) else \{/    guard ValidationScheme.utf8.isValidLabelName(dst) else {/' "$L"; run "the destination name is validated after decoding"
perl -0pi -e 's/    return try ev\.mergeSeriesWithSameLabelset\(matrix\)\n\}\n\n\/\/\/ The raw bytes/    return matrix\n}\n\n\/\/\/ The raw bytes/' "$L"; run "colliding label sets are not merged"
# ^ SURVIVES, and it is ARGUED. `cleanupMetricLabels` calls `mergeSeriesWithSameLabelset` on EVERY
# matrix, unconditionally — the `DropName` loop above it is conditional, the merge is not. So a
# collision `label_replace` leaves behind is merged one level up with the identical result, and the
# same-timestamp case raises the identical error from the identical function. There is no expression
# that can tell the two apart: a matrix from `label_replace` is either the top-level answer (merged by
# the cleanup) or consumed step-by-step as vectors, where a collision surfaces as a duplicate at one
# timestamp either way. Upstream has the same redundancy. Kept because it is upstream's shape and
# because a future caller that bypasses `Eval` would need it.
