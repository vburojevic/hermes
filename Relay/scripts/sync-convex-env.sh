#!/bin/bash
# Push Infisical /hermes/convex to a relay Convex deployment's env (merge/upsert; never deletes).
# usage: scripts/sync-convex-env.sh <dev|prod> [--dry-run|--apply]
# Values never reach stdout or argv: Convex reads the whole dotenv file.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PATH="$PATH:/opt/homebrew/bin"
PROJECT_ID="2afda67b-d54c-4256-808e-a6027fc22c15"
TARGET="${1:?usage: sync-convex-env.sh <dev|prod> [--dry-run|--apply]}"
MODE="${2:---dry-run}"
case "$TARGET" in
  dev) FLAG=() ;;
  prod) FLAG=(--prod) ;;
  *) echo "usage: sync-convex-env.sh <dev|prod> [--dry-run|--apply]" >&2; exit 2 ;;
esac
umask 077
TMP="$(mktemp)"
trap 'rm -P -f "$TMP" 2>/dev/null || rm -f "$TMP"' EXIT
infisical export --projectId "$PROJECT_ID" --env prod --path /hermes/convex --format dotenv --silent > "$TMP"
count="$(awk -F= '/^[A-Z][A-Z0-9_]*=/{c++} END{print c+0}' "$TMP")"
if [ "$MODE" = "--dry-run" ]; then
  echo "Would set $count vars on the $TARGET relay from Infisical /hermes/convex (names only):"
  awk -F= '/^[A-Z][A-Z0-9_]*=/{print "  " $1}' "$TMP" | sort
  exit 0
fi
[ "$count" -gt 0 ] || { echo "Infisical /hermes/convex is empty" >&2; exit 1; }
npx convex env set ${FLAG[@]+"${FLAG[@]}"} --from-file "$TMP" --force >/dev/null
echo "sync-convex-env: set $count vars on the $TARGET relay"
