#!/usr/bin/env bash
# The `hermes-release` pipeline's one job (.buildkite/release.yml), on the mini's self-hosted
# `macos` queue. Never a Buildkite-hosted Mac (caffeinated-buildkite).
#
# It readies the agent and runs Scripts/release.sh with the flags it takes on the Mac
# (--dry-run, --ios-only, --mac-only, --build-number). It reads no secret itself: release.sh reads
# each cluster secret where it's used, with `buildkite-agent secret get`, and gives it to the
# redactor first, so none sits in this job's environment, where xcodebuild would print it.
#
# Inputs, from the pipeline's form or the build's environment (which skips the form):
#   RELEASE_MODE          dry-run (the default) or release
#   RELEASE_PLATFORMS     both (the default), ios or mac
#   RELEASE_BUILD_NUMBER  a build number (yyMMddHHmm) to reuse; otherwise one is made and kept
#                         for the whole build, so a retried job ships under the same number
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
# An agent's environment can be minimal; Homebrew's tools (gh, jq, xcodegen, openssl@3) live here.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

[ "${BUILDKITE:-}" = true ] || { echo "This runs inside the hermes-release Buildkite job. On the Mac, run Scripts/release.sh." >&2; exit 2; }
# The YAML pins the queue; this refuses anything else in case a pipeline setting ever doesn't.
[ "${BUILDKITE_AGENT_META_DATA_QUEUE:-}" = macos ] \
  || { echo "Releases run only on the self-hosted macos queue, not '${BUILDKITE_AGENT_META_DATA_QUEUE:-}'." >&2; exit 2; }

echo "--- :clipboard: What to release"
MODE="${RELEASE_MODE:-$(buildkite-agent meta-data get release-mode --default dry-run)}"
PLATFORMS="${RELEASE_PLATFORMS:-$(buildkite-agent meta-data get release-platforms --default both)}"
FLAGS=()
case "$MODE" in
  dry-run) FLAGS+=(--dry-run) ;;
  release) ;;
  *) echo "Mode is '$MODE'; it's dry-run or release." >&2; exit 2 ;;
esac
case "$PLATFORMS" in
  both) ;;
  ios) FLAGS+=(--ios-only) ;;
  mac) FLAGS+=(--mac-only) ;;
  *) echo "Platforms is '$PLATFORMS'; it's both, ios or mac." >&2; exit 2 ;;
esac
BUILD_NUMBER="${RELEASE_BUILD_NUMBER:-$(buildkite-agent meta-data get release-build-number --default "")}"
if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER="$(date -u +%y%m%d%H%M)"
  buildkite-agent meta-data set release-build-number "$BUILD_NUMBER"
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]{10}$ ]] || { echo "The build number '$BUILD_NUMBER' isn't yyMMddHHmm." >&2; exit 2; }
FLAGS+=(--build-number "$BUILD_NUMBER")
echo "$MODE · $PLATFORMS · build $BUILD_NUMBER · ${BUILDKITE_BRANCH:-?} at ${BUILDKITE_COMMIT:-?}"

# The CHANGELOG push signs in over https with the job's GitHub token; an SSH clone would sidestep it.
case "${BUILDKITE_REPO:-}" in
  https://github.com/vburojevic/hermes|https://github.com/vburojevic/hermes.git) ;;
  *) echo "The pipeline clones '${BUILDKITE_REPO:-}'; it should be https://github.com/vburojevic/hermes.git." >&2; exit 2 ;;
esac

echo "--- :git: Full history and tags (the release notes run from the previous tag)"
git fetch --quiet --unshallow --tags origin 2>/dev/null || git fetch --quiet --tags --force origin
git fetch --quiet origin main
if [ "$MODE" = release ]; then
  # A release ships only what main has: the tag and the CHANGELOG commit are made from it.
  [ "${BUILDKITE_BRANCH:-}" = main ] || { echo "A release builds main, not '${BUILDKITE_BRANCH:-}'. A dry run can build any branch." >&2; exit 2; }
  git merge-base --is-ancestor HEAD origin/main || { echo "$(git rev-parse --short HEAD) isn't on origin/main." >&2; exit 2; }
fi

echo "--- :broom: What a killed release left on this agent"
# release.sh cleans up on exit, a cancel and a failure. Only a SIGKILL (a cancel past its grace
# period, a lost agent) skips that, so this job removes what such a run left: its keychain, its
# work folder and the App Store profiles it installed.
repair_keychains() { # the user's search list and default keychain, as a killed release can't have left them
  local line list=() default login="$HOME/Library/Keychains/login.keychain-db"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    case "$line" in ""|*/hermes-release-*.keychain-db) continue ;; esac
    [ -e "$line" ] && list+=("$line")
  done < <(security list-keychains -d user 2>/dev/null)
  case " ${list[*]-} " in *" $login "*) ;; *) [ -e "$login" ] && list+=("$login") ;; esac
  [ ${#list[@]} -eq 0 ] || security list-keychains -d user -s "${list[@]}"
  default="$(security default-keychain -d user 2>/dev/null || true)"
  default="${default#"${default%%[![:space:]]*}"}"; default="${default#\"}"; default="${default%\"}"
  case "$default" in */hermes-release-*.keychain-db) default="" ;; esac
  if { [ -z "$default" ] || [ ! -e "$default" ]; } && [ -e "$login" ]; then
    security default-keychain -d user -s "$login"
    echo "the default keychain is the login keychain again"
  fi
}
shopt -s nullglob
for keychain in "$HOME"/Library/Keychains/hermes-release-*.keychain-db; do
  security delete-keychain "$keychain" 2>/dev/null || rm -f "$keychain"
  echo "removed $(basename "$keychain")"
done
repair_keychains
for work in "${TMPDIR:-/tmp}"/hermes-release.*; do
  find "$work" -type f -exec rm -P -f {} + 2>/dev/null || true
  rm -rf "$work"
  echo "removed $(basename "$work")"
done
for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
  name="$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)"
  case "$name" in
    "Hermes App Store"|"Hermes Notifications App Store"|"Hermes Requests App Store"|"Hermes Widgets App Store")
      rm -f "$profile"; echo "removed the profile $name" ;;
  esac
done
shopt -u nullglob

echo "--- :package: Release tools"
# The vendor's arm64 build of a pinned asc, checked against the SHA-256 its release publishes
# (asc_5.10.0_checksums.txt), first on PATH: the same pin as the studio's other release pipelines.
ASC_VERSION="5.10.0"
ASC_URL="https://github.com/rudrankriyam/App-Store-Connect-CLI/releases/download/${ASC_VERSION}/asc_${ASC_VERSION}_macOS_arm64"
ASC_SHA256="65ec014b988fb9d2160cdbe60792a1470a7cba9572bccb240a0fcd81ae93ad1a"
TOOLS="$ROOT_DIR/build/release-tools"
rm -rf "$TOOLS" && mkdir -p "$TOOLS"
curl -fsSL --retry 3 --max-time 300 -o "$TOOLS/.asc-download" "$ASC_URL" \
  || { echo "Couldn't download asc $ASC_VERSION from $ASC_URL." >&2; exit 1; }
asc_sum="$(shasum -a 256 "$TOOLS/.asc-download")"; asc_sum="${asc_sum%% *}"
[ "$asc_sum" = "$ASC_SHA256" ] \
  || { echo "asc $ASC_VERSION has SHA-256 $asc_sum, not the pinned $ASC_SHA256. Nothing from it ran." >&2; exit 1; }
mv "$TOOLS/.asc-download" "$TOOLS/asc" && chmod 755 "$TOOLS/asc"
export PATH="$TOOLS:$PATH"
[ "$(command -v asc)" = "$TOOLS/asc" ] || { echo "PATH finds asc at '$(command -v asc)', not the pinned copy." >&2; exit 1; }
case "$(asc --version 2>&1 || true)" in
  "$ASC_VERSION"*) echo "asc $ASC_VERSION (pinned, sum verified)" ;;
  *) echo "The pinned asc doesn't report $ASC_VERSION." >&2; exit 1 ;;
esac
missing=()
for tool in xcodebuild xcrun python3 jq gh curl git security codesign hdiutil; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[ -x /opt/homebrew/opt/openssl@3/bin/openssl ] || [ -x /opt/homebrew/bin/openssl ] || missing+=("openssl@3")
[ ${#missing[@]} -eq 0 ] || { echo "This agent is missing: ${missing[*]}." >&2; exit 1; }
echo "$(xcodebuild -version | head -1) · $(gh --version | head -1) · $(jq --version)"

echo "--- :rocket: Scripts/release.sh ${FLAGS[*]}"
# A release is long but not urgent, and the mini is shared: it yields to everything else. exec
# makes release.sh the job's own process, so a cancel's TERM reaches it and its cleanup runs.
exec nice -n 15 Scripts/release.sh "${FLAGS[@]}"
