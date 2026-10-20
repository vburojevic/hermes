#!/usr/bin/env bash
# Publishes Tools/hermes-app-widgets to its public repo (vburojevic/hermes-app-widgets), the source
# `hermes plugins install vburojevic/hermes-app-widgets` reads. The plugin holds no secrets; the maintainers'
# spec sync script stays here.
#
# Usage: Scripts/publish-widgets-plugin.sh "commit message"
set -euo pipefail
cd "$(dirname "$0")/.."
MESSAGE="${1:?commit message}"
REPO="vburojevic/hermes-app-widgets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$REPO" "$WORK/repo" -- --quiet
rsync -a --delete --exclude .git --exclude .claude --exclude .pytest_cache --exclude __pycache__ --exclude '*.pyc' --exclude sync-spec.py Tools/hermes-app-widgets/ "$WORK/repo/"
cd "$WORK/repo"
git add -A
if git diff --cached --quiet; then
  echo "nothing to publish"
  exit 0
fi
# Public commits carry the GitHub noreply address, never a personal email.
git -c user.email="2234474+vburojevic@users.noreply.github.com" commit -q -m "$MESSAGE"
git push -q origin HEAD
echo "published $(git rev-parse --short HEAD) to $REPO"
