#!/usr/bin/env bash
# Usage: Scripts/check-build-warnings.sh <xcodebuild log>…
# Prints each warning a build raised in our own files, once, and exits 1 if there was any. Our files
# are everything in this checkout except build output: build/ (DerivedData and the resolved packages
# when built the documented way), any DerivedData, SourcePackages or .build folder. Warnings in
# Apple's or other packages' code, and ones that name no file, aren't ours to fix here.
set -euo pipefail

[ $# -gt 0 ] || { echo "Usage: $0 <xcodebuild log>…" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_REAL="$(cd "$ROOT_DIR" && pwd -P)"

# A warning names its file first, with or without a line and column: the compiler's always have
# them, while actool, Info.plist processing and the project itself name only the file.
warnings="$(awk -v root="$ROOT_DIR/" -v real="$ROOT_REAL/" '
  { rel = "" }
  index($0, root) == 1 { rel = substr($0, length(root) + 1) }
  index($0, real) == 1 { rel = substr($0, length(real) + 1) }
  rel !~ /^[^:]+(:[0-9]+)?(:[0-9]+)?: warning: / { next }
  rel ~ /^build\// || rel ~ /(^|\/)(\.build|DerivedData|SourcePackages)\// { next }
  { print }
' "$@" | sort -u)"

if [ -n "$warnings" ]; then
  echo "$warnings"
  echo "$(printf '%s\n' "$warnings" | wc -l | tr -d ' ') warning(s) in our code."
  exit 1
fi
echo "No warnings in our code."
