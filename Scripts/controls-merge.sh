#!/usr/bin/env bash
# Negative controls for the VERTICAL MERGE — `storage/merge.go`, `lazy.go`, `secondary.go` and
# `generic.go` Part A.
#
# Five source files, so `run` takes the file it perturbed (the two-file helper from
# `Scripts/controls-headwaltruncate.sh`, widened):
#
#   Sources/PromStorage/Merge.swift        storage/merge.go
#   Sources/PromStorage/Lazy.swift         storage/lazy.go
#   Sources/PromStorage/Secondary.swift    storage/secondary.go
#   Sources/PromStorage/Generic.swift      storage/generic.go Part A
#   Sources/PromStorage/SeriesChunks.swift storage/series.go's chunk half
#
# plus two GoCompat files this slice grew for it:
#
#   Sources/GoCompat/GoHeap.swift          container/heap's Pop, which all three heaps run on
#   Sources/GoCompat/GoErrors.swift        errors.Join, which four Err() methods render through
#
# The corpus is `Fixtures/storage/merge.jsonl`, 85 cases driven through the real
# `NewMergeQuerier`/`NewMergeChunkQuerier` over real block queriers. It commits the merged label
# sets, the sample TIMESTAMPS AND VALUES, a seek script, the chunk ranges and BYTES, both label
# queries, the warnings and the errors — so a perturbation that changes which duplicate sample wins,
# or that re-encodes a chunk it should have passed through, is a byte diff rather than a count diff.
#
# `PromBlockTests` is run alongside `PromStorageTests` because this slice also gave `PromBlock` its
# `Querier`/`SeriesSet` conformances, and a perturbation there has to be visible somewhere.
#
# Traps inherited from earlier sweeps and worth re-reading before adding a control:
#
#   * `\Q…\E` cannot contain a `$` or a `\`, so no Swift string interpolation can appear in a
#     pattern. End the quoted run early and use `[^\n]*` for the rest of the line.
#   * `\Q…\E` does not interpret `\n`; a multi-line pattern needs `\E\n\Q` between the lines.
#   * an apostrophe cannot appear in a single-quoted perl program.
#   * check the indentation — most of this file's bodies are two or three levels in.
#   * a control that patches a DOC COMMENT measures nothing. Include enough context to be unique.
set -uo pipefail
cd "$(dirname "$0")/.."
MG=Sources/PromStorage/Merge.swift
LZ=Sources/PromStorage/Lazy.swift
SC=Sources/PromStorage/Secondary.swift
GN=Sources/PromStorage/Generic.swift
SK=Sources/PromStorage/SeriesChunks.swift
GH=Sources/GoCompat/GoHeap.swift
GE=Sources/GoCompat/GoErrors.swift
cp "$MG" /tmp/mrg-mg.orig
cp "$LZ" /tmp/mrg-lz.orig
cp "$SC" /tmp/mrg-sc.orig
cp "$GN" /tmp/mrg-gn.orig
cp "$SK" /tmp/mrg-sk.orig
cp "$GH" /tmp/mrg-gh.orig
cp "$GE" /tmp/mrg-ge.orig
restore() {
  cp /tmp/mrg-mg.orig "$MG"; cp /tmp/mrg-lz.orig "$LZ"; cp /tmp/mrg-sc.orig "$SC"
  cp /tmp/mrg-gn.orig "$GN"; cp /tmp/mrg-sk.orig "$SK"
  cp /tmp/mrg-gh.orig "$GH"; cp /tmp/mrg-ge.orig "$GE"
}
trap restore EXIT

source "$(dirname "$0")/lib/control-run.sh"

# run <file> <name>
run() {
  local f="$1" name="$2" orig
  case "$f" in
    "$MG") orig=/tmp/mrg-mg.orig ;;
    "$LZ") orig=/tmp/mrg-lz.orig ;;
    "$SC") orig=/tmp/mrg-sc.orig ;;
    "$GN") orig=/tmp/mrg-gn.orig ;;
    "$SK") orig=/tmp/mrg-sk.orig ;;
    "$GH") orig=/tmp/mrg-gh.orig ;;
    "$GE") orig=/tmp/mrg-ge.orig ;;
  esac
  if cmp -s "$f" "$orig"
  then
    printf "  %-72s SKIP (patch did not apply)\n" "$name"
    restore
    return
  fi
  control_verdict "$name" 'StorageMergeTests|StorageMergeUnitTests|SecondaryQuerierMultiSetTests|BlockSeriesSetTests' 72
  restore
}

echo "=== NewMergeQuerier's four-arm switch, and filterQueriers ==="
perl -0pi -e 's~\Q        if q is NoopQuerier { continue }\E~~' "$MG"; run "$MG" "filterQueriers keeps noop queriers"
perl -0pi -e 's~\Q        guard let q else { continue }\E\n\Q        if q is NoopQuerier { continue }\E~        guard let q else { continue }~' "$MG"; run "$MG" "filterQueriers keeps noop queriers (sample side only)"
perl -0pi -e 's~\Q    case \E\Q(1, 0):\E\n\Q        return primaries\E\Q[0]\E~    case (1, 0):\n        return QuerierAdapter(newGenericQuerierFrom(primaries[0]))~' "$MG"; run "$MG" "a single primary is WRAPPED rather than passed through"
perl -0pi -e 's~\Q    case \E\Q(0, 1):\E\n\Q        return QuerierAdapter(newSecondaryQuerierFrom(secondaries\E\Q[0]))\E~    case (0, 1):\n        return secondaries[0]~' "$MG"; run "$MG" "a single secondary is passed through rather than wrapped"
perl -0pi -e 's~\Q    case \E\Q(0, 0):\E\n\Q        return NoopQuerier()\E~    case (-1, -1):\n        return NoopQuerier()~' "$MG"; run "$MG" "the no-querier arm is unreachable"
perl -0pi -e 's~\Q    for q in primaries { queriers.append(newGenericQuerierFrom(q)) }\E\n\Q    for q in secondaries { queriers.append(newSecondaryQuerierFrom(q)) }\E~    for q in secondaries { queriers.append(newSecondaryQuerierFrom(q)) }\n    for q in primaries { queriers.append(newGenericQuerierFrom(q)) }~' "$MG"; run "$MG" "secondaries are ordered BEFORE primaries"
perl -0pi -e 's~\Q    for q in secondaries { queriers.append(newSecondaryQuerierFrom(q)) }\E~    for q in secondaries { queriers.append(newGenericQuerierFrom(q)) }~' "$MG"; run "$MG" "a secondary is wrapped as a PRIMARY"
perl -0pi -e 's~\Q    for q in primaries { queriers.append(newGenericQuerierFrom(q)) }\E~    for q in primaries { queriers.append(newSecondaryQuerierFrom(q)) }~' "$MG"; run "$MG" "a primary is wrapped as a SECONDARY"
perl -0pi -e 's~\Q        if q is NoopChunkQuerier { continue }\E~~' "$MG"; run "$MG" "filterChunkQueriers keeps noop chunk queriers"
perl -0pi -e 's~\Q        return ChunkQuerierAdapter(newSecondaryQuerierFromChunk(secondaries\E\Q[0]))\E~        return secondaries[0]~' "$MG"; run "$MG" "a single secondary CHUNK querier is passed through"

echo "=== mergeGenericQuerier.Select ==="
perl -0pi -e 's~\Q                querier.select(ctx, sortSeries: true, hints: hints, matchers: matchers))\E~                querier.select(ctx, sortSeries: sortSeries, hints: hints, matchers: matchers))~' "$MG"; run "$MG" "the fan-out forwards sortSeries instead of forcing true"
perl -0pi -e 's~\Q        let limit = hints?.limit ?? 0\E~        let limit = 0~' "$MG"; run "$MG" "the SelectHints limit never reaches the merge"
perl -0pi -e 's~\Q        let limit = hints?.limit ?? 0\E~        let limit = (hints?.limit ?? 0) + 1~' "$MG"; run "$MG" "the series limit is one too many"
perl -0pi -e 's~\Q            return (s, s.next())\E~            return (s, true)~' "$MG"; run "$MG" "the lazy set is not pre-advanced"
perl -0pi -e 's~\Q        return LazyGenericSeriesSet<E> {\E\n\Q            let s = newGenericMergeSeriesSet(seriesSets, limit, mergeFn)\E\n\Q            return (s, s.next())\E\n\Q        }\E~        return newGenericMergeSeriesSet(seriesSets, limit, mergeFn)~' "$MG"; run "$MG" "Select is not lazy at all"
perl -0pi -e 's~\Q        for querier in queriers {\E~        for querier in queriers.reversed() {~' "$MG"; run "$MG" "the sets are collected in REVERSE querier order"

echo "=== newGenericMergeSeriesSet ==="
perl -0pi -e 's~\Q    if sets.count == 1 {\E\n\Q        return sets\E\Q[0]\E\n\Q    }\E~~' "$MG"; run "$MG" "a single set is wrapped rather than returned unchanged"
perl -0pi -e 's~\Q    if sets.count == 1 {\E~    if sets.count <= 2 {~' "$MG"; run "$MG" "two sets take the single-set shortcut"
perl -0pi -e 's~\Q        if set.next() {\E\n\Q            h.push(set)\E\n\Q        }\E\n\Q        if let err = set.err() {\E~        if let err = set.err() {~' "$MG"; run "$MG" "the sets are not pre-advanced before the heap is built"
perl -0pi -e 's~\Q        if let err = set.err() {\E\n\Q            return ErrorOnlySeriesSet<E>(err)\E\n\Q        }\E~~' "$MG"; run "$MG" "a set that errors during the pre-advance is not reported"
perl -0pi -e 's~\Q            return ErrorOnlySeriesSet<E>(err)\E~            return WarningsOnlySeriesSet<E>(Annotations())~' "$MG"; run "$MG" "a pre-advance error becomes an empty set rather than an error"

echo "=== genericMergeSeriesSet.Next ==="
perl -0pi -e 's~\Q        if seriesLimit > 0 && mergedSeries >= seriesLimit {\E~        if seriesLimit > 0 \&\& mergedSeries > seriesLimit {~' "$MG"; run "$MG" "the series limit admits one extra series"
perl -0pi -e 's~\Q        if seriesLimit > 0 && mergedSeries >= seriesLimit {\E\n\Q            return false\E\n\Q        }\E~~' "$MG"; run "$MG" "the series limit is never enforced"
perl -0pi -e 's~\Q        if seriesLimit > 0 && mergedSeries >= seriesLimit {\E~        if seriesLimit >= 0 \&\& mergedSeries >= seriesLimit {~' "$MG"; run "$MG" "a limit of zero means zero rather than unlimited"
perl -0pi -e 's~\Q            for set in currentSets {\E\n\Q                if set.next() {\E\n\Q                    heap.push(set)\E\n\Q                }\E\n\Q            }\E~~' "$MG"; run "$MG" "the consumed sets are never re-advanced"
perl -0pi -e 's~\Q                if set.next() {\E\n\Q                    heap.push(set)\E\n\Q                }\E~                _ = set.next()\n                heap.push(set)~' "$MG"; run "$MG" "an exhausted set is pushed back onto the heap"
perl -0pi -e 's~\Q            currentSets.removeAll(keepingCapacity: true)\E~~' "$MG"; run "$MG" "currentSets is never cleared between series"
perl -0pi -e 's~\Q                Labels.compare(currentLabels, heap.peek().at()?.labels() ?? Labels.empty) == 0\E~                false~' "$MG"; run "$MG" "no two sets are ever considered to hold the same series"
perl -0pi -e 's~\Q            while !heap.isEmpty,\E\n\Q                Labels.compare(currentLabels, heap.peek().at()?.labels() ?? Labels.empty) == 0\E\n\Q            {\E~            while !heap.isEmpty {~' "$MG"; run "$MG" "every set is popped for the first label set"
perl -0pi -e 's~\Q            if !currentSets.isEmpty {\E\n\Q                break\E\n\Q            }\E~            break~' "$MG"; run "$MG" "the retry loop exits even with an empty currentSets"
perl -0pi -e 's~\Q        mergedSeries += 1\E~~' "$MG"; run "$MG" "the merged-series counter never advances"

echo "=== genericMergeSeriesSet.At / Err / Warnings ==="
perl -0pi -e 's~\Q        if currentSets.count == 1 {\E\n\Q            return currentSets\E\Q[0].at()\E\n\Q        }\E~~' "$MG"; run "$MG" "a single-set series still goes through the merge function"
perl -0pi -e 's~\Q        if currentSets.count == 1 {\E~        if currentSets.count >= 1 {~' "$MG"; run "$MG" "At always returns the FIRST set's series"
perl -0pi -e 's~\Q        for set in currentSets {\E\n\Q            guard let s = set.at() else { continue }\E\n\Q            series.append(s)\E\n\Q        }\E~        for set in currentSets.reversed() {\n            guard let s = set.at() else { continue }\n            series.append(s)\n        }~' "$MG"; run "$MG" "the merge function is given the sets in reverse pop order"
perl -0pi -e 's~\Q        for set in sets {\E\n\Q            if let err = set.err() { return err }\E\n\Q        }\E~~' "$MG"; run "$MG" "Err never reports anything"
perl -0pi -e 's~\Q            ws.merge(set.warnings())\E~~' "$MG"; run "$MG" "Warnings are never collected"

echo "=== the heaps ==="
perl -0pi -e 's~\Q        return Labels.compare(a, b) < 0\E~        return Labels.compare(a, b) > 0~' "$MG"; run "$MG" "the series-set heap is ordered descending"
perl -0pi -e 's~\Q        return Labels.compare(a, b) < 0\E~        return false~' "$MG"; run "$MG" "the series-set heap does not order at all"
perl -0pi -e 's~\Q    private func less(_ i: Int, _ j: Int) -> Bool { items\E\Q[i].atT() < items[j].atT() }\E~    private func less(_ i: Int, _ j: Int) -> Bool { items[i].atT() > items[j].atT() }~' "$MG"; run "$MG" "the sample heap is ordered by DESCENDING timestamp"
perl -0pi -e 's~\Q        if at.minTime == bt.minTime {\E\n\Q            return at.maxTime < bt.maxTime\E\n\Q        }\E~~' "$MG"; run "$MG" "the chunk heap does not break min-time ties by max time"
perl -0pi -e 's~\Q            return at.maxTime < bt.maxTime\E~            return at.maxTime > bt.maxTime~' "$MG"; run "$MG" "the chunk heap breaks min-time ties by DESCENDING max time"
perl -0pi -e 's~\Q        return at.minTime < bt.minTime\E~        return at.maxTime < bt.maxTime~' "$MG"; run "$MG" "the chunk heap orders by max time rather than min time"

echo "=== GoHeap.popped, which every one of the three heaps runs on ==="
perl -0pi -e 's~\Q        let n = count - 1\E\n\Q        swap(0, n)\E\n\Q        _ = down(0, n, less, swap)\E~        let n = count - 1\n        swap(0, n)\n        _ = down(0, count, less, swap)~' "$GH"; run "$GH" "heap.Pop sifts down over the FULL length"
perl -0pi -e 's~\Q        swap(0, n)\E\n\Q        _ = down(0, n, less, swap)\E~        _ = down(0, n, less, swap)\n        swap(0, n)~' "$GH"; run "$GH" "heap.Pop sifts down BEFORE moving the root to the end"

echo "=== chainSampleIterator.Next ==="
perl -0pi -e 's~\Q                if currT == lastT {\E~                if currT == lastT \&\& false {~' "$MG"; run "$MG" "a duplicate timestamp is emitted rather than dropped"
perl -0pi -e 's~\Q                if currT == lastT {\E~                if currT <= lastT {~' "$MG"; run "$MG" "any non-increasing timestamp is dropped"
perl -0pi -e 's~\Q                if currT < nextT {\E~                if currT <= nextT {~' "$MG"; run "$MG" "the current iterator wins a tie against the heap top"
perl -0pi -e 's~\Q                if currT < nextT {\E~                if false {~' "$MG"; run "$MG" "the current iterator never keeps the cursor"
perl -0pi -e 's~\Q                h!.push(curr!)\E~~' "$MG"; run "$MG" "an out-of-turn iterator is dropped rather than pushed back"
perl -0pi -e 's~\Q            currValueType = popped.seek(currT)\E~~' "$MG"; run "$MG" "the popped iterator is not re-seeked to its own timestamp"
perl -0pi -e 's~\Q            if currT != lastT {\E~            if true {~' "$MG"; run "$MG" "the post-pop duplicate check is skipped"
perl -0pi -e 's~\Q            curr = iterators.first\E~            curr = iterators.first; _ = curr?.next()~' "$MG"; run "$MG" "iterators[0] is advanced during initialisation"
perl -0pi -e 's~\Q            for iter in iterators.dropFirst() {\E~            for iter in iterators {~' "$MG"; run "$MG" "iterators[0] is also pushed onto the heap"
perl -0pi -e 's~\Q                if h!.isEmpty {\E\n\Q                    // The only iterator left; no need to consult the heap.\E\n\Q                    break\E\n\Q                }\E~~' "$MG"; run "$MG" "the last-iterator shortcut is removed"
perl -0pi -e 's~\Q        lastT = currT\E~~' "$MG"; run "$MG" "lastT is never updated"
perl -0pi -e 's~\Q        consecutive = !iteratorChanged\E~        consecutive = iteratorChanged~' "$MG"; run "$MG" "the consecutive flag is inverted (INERT: floats only, so no counter-reset hint is read)"

echo "=== chainSampleIterator.Seek ==="
perl -0pi -e 's~\Q        if let curr, lastT >= t {\E~        if let curr, lastT > t {~' "$MG"; run "$MG" "the seek no-op check excludes an exactly-equal timestamp"
perl -0pi -e 's~\Q        if let curr, lastT >= t {\E\n\Q            return curr.seek(lastT)\E\n\Q        }\E~~' "$MG"; run "$MG" "there is no seek no-op check at all"
perl -0pi -e 's~\Q            return curr.seek(lastT)\E~            return curr.seek(t)~' "$MG"; run "$MG" "the no-op branch seeks to t rather than to lastT"
perl -0pi -e 's~\Q            lastT = popped.atT()\E\n\Q            return popped.seek(lastT)\E~            return popped.seek(popped.atT())~' "$MG"; run "$MG" "Seek does not record lastT"
perl -0pi -e 's~\Q        h = SamplesIteratorHeap()\E\n\Q        for iter in iterators {\E~        for iter in iterators {~' "$MG"; run "$MG" "Seek leaves the heap nil, so a following Next re-initialises"
perl -0pi -e 's~\Q                if iter.err() != nil {\E\n\Q                    // Any iterator reporting an error aborts the whole seek.\E\n\Q                    return .none\E\n\Q                }\E~~' "$MG"; run "$MG" "an erroring iterator does not abort the seek"
perl -0pi -e 's~\Q        curr = nil\E\n\Q        return .none\E\n\Q    }\E~        return .none\n    }~' "$MG"; run "$MG" "an exhausted seek leaves curr in place"

echo "=== ChainedSeriesMerge ==="
perl -0pi -e 's~\Q    return SeriesEntry(lset: series\E\Q[0].labels()) { it in\E~    return SeriesEntry(lset: series[series.count - 1].labels()) { it in~' "$MG"; run "$MG" "the chained series takes its labels from the LAST input (INERT: the inputs are equal by construction)"
perl -0pi -e 's~\Q    if series.isEmpty {\E\n\Q        return nil\E\n\Q    }\E\n\Q    return SeriesEntry\E~    return SeriesEntry~' "$MG"; run "$MG" "the empty-input guard is removed"
perl -0pi -e 's~\Q        built.append(s.iterator(i < csi.reuseSlots.count ? csi.reuseSlots\E\Q[i] : nil))\E~        built.append(s.iterator(nil))~' "$MG"; run "$MG" "the reuse slots are never offered back (INERT: the block iterators ignore the argument)"
perl -0pi -e 's~\Q        if csi.iterators.count < length {\E~        if csi.iterators.count <= length {~' "$MG"; run "$MG" "the reuse capacity test is off by one"

echo "=== the compacting chunk merger ==="
perl -0pi -e 's~\Q            if next.minTime > oMaxTime {\E~            if next.minTime >= oMaxTime {~' "$MG"; run "$MG" "a chunk TOUCHING the run at one timestamp is treated as disjoint"
perl -0pi -e 's~\Q            if next.minTime > oMaxTime {\E\n\Q                break\E\n\Q            }\E~~' "$MG"; run "$MG" "the overlap test is removed, so every chunk joins the run"
perl -0pi -e 's~\Q                if next.maxTime > oMaxTime {\E\n\Q                    oMaxTime = next.maxTime\E\n\Q                }\E~~' "$MG"; run "$MG" "the run does not extend transitively"
perl -0pi -e 's~\Q                || (next.chunk?.bytes ?? \E\Q[]) != (prev.chunk?.bytes ?? [])\E~                || false~' "$MG"; run "$MG" "the duplicate test ignores the chunk BYTES"
perl -0pi -e 's~\Q            if next.minTime != prev.minTime || next.maxTime != prev.maxTime\E~            if true~' "$MG"; run "$MG" "no chunk is ever recognised as a perfect duplicate"
perl -0pi -e 's~\Q                prev = next\E~~' "$MG"; run "$MG" "the duplicate test always compares against the FIRST chunk"
perl -0pi -e 's~\Q        overlapping.append(newChunkToSeriesDecoder(Labels.empty, curr))\E~        overlapping.insert(newChunkToSeriesDecoder(Labels.empty, curr), at: 0)~' "$MG"; run "$MG" "the current chunk is merged FIRST rather than last"
perl -0pi -e 's~\Q        if overlapping.isEmpty {\E\n\Q            return true\E\n\Q        }\E~~' "$MG"; run "$MG" "a non-overlapping chunk is re-encoded anyway"
perl -0pi -e 's~\Q        if encoded.next() {\E\n\Q            h!.push(encoded)\E\n\Q        }\E~~' "$MG"; run "$MG" "the re-encoder's later chunks are dropped"
perl -0pi -e 's~\Q        let iter = h!.pop()\E\n\Q        curr = iter.at()\E~        let iter = h!.pop()\n        curr = iter.at()\n        _ = iter~' "$MG"; run "$MG" "(equivalence probe, MUST SURVIVE) a no-op statement after the pop"

echo "=== the concatenating chunk merger ==="
perl -0pi -e 's~\Q        if iterators\E\Q[idx].err() != nil {\E\n\Q            return false\E\n\Q        }\E~~' "$MG"; run "$MG" "an erroring iterator is skipped rather than stopping the concatenation"
perl -0pi -e 's~\Q        if idx >= iterators.count {\E~        if idx > iterators.count {~' "$MG"; run "$MG" "the concatenation runs one iterator past the end"

echo "=== mergeResults, mergeStrings and the label limits ==="
perl -0pi -e 's~\Q    let i = lq.count / 2\E~    let i = 1~' "$MG"; run "$MG" "mergeResults folds left instead of splitting by half"
perl -0pi -e 's~\Q    let i = lq.count / 2\E~    let i = lq.count - 1~' "$MG"; run "$MG" "mergeResults splits off the LAST querier"
perl -0pi -e 's~\Q    if lq.count == 1 {\E\n\Q        return try resultsFn(lq\E\Q[0])\E\n\Q    }\E~~' "$MG"; run "$MG" "a single querier is not called directly"
perl -0pi -e 's~\Q    s1 = truncateToLimit(s1, hints)\E\n\Q    s2 = truncateToLimit(s2, hints)\E~~' "$MG"; run "$MG" "the halves are not truncated before merging"
perl -0pi -e 's~\Q    merged = truncateToLimit(merged, hints)\E~~' "$MG"; run "$MG" "the merged result is not truncated"
perl -0pi -e 's~\Q    if let hints, hints.limit > 0, s.count > hints.limit {\E~    if let hints, hints.limit > 0, s.count >= hints.limit {~' "$MG"; run "$MG" "truncateToLimit fires on an exactly-limit-sized list"
perl -0pi -e 's~\Q        return Array(s\E\Q[0..<hints.limit])\E~        return Array(s.suffix(hints.limit))~' "$MG"; run "$MG" "truncateToLimit keeps the LAST values"
perl -0pi -e 's~\Q    if let hints, hints.limit > 0, s.count > hints.limit {\E~    if let hints, hints.limit >= 0, s.count > hints.limit {~' "$MG"; run "$MG" "a label limit of zero truncates to nothing"
perl -0pi -e 's~\Q        if a\E\Q[i] == b[j] {\E\n\Q            res.append(a\E\Q[i])\E\n\Q            i += 1\E\n\Q            j += 1\E~        if a[i] == b[j] {\n            res.append(a[i])\n            res.append(b[j])\n            i += 1\n            j += 1~' "$MG"; run "$MG" "mergeStrings does not deduplicate"
perl -0pi -e 's~\Q        } else if goStringLess(a\E\Q[i], b[j]) {\E~        } else if goStringLess(b[j], a[i]) {~' "$MG"; run "$MG" "mergeStrings compares the wrong way round"
perl -0pi -e 's~\Q    res.append(contentsOf: a\E\Q[i...])\E~~' "$MG"; run "$MG" "the left remainder is dropped"
perl -0pi -e 's~\Q    res.append(contentsOf: b\E\Q[j...])\E~~' "$MG"; run "$MG" "the right remainder is dropped"
perl -0pi -e 's~\Q        ws.merge(r.warnings)\E~~g' "$MG"; run "$MG" "mergeResults does not accumulate warnings"
perl -0pi -e 's~\Q    if lq.isEmpty {\E\n\Q        return (\E\Q[], Annotations())\E\n\Q    }\E~~' "$MG"; run "$MG" "the empty-querier base case is removed"

echo "=== the LabelValues / LabelNames error wrappers ==="
perl -0pi -e 's~\Q            return "LabelValues() from merge generic querier for label \E~            return "LabelValues from merge generic querier for label ~' "$MG"; run "$MG" "the LabelValues error prefix loses its parentheses"
perl -0pi -e 's~\Q            return "LabelNames() from merge generic querier: \E~            return "LabelNames() from merge querier: ~' "$MG"; run "$MG" "the LabelNames error prefix is reworded"
perl -0pi -e 's~\Q            throw MergeQuerierError.labelValues(name: name, underlying: e.underlying)\E~            throw e.underlying~' "$MG"; run "$MG" "the LabelValues error is not wrapped"
perl -0pi -e 's~\Q            throw MergeQuerierError.labelNames(underlying: e.underlying)\E~            throw e.underlying~' "$MG"; run "$MG" "the LabelNames error is not wrapped"

echo "=== Close, and errors.Join ==="
perl -0pi -e 's~\Q            do { try querier.close() } catch { errs.append(error) }\E~            try querier.close()~' "$MG"; run "$MG" "Close stops at the first failing querier"
perl -0pi -e 's~\Q        if let joined = goErrorsJoin(errs) { throw joined }\E~        if let first = errs.compactMap({ \$0 }).first { throw first }~' "$MG"; run "$MG" "Close throws only the first error rather than the join"
perl -0pi -e 's~\Q            if i > 0 { out += \E[^\n]*~            if i > 0 { out += "; " }~' "$GE"; run "$GE" "errors.Join separates with a semicolon"
perl -0pi -e 's~\Q    if kept.isEmpty { return nil }\E~    if false { return nil }~' "$GE"; run "$GE" "errors.Join returns an empty joined error rather than nil"

echo "=== lazy.go ==="
perl -0pi -e 's~\Q        if let set { return set.next() }\E~~' "$LZ"; run "$LZ" "the lazy set re-initialises on every Next"
perl -0pi -e 's~\Q        let (s, ok) = initialise()\E\n\Q        set = s\E\n\Q        return ok\E~        let (s, _) = initialise()\n        set = s\n        return s.next()~' "$LZ"; run "$LZ" "the lazy set advances again instead of trusting the initialiser"
perl -0pi -e 's~\Q        let (s, ok) = initialise()\E\n\Q        set = s\E\n\Q        return ok\E~        let (s, ok) = initialise()\n        set = s\n        return ok \&\& false~' "$LZ"; run "$LZ" "the lazy set always reports no data on the first Next"
perl -0pi -e 's~\Q    public func err() -> (any Error)? { set?.err() }\E~    public func err() -> (any Error)? { nil }~' "$LZ"; run "$LZ" "the lazy set never reports its inner error"
perl -0pi -e 's~\Q    public func warnings() -> Annotations { set?.warnings() ?? Annotations() }\E~    public func warnings() -> Annotations { Annotations() }~' "$LZ"; run "$LZ" "the lazy set never reports its inner warnings"
perl -0pi -e 's~\Q    public func at() -> E? { set?.at() }\E~    public func at() -> E? { nil }~' "$LZ"; run "$LZ" "the lazy set never yields a series"
perl -0pi -e 's~\Q    public func warnings() -> Annotations { annotations }\E~    public func warnings() -> Annotations { Annotations() }~' "$LZ"; run "$LZ" "warningsOnlySeriesSet drops its warnings"
perl -0pi -e 's~\Q    public func err() -> (any Error)? { error }\E~    public func err() -> (any Error)? { nil }~' "$LZ"; run "$LZ" "errorOnlySeriesSet drops its error"

echo "=== secondary.go ==="
perl -0pi -e 's~\Q            return try base.labelValues(ctx, name: name, hints: hints, matchers: matchers)\E\n\Q        } catch {\E~            return try base.labelValues(ctx, name: name, hints: hints, matchers: matchers)\n        } catch let e where false {\n            throw e\n        } catch {~' "$SC"; run "$SC" "a secondary LabelValues error path is reshaped (equivalence probe, MUST SURVIVE)"
perl -0pi -e 's~\Q        do {\E\n\Q            return try base.labelValues(ctx, name: name, hints: hints, matchers: matchers)\E\n\Q        } catch {\E\n\Q            var w = Annotations()\E\n\Q            return (\E\Q[], w.add(error: error))\E\n\Q        }\E~        return try base.labelValues(ctx, name: name, hints: hints, matchers: matchers)~' "$SC"; run "$SC" "a secondary LabelValues error is NOT demoted to a warning"
perl -0pi -e 's~\Q                        var withErr = ws\E\n\Q                        withErr.add(error: err)\E~                        var withErr = Annotations()\n                        withErr.add(error: err)~' "$SC"; run "$SC" "a failing secondary set loses the warnings it had already produced"
perl -0pi -e 's~\Q                        withErr.add(error: err)\E~~' "$SC"; run "$SC" "a failing secondary set does not carry its error as a warning"
perl -0pi -e 's~\Q                        asyncSets\E\Q[curr] = WarningsOnlySeriesSet<E>(withErr)\E~                        asyncSets[i] = WarningsOnlySeriesSet<E>(withErr)~' "$SC"; run "$SC" "the error is attributed to the FAILING set rather than to the current one"
perl -0pi -e 's~\Q                        for j in asyncSets.indices where j != curr {\E\n\Q                            asyncSets\E\Q[j] = NoopGenericSeriesSet<E>()\E\n\Q                        }\E~~' "$SC"; run "$SC" "the all-or-nothing rule is dropped: the other sets keep their data"
perl -0pi -e 's~\Q                        break\E\n\Q                    }\E\n\Q                    // Exhausted set.\E~                    }\n                    // Exhausted set.~' "$SC"; run "$SC" "the once-loop continues past a failing set"
perl -0pi -e 's~\Q                    asyncSets\E\Q[i] = WarningsOnlySeriesSet<E>(ws)\E~~' "$SC"; run "$SC" "an exhausted secondary set is not replaced by a warnings-only set"
perl -0pi -e 's~\Q                    if set.next() { continue }\E~                    if !set.next() { continue }~' "$SC"; run "$SC" "the once-loop treats a set with data as exhausted"
perl -0pi -e 's~\Q            if set is WarningsOnlySeriesSet<E> || set is NoopGenericSeriesSet<E> {\E\n\Q                return (set, false)\E\n\Q            }\E~~' "$SC"; run "$SC" "a replaced secondary set reports that it holds data"
perl -0pi -e 's~\Q            return (set, true)\E~            return (set, set.next())~' "$SC"; run "$SC" "a surviving secondary set is advanced a second time"
perl -0pi -e 's~\Q        if done {\E~        if false {~' "$SC"; run "$SC" "Select after the first Next is allowed (INERT: each corpus pass builds fresh queriers)"
perl -0pi -e 's~\Q            if !onceDone {\E~            if true {~' "$SC"; run "$SC" "the once-guard is removed, so every set re-runs the all-or-nothing pass"
perl -0pi -e 's~\Q    public func close() throws { try base.close() }\E~    public func close() throws { try? base.close() }~' "$SC"; run "$SC" "a secondary's Close error is swallowed"

echo "=== generic.go Part A ==="
perl -0pi -e 's~\Q    public func at() -> AnySeries? { base.at().map(AnySeries.init) }\E~    public func at() -> AnySeries? { nil }~' "$GN"; run "$GN" "the series-set adapter never yields a series"
perl -0pi -e 's~\Q    public func warnings() -> Annotations { base.warnings() }\E~    public func warnings() -> Annotations { Annotations() }~g' "$GN"; run "$GN" "the adapters drop the wrapped set's warnings"
perl -0pi -e 's~\Q    public func err() -> (any Error)? { base.err() }\E~    public func err() -> (any Error)? { nil }~g' "$GN"; run "$GN" "the adapters drop the wrapped set's error"
perl -0pi -e 's~\Q    { elements in f(elements.map(\E[^\n]*\QAnySeries.init) }\E~    { elements in f(elements.map { \$0.base }.reversed()).map(AnySeries.init) }~' "$GN"; run "$GN" "the series merge adapter reverses its inputs"
perl -0pi -e 's~\Q    { elements in f(elements.map(\E[^\n]*\QAnyChunkSeries.init) }\E~    { elements in f(elements.map { \$0.base }.reversed()).map(AnyChunkSeries.init) }~' "$GN"; run "$GN" "the chunk merge adapter reverses its inputs"
perl -0pi -e 's~\Q    public func next() -> Bool { false }\E~    public func next() -> Bool { true }~' "$GN"; run "$GN" "the noop generic set claims to have data"

echo "=== series.go's chunk half, which the compacting merger re-encodes through ==="
perl -0pi -e 's~\Qpublic let seriesToChunkEncoderSplit = 120\E~public let seriesToChunkEncoderSplit = 60~' "$SK"; run "$SK" "the re-encoder cuts every 60 samples"
perl -0pi -e 's~\Qpublic let seriesToChunkEncoderSplit = 120\E~public let seriesToChunkEncoderSplit = 100000~' "$SK"; run "$SK" "the re-encoder never cuts"
perl -0pi -e 's~\Q            if typ != lastType || lastHadST != hasST || i >= seriesToChunkEncoderSplit {\E~            if typ != lastType || lastHadST != hasST || i > seriesToChunkEncoderSplit {~' "$SK"; run "$SK" "the sample-count cut is off by one"
perl -0pi -e 's~\Q                mint = Int64.max\E\n\Q                // maxt is NOT reset\E[^\n]*~                mint = Int64.max\n                maxt = Int64.min~' "$SK"; run "$SK" "maxt IS reset when a chunk is cut (INERT: it is overwritten before it is read)"
perl -0pi -e 's~\Q            if mint == Int64.max {\E\n\Q                mint = t\E\n\Q            }\E~            mint = t~' "$SK"; run "$SK" "mint tracks the LAST sample rather than the first"
perl -0pi -e 's~\Q            maxt = t\E\n\Q            if mint == Int64.max {\E~            if mint == Int64.max {~' "$SK"; run "$SK" "maxt is never updated"
perl -0pi -e 's~\Q        chks = appendChunk(chks, mint, maxt, chk)\E\n\n\Q        if let existing {\E~        if let existing {~' "$SK"; run "$SK" "the final chunk is never appended"
perl -0pi -e 's~\Q    guard let chk else { return chks }\E~    guard let chk else { return chks }\n    if chks.isEmpty { return chks }~' "$SK"; run "$SK" "appendChunk drops the first chunk"
perl -0pi -e 's~\Q        idx += 1\E\n\Q        return idx < chks.count\E~        idx += 1\n        return idx <= chks.count~' "$SK"; run "$SK" "the list chunk iterator runs one past the end"

echo
echo "Every SURVIVED above is argued below. A survivor is a hypothesis until it is."
cat <<'ARGUED'

  THE TWO DELIBERATELY INERT CONTROLS, which must survive or the sweep is measuring nothing:

  * "(equivalence probe, MUST SURVIVE) a no-op statement after the pop" — `_ = iter` cannot change
    anything.
  * "a secondary LabelValues error path is reshaped (equivalence probe, MUST SURVIVE)" — an extra
    `catch let e where false` arm, which can never be entered.

    If either reports `broke`, the sweep is measuring build noise and every other verdict in the run
    is suspect.

  PROVABLE TAUTOLOGIES — the perturbation is the same program, and here is why:

  * "the retry loop exits even with an empty currentSets". `currentSets` is never empty at that
    point. `currentLabels` is read from `heap.peek()` immediately after the `heap.isEmpty` guard, so
    the first pop of the following loop always compares equal and always appends. Upstream's
    `if len(c.currentSets) != 0 { break }` is defensive against a shape its own `Next` cannot
    produce. Quirk 160's shape.

  * "the empty-querier base case is removed". `mergeResults` is reached only from
    `mergeGenericQuerier`, which by construction holds at least two queriers, and `count / 2 >= 1`
    for `count >= 2` — so both halves of every split are non-empty and `lq.isEmpty` is unreachable.

  * "truncateToLimit fires on an exactly-limit-sized list". `s[0..<limit]` of a list of exactly
    `limit` elements is that list. `>` versus `>=` differ only in whether a copy is made.

  * "the no-op branch seeks to t rather than to lastT". The branch is entered only when
    `lastT >= t`, and the current iterator is positioned AT `lastT`. `Seek` is "advance to the first
    sample at or after X" and never moves backwards, so `seek(lastT)` and `seek(t <= lastT)` both
    leave it exactly where it is and return the same value type. Upstream could have written either.

  * "mergeResults folds left instead of splitting by half", "mergeResults splits off the LAST
    querier", "the halves are not truncated before merging" — three controls, one proof. With a
    limit of k, every truncation keeps a list's k SMALLEST values, and the global k smallest values
    are each among their own querier's k smallest. So any binary tree over the same leaves, with or
    without intermediate truncation, produces the same k. `SplitByHalf` and the two inner
    `truncateToLimit` calls are a cost saving — smaller merges at every level — and not a contract.
    Note the boundary: "the merged result is not truncated" BROKE, because that one loses the limit.

  ESTABLISHED EQUIVALENCES — argued from behaviour the corpus records, not from inspection:

  * "a single-set series still goes through the merge function". `ChainedSeriesMerge([s])` builds a
    chain over one iterator, which for a block series yields the same samples in the same order; the
    two chunk mergers over one series find no overlap and pass the chunks through untouched. The
    corpus records the chunk BYTES and the seek script's VALUES, so a re-encode or a repositioning
    would show up — this is established over that evidence rather than assumed, which is quirk 159's
    rule. Upstream's early return is a cost saving. Kept because it is upstream's shape, and because
    a Head series (whose iterator can fail mid-way) may yet make it live.

  * "the current iterator never keeps the cursor". Forcing the push-and-pop path pushes `curr` onto
    a heap whose root is strictly later, so `curr` is immediately popped back and `seek(currT)`
    repositions it where it already was. The only difference is `iteratorChanged`, which feeds
    `consecutive`, which only the two histogram accessors read — see the next entry.

  * "the duplicate test always compares against the FIRST chunk". `prev` tracks the last chunk ADDED
    to the overlap so that a run of identical chunks collapses. Comparing against `curr` forever
    admits chunks the real code would skip — but a chunk admitted twice contributes the same
    timestamps, and `chainSampleIterator` drops a duplicate timestamp, so the merged samples are
    identical. `oMaxTime` cannot differ either, because a skipped chunk has the same bounds as the
    one it duplicates. `prev` is a decoding cost saving.

  * "an exhausted seek leaves curr in place". After the fan-out finds nothing, every base iterator
    has been seeked past its end, so the next `Next()` exhausts and nils `curr` anyway. The
    difference is only visible to a caller that reads `At()` after a failed `Seek` — where upstream
    PANICS on the nil, which a fixture cannot record (quirk 191's family). Reproduced because
    upstream's nil is the thing that turns that misuse into a crash rather than a stale sample.

  DECLARED CORPUS GAPS, each with the slice that closes it:

  * "the fan-out forwards sortSeries instead of forcing true". Every corpus case selects unsorted,
    and a block querier honours `sortSeries` by doing nothing — `Reader.SortedPostings` is the
    identity for a block, because postings are in ref order and refs are assigned in label order
    (§6v). So the flag cannot change a block's answer. **Closed by the HEAD**, whose
    `SortedPostings` really does sort; that is §7j, which is the first slice to merge a Head with a
    block.

  * "secondaries are ordered BEFORE primaries". A DELIBERATE gap, not an oversight. The order of
    `seriesSets` is observable only through the label-set heap's tie-break, and upstream randomises
    exactly that whenever a secondary is present (goroutines, unbuffered channel — exception 240).
    Every case with a secondary is therefore built so no tie can arise. Closing this would mean
    pinning a coin flip. **Unclosable by construction**, and recorded as such rather than left to
    look like an omission.

  * "the consecutive flag is inverted", and with it the `iteratorChanged` half of "the current
    iterator never keeps the cursor". `consecutive` is read in exactly two places, `AtHistogram` and
    `AtFloatHistogram`, where it downgrades a counter-reset hint across a change of source
    iterator. `PromChunkEnc` has no histogram chunk encoding yet (`newEmptyChunk` answers for XOR
    and XOR2 only), so `blockfixture.go` can only write float chunks and no case can reach either
    accessor. **Closed by the histogram encodings** (§7f's deferral), not by this slice.

  * "a duplicate timestamp is emitted rather than dropped" and "any non-increasing timestamp is
    dropped" — the `if currT == lastT { continue }` at the TOP of `Next`'s loop. This is worth
    reading carefully, because it is not the duplicate rule you would expect it to be: the
    cross-iterator de-duplication is done by the `if currT != lastT { break }` at the BOTTOM, and
    that control breaks. The top check fires only when `curr.next()` itself yields a timestamp equal
    to the last one emitted — which needs two samples with the same timestamp inside ONE base
    iterator, i.e. a chunk with a repeated timestamp. A block writer cannot produce one. **Closed by
    malformed chunk bytes**, the same input §6w's two remaining read-path gaps wait on, and §7i(a)
    has now made those producible.

  * "an erroring iterator does not abort the seek" and "an erroring iterator is skipped rather than
    stopping the concatenation". Both need a chunk iterator that FAILS mid-iteration. A block's
    cannot. Same closing input as the entry above.

  * "the reuse slots are never offered back" and "the reuse capacity test is off by one". Go's
    `getChainSampleIterator` reuse exists to avoid an allocation: the recycled iterator is passed to
    `Series.Iterator(it)`, and `BlockSeriesEntry.iterator(_:)` ignores it and returns the populate
    iterator the set already built. So there is nothing to observe until a `Series` that HONOURS the
    reuse buffer is merged — `NewListSeries` is one, and it reaches the merge through
    `NewMergeSeriesSet`, which is Phase 9's caller. Quirk 163's shape.

  * "the chained series takes its labels from the LAST input". A tautology about the CALLER:
    `ChainedSeriesMerge` is only ever reached from `genericMergeSeriesSet.At()`, which only passes
    it series the heap judged EQUAL by `labels.Compare`. Upstream's own comment says the same ("It
    expects the same labels for each given series"). A future caller that merged unequal labels
    would make it live, which is why the port keeps `series[0]`.

  * "maxt IS reset when a chunk is cut". Upstream says why, in a comment repeated three times:
    "maxt is immediately overwritten below which is why setting it here won't make a difference."
    The reset would sit at the top of the cut branch, and `maxt = t` runs unconditionally at the
    bottom of every iteration before anything reads it. Reproduced anyway, because the symmetry with
    `mint` — which is NOT dead; the `Int64.max` sentinel is how the first sample of a chunk is
    recognised, and perturbing it breaks — is what makes the loop readable.
ARGUED
