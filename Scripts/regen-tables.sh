#!/usr/bin/env bash
# Regenerate the Swift source files that are derived from Go's own tables.
#
# These are checked in so `swift build` needs no Go toolchain, but they must never
# be hand-edited — the data (strconv.IsPrint, unicode.SimpleFold, the \p{...}
# category/script/property ranges) is far too large to transcribe reliably.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

echo "==> building oracle"
(cd "$ROOT/oracle" && go build -o promoracle .)
ORACLE="$ROOT/oracle/promoracle"

# table name -> destination
declare -a TARGETS=(
  "GoIsPrint:Sources/GoCompat/Generated/GoIsPrint.swift"
  "SimpleFold:Sources/PromRegex/Generated/SimpleFold.swift"
  "UnicodeGroups:Sources/PromRegex/Generated/UnicodeGroups.swift"
  "RegexGroups:Sources/PromRegex/Generated/RegexGroups.swift"
  "HistogramBounds:Sources/PromHistogram/Generated/HistogramBounds.swift"
)

for entry in "${TARGETS[@]}"; do
  name="${entry%%:*}"
  dest="${entry#*:}"
  mkdir -p "$(dirname "$ROOT/$dest")"
  "$ORACLE" tables "$name" > "$ROOT/$dest"
  printf '  %-14s -> %-52s %6s lines\n' "$name" "$dest" "$(wc -l < "$ROOT/$dest" | tr -d ' ')"
done

echo "==> done"
