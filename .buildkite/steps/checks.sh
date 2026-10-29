#!/usr/bin/env bash
# The `hermes-checks` pipeline's one job (.buildkite/checks.yml), on the mini's self-hosted `macos`
# queue, for every commit to main and nothing else (docs/development.md, Checks on main).
#
# It runs HermesKit's `swift test`, the relay's tests, and the iPhone and Mac Debug builds, which
# fail on any warning in our code (Scripts/check-build-warnings.sh). The builds sign ad hoc, with no
# identity, no imported keychain and no simulator booted. It reads no secret, and the tools run in an
# environment with nothing of the job's in it, so no agent token reaches their logs.
set -euo pipefail

# Main of this repository only, never a pull request or a fork: the mini holds the studio's signing
# keys. checks.yml says so too; this refuses anything else in case a pipeline setting ever doesn't.
case "${BUILDKITE_REPO:-}" in
  https://github.com/vburojevic/hermes|https://github.com/vburojevic/hermes.git|git@github.com:vburojevic/hermes.git) ;;
  *) echo "Checks run only for vburojevic/hermes, never a fork or another repository." >&2; exit 2 ;;
esac
[ "${BUILDKITE_PULL_REQUEST:-}" = false ] \
  || { echo "Checks never run for a pull request ('${BUILDKITE_PULL_REQUEST:-}')." >&2; exit 2; }
[ "${BUILDKITE_BRANCH:-}" = main ] \
  || { echo "Checks run only on main, not '${BUILDKITE_BRANCH:-}'." >&2; exit 2; }
# The Keychain tests need the desktop session, where the agent runs (its LaunchAgent, in gui/<uid>).
session="$(launchctl managername 2>/dev/null || true)"
[ "$session" = Aqua ] \
  || { echo "Checks run in the desktop (Aqua) session, where the Keychain tests can reach the login keychain, not '$session'." >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# The mini is shared: the checks yield to whatever else runs there.
renice -n 10 -p $$ >/dev/null
# An agent's environment can be minimal; Homebrew's tools (xcodegen) live here.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CHECKS="$ROOT_DIR/build/checks"
LOGS="$CHECKS/logs"
mkdir -p "$LOGS"
cleanup() {
  # swift test rewrites this and drops the app's pins (AGENTS.md).
  git -C "$ROOT_DIR" checkout -q -- Packages/HermesKit/Package.resolved 2>/dev/null || true
  rm -rf "${CHECKS:?}/swiftpm" "${CHECKS:?}/SourcePackages" "${CHECKS:?}/DerivedData-ios" "${CHECKS:?}/DerivedData-mac"
}
trap cleanup EXIT

# Only what the tools need, so nothing of the job's (BUILDKITE_AGENT_ACCESS_TOKEN among it) reaches
# them: xcodebuild writes every environment variable into its log as a build setting.
TOOL_ENV=(HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" PATH="$PATH"
  LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}")
[ -z "${DEVELOPER_DIR:-}" ] || TOOL_ENV+=(DEVELOPER_DIR="$DEVELOPER_DIR")

FAILED=()
step() { # <title> <log name> <folder> <command…>: one check, its output in its own log
  local title=$1 log="$LOGS/$2.log" dir=$3 status=0
  shift 3
  echo "--- $title"
  (cd "$dir" && env -i "${TOOL_ENV[@]}" "$@") >"$log" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    grep -E ': (fatal )?error: |✘|FAIL ' "$log" | sort -u | head -n 80 || true
    tail -n 40 "$log"
    echo "^^^ +++"
    echo "$title failed (exit $status); the whole log is the artifact $(basename "$log")."
    FAILED+=("$title")
    return 1
  fi
  tail -n 3 "$log"
}
build() { # <title> <log name> <destination> <DerivedData folder>: a Debug build without warnings in our code
  step "$1" "$2" "$ROOT_DIR" xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Debug \
    -destination "$3" -derivedDataPath "$CHECKS/$4" -clonedSourcePackagesDirPath "$CHECKS/SourcePackages" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    build || return 0
  Scripts/check-build-warnings.sh "$LOGS/$2.log" || { echo "^^^ +++"; FAILED+=("$1 (warnings)"); }
}

# The agent builds with the mini's selected Xcode (its DEVELOPER_DIR follows xcode-select).
echo "--- :mag: Xcode, Swift and the commit"
env -i "${TOOL_ENV[@]}" xcodebuild -version
env -i "${TOOL_ENV[@]}" swift --version 2>&1 | head -n 1
echo "${BUILDKITE_COMMIT:-$(git rev-parse HEAD)} on main"
step ":hammer_and_wrench: xcodegen generate" xcodegen "$ROOT_DIR" xcodegen generate || exit 1
step ":swift: swift test (HermesKit)" swift-test "$ROOT_DIR/Packages/HermesKit" \
  swift test --scratch-path "$CHECKS/swiftpm" || true
git checkout -q -- Packages/HermesKit/Package.resolved
step ":convex: Relay tests" relay "$ROOT_DIR/Relay" /bin/sh -c 'npm ci --no-audit --no-fund && npm test' || true
build ":iphone: iPhone Debug build" build-ios "generic/platform=iOS Simulator" DerivedData-ios
build ":desktop_computer: Mac Debug build" build-mac "platform=macOS" DerivedData-mac

if [ ${#FAILED[@]} -gt 0 ]; then
  failed="$(printf '%s, ' "${FAILED[@]}")"
  echo "+++ :x: Failed: ${failed%, }"
  exit 1
fi
echo "+++ :white_check_mark: Tests, relay tests and the iPhone and Mac builds passed, with no warnings in our code"
