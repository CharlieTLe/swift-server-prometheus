#!/usr/bin/env bash
# Negative controls for promql/info.go (Sources/PromQL/Engine+Info.swift) and `regexp.QuoteMeta`.
#
# `info.test`'s 42 assertions ARE the corpus here — there is no fixture, because `info` needs a
# running engine and a storage. So each control perturbs one decision and the exit gate is what
# notices. A SURVIVOR must be argued. See HANDOFF §4.
set -uo pipefail
cd "$(dirname "$0")/.."
I=Sources/PromQL/Engine+Info.swift
R=Sources/PromRegex/FastRegexMatcher.swift
cp "$I" /tmp/info.orig && cp "$R" /tmp/re.orig
restore() { cp /tmp/info.orig "$I"; cp /tmp/re.orig "$R"; }
trap restore EXIT

# The shared harness: builds, runs the filter under a time budget, prints the verdict. Its header says
# why that is not three lines inline.
source "$(dirname "$0")/lib/control-run.sh"

run() {
  control_verdict "$1" 'ExitGate|QuoteMeta|InfoEdge' 54
  restore
}

echo "=== identifying labels and the signature ==="
perl -0pi -e 's/private let identifyingLabels = \["instance", "job"\]/private let identifyingLabels = ["instance"]/' "$I"; run "job is not an identifying label"
perl -0pi -e 's/private let identifyingLabels = \["instance", "job"\]/private let identifyingLabels = ["instance", "job", "label"]/' "$I"; run "label is also an identifying label"
perl -0pi -e 's/            b\.add\(LabelName\.metricName, name\)//' "$I"; run "the signature omits the info metric name"
perl -0pi -e 's/            b\.sort\(\)//' "$I"; run "the signature is not sorted"
# ^ SURVIVES, and it is ARGUED. Both sides of the join build their signature with the SAME closure, so
# an unsorted signature is unsorted identically on both and equality is unaffected. Sorting matters to
# upstream because it hashes to a byte string via `Labels.Bytes()`, where order changes the bytes; the
# port keys on `Labels` itself. Kept so the two implementations read the same.
perl -0pi -e 's/for l in lset\.matchLabels\(on: true, identifyingLabels\)/for l in lset.matchLabels(on: false, identifyingLabels)/' "$I"; run "the signature keeps the NON-identifying labels"

echo "=== effectiveInfoNameMatchers: the three cases ==="
perl -0pi -e 's/        for m in matchers where m\.type == \.equal \|\| m\.type == \.regexp \{\n            \/\/ At least one positive matcher: use them as given\.\n            return matchers\n        \}//' "$I"; run "a positive matcher does not short-circuit"
perl -0pi -e 's/            return try \[Matcher\(\.regexp, LabelName\.metricName, "\.\+_info"\)\] \+ matchers/            return matchers/' "$I"; run "negatives-only gets no synthetic .+_info"
perl -0pi -e 's/        return \[try Matcher\(\.equal, LabelName\.metricName, targetInfoName\)\]/        return []/' "$I"; run "no matchers means no target_info default"
# Targets the CODE, not the header comment that mentions the same string — `-0pi` with no /g replaces
# only the first occurrence in the file, and the comment comes first.
perl -0pi -e 's/Matcher\(\.regexp, LabelName\.metricName, "\.\+_info"\)/Matcher(.regexp, LabelName.metricName, ".*_info")/' "$I"; run "the synthetic matcher is .*_info not .+_info"

echo "=== ignoreSeries: do not enrich an info series ==="
perl -0pi -e 's/            if effectiveNameMatchers\.allSatisfy\(\{ \$0\.matches\(name\) \}\) \{/            if false {/' "$I"; run "info series are enriched too"
perl -0pi -e 's/allSatisfy\(\{ \$0\.matches\(name\) \}\)/contains(where: { \$0.matches(name) })/' "$I"; run "ANY name matcher matching is enough to ignore"
perl -0pi -e 's/                out\.samples\.append\(Sample\(t: bs\.t, f: bs\.f, h: bs\.h, metric: bs\.metric\)\)\n                continue/                continue/' "$I"; run "an ignored series is dropped, not passed through"

echo "=== infoSelectHints ==="
perl -0pi -e 's/        start -= durationMilliseconds\(lookbackDelta\) - 1/        start -= durationMilliseconds(lookbackDelta)/' "$I"; run "the lookback reduction is not off by one"
# ^ SURVIVES, and it is ARGUED. The `- 1` is redundant against the lookback the info matrix is then
# evaluated with: `vectorSelectorSingle`'s window is `(ts - lookbackDelta, ts]`, half-open at the
# start, and the hints' start is `startTimestamp - lookbackDelta + 1`. So the only sample the
# perturbation newly admits sits at exactly `startTimestamp - lookbackDelta`, which every step's
# lookback then excludes anyway — the earliest instant any step can read is strictly later. Upstream's
# `- 1` states the intent at the storage boundary as well as the evaluation one; it cannot change an
# answer. Kept because upstream has it and because a storage that returns whole chunks (Phase 6-7)
# would make the narrower request cheaper rather than merely tidier.
perl -0pi -e 's/            start = ts\n            end = ts//' "$I"; run "the \@ timestamp does not override the range"
perl -0pi -e 's/        start -= offset\n        end -= offset//' "$I"; run "the offset is not applied to the hints"
perl -0pi -e 's/            throw EndTraversal\(\)/            return/' "$I"; run "Inspect does not stop at the first selector"

echo "=== fetchInfoSeries ==="
perl -0pi -e 's/                if val\.isEmpty \{ continue \}//' "$I"; run "an empty identifying label value is collected"
perl -0pi -e 's/            let re = idLblValues\[name\]!\.map\(goQuoteMeta\)\.joined\(separator: "\|"\)/            let re = idLblValues[name]!.joined(separator: "|")/' "$I"; run "identifying label values are not QuoteMeta'd"
perl -0pi -e 's/            if ignoreSeries\.contains\(s\.metric\.goHash\(\)\) \{ continue \}//' "$I"; run "ignored series contribute identifying values"
# ^ SURVIVES, and it is ARGUED. Skipping ignored series can only NARROW the alternation, and the
# alternation is a prefilter: the join compares signatures exactly, so extra info series fetched
# through a wider selector all fail to match. The skip is an efficiency, not a semantic — the same
# argument as the `QuoteMeta` one below, which needed an INVALID pattern rather than a wider one to
# become observable at all.
# `__name__` must be removed from the data label matchers on BOTH exits.
perl -0pi -e 's/        if idLblValues\.isEmpty \{\n            removeNameFromDataLabelMatchers\(\)/        if idLblValues.isEmpty {/' "$I"; run "the early exit skips removeName"
perl -0pi -e 's/        removeNameFromDataLabelMatchers\(\)\n        infoLabelMatchers \+= try effectiveInfoNameMatchers\(nameMatchers\)/        infoLabelMatchers += try effectiveInfoNameMatchers(nameMatchers)/' "$I"; run "the main exit skips removeName"
perl -0pi -e 's/                if m\.name == LabelName\.metricName \{\n                    nameMatchers\.append\(m\)\n                \} else \{\n                    infoLabelMatchers\.append\(m\)\n                \}/                infoLabelMatchers.append(m)/' "$I"; run "a __name__ matcher is used as a data label matcher"
perl -0pi -e 's/        let infoMat = try evalSeries\(ctx, infoSeries, GoDuration\(nanoseconds: 0\), true\)/        let infoMat = try evalSeries(ctx, infoSeries, GoDuration(nanoseconds: 0), false)/' "$I"; run "info series are evaluated without recordOrigT"

echo "=== combineWithInfoVector ==="
perl -0pi -e 's/        if base\.samples\.isEmpty \{\n            \/\/ "Short-circuit: nothing is going to match\."\n            return Vector\(\)\n        \}//' "$I"; run "no short-circuit on an empty base vector"
# ^ SURVIVES, and it is ARGUED: with no base samples the signature map is still built and then the base
# loop does nothing, so the function returns an empty vector either way. Upstream's own comment calls it
# a short-circuit. Pure optimisation.
perl -0pi -e 's/                if existingOrigT > origT \{/                if existingOrigT < origT {/' "$I"; run "the OLDER info sample wins"
perl -0pi -e 's/                    if l\.name == LabelName\.metricName \{ continue \}//' "$I"; run "the info metric's own __name__ is copied over"
perl -0pi -e 's/                    if !dataLabelMatchers\.isEmpty && dataLabelMatchers\[l\.name\] == nil \{/                    if false {/' "$I"; run "every info label is copied, not just the asked-for ones"
perl -0pi -e 's/                    if baseLabels\[l\.name\] != nil \{\n                        \/\/ Already on the base metric, so the base wins\.\n                        continue\n                    \}//' "$I"; run "an info label overwrites the base metric's"
perl -0pi -e 's/                    if !v\.isEmpty && v != l\.value \{\n                        throw EvaluationError\.conflictingLabel\(l\.name\)\n                    \}//' "$I"; run "a conflicting label is not an error"
perl -0pi -e 's/                if !allMatchersMatchEmpty \{\n                    continue\n                \}//' "$I"; run "an unmatched base series is kept anyway"
perl -0pi -e 's/                for m in ms where !m\.matches\(""\) \{/                for m in ms where false {/' "$I"; run "allMatchersMatchEmpty is always true"
perl -0pi -e 's/                if seenInfoMetrics\.contains\(infoName\) \{ continue \}//' "$I"; run "one info metric may join twice"
# ^ SURVIVES, and it is ARGUED as DEAD CODE — upstream's as much as the port's. The loop iterates
# `baseSigs[hash]`, a map keyed BY info metric name, so `infoName` is distinct on every iteration and
# the check can never fire. Kept only so the two implementations line up; if upstream ever iterates
# something else, this is the guard that was already there.

echo "=== QuoteMeta ==="
perl -0pi -e 's/UInt8\(ascii: "\."\), //' "$R"; run "a dot is not escaped"
perl -0pi -e 's/UInt8\(ascii: "\\\\"\), //' "$R"; run "a backslash is not escaped"
perl -0pi -e 's/, UInt8\(ascii: "\$"\):/:/' "$R"; run "a dollar is not escaped"
