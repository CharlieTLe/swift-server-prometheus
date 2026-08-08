#!/usr/bin/env bash
# Regenerate committed golden fixtures from the Go oracle.
#
# Requires: Go toolchain, and the pinned upstream worktree described in
# docs/PORTING.md. `swift test` does NOT need either — it reads the committed
# output of this script.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
FIXTURES="$ROOT/Fixtures"
PIN="$ROOT/../../prometheus/prometheus-v3.13.2"

if [[ ! -d "$PIN" ]]; then
  echo "error: pinned upstream worktree missing: $PIN" >&2
  echo "create it with:" >&2
  echo "  git -C ../../prometheus/prometheus worktree add ../prometheus-v3.13.2 v3.13.2" >&2
  exit 1
fi

echo "==> building oracle"
(cd "$ROOT/oracle" && go build -o promoracle .)
ORACLE="$ROOT/oracle/promoracle"

echo "==> copying verbatim upstream testdata"
# PromQL conformance suite: 21 files, ~2,200 eval assertions. Copied verbatim,
# never edited. This is the acceptance gate for Phase 5.
mkdir -p "$FIXTURES/promql/testdata"
cp "$PIN"/promql/promqltest/testdata/*.test "$FIXTURES/promql/testdata/"

# Go's own regexp corpus, mined by the regex/parse suite. Committed rather than
# read from $GOROOT so the corpus does not vary with the local Go version.
mkdir -p "$FIXTURES/regex/gotestdata"
GOROOT_SRC=$(go env GOROOT)/src
for f in basic.dat repetition.dat nullsubexpr.dat re2-search.txt; do
  cp "$GOROOT_SRC/regexp/testdata/$f" "$FIXTURES/regex/gotestdata/$f"
done

# Generation reads the copies above, so it must come after them.
echo "==> generating fixtures"
# Absolute path: the oracle runs with CWD at the repo root, so a relative default
# would resolve outside it.
export REGEX_TESTDATA="$FIXTURES/regex/gotestdata"

for suite in $("$ORACLE" suites); do
  out="$FIXTURES/$suite.jsonl"
  mkdir -p "$(dirname "$out")"
  "$ORACLE" gen "$suite" > "$out"
done

echo "==> writing MANIFEST.json"
UPSTREAM_COMMIT=$(git -C "$PIN" rev-parse HEAD)
UPSTREAM_DESC=$(git -C "$PIN" describe --tags)
{
  echo "{"
  echo "  \"upstreamCommit\": \"$UPSTREAM_COMMIT\","
  echo "  \"upstreamDescribe\": \"$UPSTREAM_DESC\","
  echo "  \"goVersion\": \"$(go version | awk '{print $3}')\","
  echo "  \"files\": {"
  first=1
  while IFS= read -r f; do
    rel=${f#"$FIXTURES/"}
    sum=$(shasum -a 256 "$f" | awk '{print $1}')
    lines=$(wc -l < "$f" | tr -d ' ')
    [[ $first -eq 0 ]] && echo ","
    first=0
    printf '    "%s": { "sha256": "%s", "lines": %s }' "$rel" "$sum" "$lines"
  done < <(find "$FIXTURES" -type f \( -name '*.jsonl' -o -name '*.test' \) | sort)
  echo ""
  echo "  }"
  echo "}"
} > "$FIXTURES/MANIFEST.json"

echo
echo "==> summary"
du -sh "$FIXTURES"
find "$FIXTURES" -name '*.jsonl' | sort | while read -r f; do
  printf '  %8s lines  %s\n' "$(wc -l < "$f" | tr -d ' ')" "${f#"$FIXTURES"/}"
done
