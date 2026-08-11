#!/usr/bin/env bash
# SOURCED, not executed. The shared half of every negative-control sweep.
#
# There is exactly one thing here, and it is the thing three separate sweeps got wrong before it was
# shared: **running one perturbed build under a time budget and turning the result into a verdict.**
#
# ## Two failure modes, both from real runs
#
# 1. **A perturbation can HANG rather than fail.** `intersectPostings.Seek` loops until its target
#    settles, so a control that lets it accept an equal value makes it non-terminating — and the first
#    run of `controls-postings.sh` stalled for half an hour at `=== Intersect ===` with no output. A
#    control that never returns is a control that broke; it has to be killed and *reported*.
#
# 2. **`timeout(1)` is GNU coreutils and is NOT on a stock macOS.** Five sweeps called it directly, so
#    on a machine without Homebrew's coreutils `timeout 900 swift build` exits 127, the `if !` fires,
#    and **every control reports COMPILE** — a sweep that looks like it ran and measured nothing. That
#    is strictly worse than a hang, because a hang is obvious and this is not. Hence background-and-
#    poll, which needs nothing but the shell.
#
# ## The verdict rules, in order
#
#   hung                          -> broke (hung)
#   log has ✘ or `error:`         -> broke
#   log has `Test run with`       -> SURVIVED
#   neither                       -> broke (trapped)
#
# That last line is why the check is not just a grep for ✘: a Swift **trap** takes the test process
# down without printing a failure, so the absence of any "Test run with" line is itself the signal.
# `controls-aggregation.sh` had this and the chunkenc sweeps did not, which meant a trapping
# perturbation could read as SURVIVED there.
#
# ## Usage
#
#   source "$(dirname "$0")/lib/control-run.sh"
#   run() { control_verdict "$1" 'SuiteFilter'; restore; }
#
# `control_verdict` deliberately does NOT restore: each sweep keeps its own restore discipline, and
# they differ (some restore after the run, the aggregation family before the next patch).

# Seconds. Generous enough for a cold `swift test` over the engine suites, short enough that a hang is
# reported rather than waited on. Override per-sweep with `CONTROL_BUDGET=900 ./Scripts/controls-x.sh`.
CONTROL_BUDGET=${CONTROL_BUDGET:-600}

# control_verdict <name> <swift-test-filter> [column-width]
control_verdict() {
  local name="$1" filter="$2" width="${3:-56}"

  if ! swift build >/dev/null 2>&1; then
    printf "  %-${width}s COMPILE\n" "$name"
    return
  fi

  local log
  log=$(mktemp)
  swift test --filter "$filter" >"$log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$CONTROL_BUDGET" ]; do
    sleep 2
    waited=$((waited + 2))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    # The test binary is a child of swiftpm and outlives the kill above.
    pkill -9 -f swiftpm-testing-helper 2>/dev/null
    wait "$pid" 2>/dev/null
    printf "  %-${width}s broke (hung)\n" "$name"
  elif grep -qE '✘|error:' "$log"; then
    printf "  %-${width}s broke\n" "$name"
  elif grep -q 'Test run with' "$log"; then
    printf "  %-${width}s SURVIVED\n" "$name"
  else
    printf "  %-${width}s broke (trapped)\n" "$name"
  fi

  rm -f "$log"
}
