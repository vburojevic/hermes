#!/usr/bin/env bash
# Hermes release, run by the studio's Buildkite pipeline hermes-release on the mini's self-hosted
# macos queue (.buildkite/release.yml), or on the trusted studio Mac (Caffeinated Code, team 29ZNGBT83H):
#   • iOS / iPadOS → App Store Connect "Hermes Agent App" (6822000332) → internal TestFlight
#     (the "Internal Testers" group has automatic access to every build).
#   • macOS → Developer ID signed, notarized and stapled DMG + Sparkle appcast, published as a
#     GitHub release on vburojevic/hermes-releases (the feed the app reads).
#   • iOS / iPadOS → also the public TestFlight: the "Public Beta" group, submitted for beta review.
#   • Source → the commit it was built from is tagged v<version>-<build> on vburojevic/hermes, with a
#     GitHub release there (pre-release while Hermes is in beta) and its section in CHANGELOG.md.
#
# Signing follows the studio's post-CAF-73 rules: the escrowed Apple Distribution and Developer ID
# G2 identities are read from Infisical prod /shared/apple/signing-caf73-20261005-e4rd77v8r4 into a
# temporary keychain that is deleted on exit; no certificates are minted. Upload and notarization
# use the studio ASC key 8BNZ87QD3D. Sparkle's EdDSA key is Infisical prod /hermes/ci.
# In a Buildkite job (BUILDKITE=true) the same secrets come from the cluster's mirrors instead,
# read one at a time with `buildkite-agent secret get` and given to the redactor before anything
# prints (see "Secrets" below and docs/releasing.md); without it the Mac's Infisical login is used.
# Release builds are the real "Hermes" (co.caffeinatedcode.hermes) with no demo code; the demo
# lives only in Debug ("Hermes Dev", co.caffeinatedcode.hermes.dev).
#
# Usage: Scripts/release.sh [--dry-run] [--build-number N]
#   --dry-run  sign, notarize and package, but upload/publish nothing.
# Every release ships iOS and macOS together (docs/releasing.md): there is no one-platform release. If
# one leg fails, fix the cause and release both again under a new build number.
set -euo pipefail
# A tight umask makes codesign write owner-only files that fail Mac validation (ITMS-90255).
umask 022
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ASC_BYPASS_KEYCHAIN=1
cd "$(dirname "$0")/.."

IOS=1 MAC=1 DRY_RUN=0
BUILD_NUMBER="$(date -u +%y%m%d%H%M)"
while [ $# -gt 0 ]; do
  case "$1" in
    --ios-only|--mac-only)
      echo "$1: Hermes releases ship iOS and macOS together, never one alone (docs/releasing.md)." >&2
      echo "Fix the failed leg and release both again under a new build number." >&2
      exit 2 ;;
    --dry-run) DRY_RUN=1 ;;
    --build-number) BUILD_NUMBER="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

TEAM_ID="29ZNGBT83H"
BUNDLE_ID="co.caffeinatedcode.hermes"
ASC_APP_ID="6822000332"
APP_GROUP="group.co.caffeinatedcode.hermes"
# App Store profiles on Distribution P6CMUV82AA, by bundle id: the app and its push extensions
# (docs/notifications.md). The iOS archive signs with them by hand (project.yml, Release).
IOS_PROFILES=(
  "$BUNDLE_ID|Hermes App Store"
  "$BUNDLE_ID.NotificationService|Hermes Notifications App Store"
  "$BUNDLE_ID.NotificationContent|Hermes Requests App Store"
  "$BUNDLE_ID.Widgets|Hermes Widgets App Store"
)
INFISICAL_PROJECT="2afda67b-d54c-4256-808e-a6027fc22c15"
ESCROW="/shared/apple/signing-caf73-20261005-e4rd77v8r4"
ASC_KEY_ID="8BNZ87QD3D"
ASC_ISSUER_ID="69a6de74-49bb-47e3-e053-5b8c7c11a4d1"
ASC_KEY_PATH="$HOME/.config/caffeinated-code/apple/AuthKey_${ASC_KEY_ID}.p8"
RELEASES_REPO="vburojevic/hermes-releases"
SOURCE_REPO="vburojevic/hermes"
BETA=1   # releases on SOURCE_REPO are pre-releases while Hermes is in public beta
ASC=(asc --profile "Caffeinated Code d.o.o.")   # the studio Mac's asc profile name, an identifier
VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"
OUT="$PWD/build/release/$VERSION-$BUILD_NUMBER"
AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
mkdir -p "$OUT"
log() { printf '\n--- %s\n' "$*"; }

# --- Secrets: the Mac's Infisical login, or the Buildkite job's cluster secrets ----------------------
# >>> secrets (sourced on its own by the static checks in docs/releasing.md)
# Values never reach argv, the environment of a build tool, or a log: each is read into a pipe or
# an owner-only file, and in Buildkite given to the redactor before anything else runs.
if [ "${BUILDKITE:-}" = true ]; then
  command -v buildkite-agent >/dev/null || { echo "BUILDKITE is set but buildkite-agent isn't on PATH"; exit 1; }
  CI_RELEASE=1
else
  CI_RELEASE=0
fi
cluster_secrets() { # <KEY[=CLUSTER_NAME]>… → one JSON object of KEY: value
  python3 -I -c '
import json, subprocess, sys
values = {}
for spec in sys.argv[1:]:
    key, _, name = spec.partition("=")
    name = name or key
    got = subprocess.run(["buildkite-agent", "secret", "get", name], capture_output=True, text=True)
    value = got.stdout.rstrip("\n") if got.returncode == 0 else ""
    if not value.strip():
        sys.exit("cluster secret " + name + " is empty or this pipeline may not read it")
    if subprocess.run(["buildkite-agent", "redactor", "add"], input=value, text=True, capture_output=True).returncode != 0:
        sys.exit("could not give " + name + " to the redactor")
    values[key] = value
json.dump(values, sys.stdout)
' "$@"
}
secrets_json() { # <Infisical folder> <KEY[=CLUSTER_NAME]>… → the secrets as JSON (Infisical's export, or a KEY: value object)
  local folder="$1"; shift
  if [ "$CI_RELEASE" = 1 ]; then
    cluster_secrets "$@"
  else
    infisical export --projectId "$INFISICAL_PROJECT" --env prod --path "$folder" --format json 2>/dev/null
  fi
}
secret_file() { # <Infisical folder> <KEY[=CLUSTER_NAME]> <file>: one secret, trimmed, into an owner-only file
  secrets_json "$1" "$2" | KEY="${2%%=*}" OUT_FILE="$3" python3 -I -c '
import json, os, sys
data = json.load(sys.stdin)
rows = data if isinstance(data, list) else data.get("secrets", data)
values = {(r.get("key") or r.get("secretKey")): (r.get("value") or r.get("secretValue")) for r in rows} if isinstance(rows, list) else rows
value = (values.get(os.environ["KEY"]) or "").strip()
if not value:
    sys.exit(os.environ["KEY"] + " is empty")
fd = os.open(os.environ["OUT_FILE"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, value.encode())
os.close(fd)
'
}
ci_asc_key() { # <work dir>: the cluster's ASC key as AuthKey_<id>.p8 there, once it is known to be this script's key
  secret_file - ASC_KEY_ID "$1/asc-key-id"
  secret_file - ASC_ISSUER_ID "$1/asc-issuer-id"
  [ "$(cat "$1/asc-key-id")" = "$ASC_KEY_ID" ] && [ "$(cat "$1/asc-issuer-id")" = "$ASC_ISSUER_ID" ] \
    || { echo "the cluster's ASC_KEY_ID or ASC_ISSUER_ID isn't the studio key this script signs with"; exit 1; }
  rm -f "$1/asc-key-id" "$1/asc-issuer-id"
  secret_file - ASC_PRIVATE_KEY_B64 "$1/asc-key.b64"
  ASC_KEY_PATH="$1/AuthKey_${ASC_KEY_ID}.p8"
  (umask 077 && base64 -d < "$1/asc-key.b64" > "$ASC_KEY_PATH") || { echo "ASC_PRIVATE_KEY_B64 isn't base64"; exit 1; }
  rm -P -f "$1/asc-key.b64"
  grep -q -- '-----BEGIN PRIVATE KEY-----' "$ASC_KEY_PATH" || { echo "ASC_PRIVATE_KEY_B64 doesn't decode to a private key"; exit 1; }
  buildkite-agent redactor add "$ASC_KEY_PATH"
}
github() { # <command…>: gh or git, with the job's GitHub token in that command's environment alone (Buildkite)
  if [ "$CI_RELEASE" = 1 ]; then GH_TOKEN="$(cat "$GITHUB_TOKEN_FILE")" "$@"; else "$@"; fi
}
# <<< secrets

log "Hermes $VERSION ($BUILD_NUMBER)$([ $DRY_RUN = 1 ] && echo ' — dry run')$([ "$CI_RELEASE" = 1 ] && echo " — Buildkite job ${BUILDKITE_JOB_ID:-}")"
if [ "$CI_RELEASE" = 0 ]; then
  [ -r "$ASC_KEY_PATH" ] || { echo "missing ASC key $ASC_KEY_PATH"; exit 1; }
fi
# The CHANGELOG commit carries the repository's identity, name included, taken from its own
# commits so a machine's global git config never decides it. Checked before anything ships.
GIT_EMAIL="2234474+vburojevic@users.noreply.github.com"
if [ $DRY_RUN = 0 ]; then
  GIT_NAME="$(git log -1 --fixed-strings --format=%an --author="$GIT_EMAIL" HEAD 2>/dev/null || true)"
  [ -n "$GIT_NAME" ] || { echo "no commit by $GIT_EMAIL in this checkout's history to take the committer name from"; exit 1; }
fi
# Archives build in a DerivedData of their own, so the Sparkle sign_update below is the one this
# release resolved, never another app's on a shared Mac.
RELEASE_DERIVED_DATA="$PWD/build/DerivedData-release"
# In Buildkite, anything shaped like a credential stays out of what xcodebuild prints: Xcode turns
# the environment into build settings, and its logs are kept as artifacts, which the redactor never
# sees. The job's own token is one; an agent hook could add more. Names only, never values.
XCB=(xcodebuild)
if [ "$CI_RELEASE" = 1 ]; then
  XCB=(env)
  while IFS= read -r name; do
    case "$name" in
      *TOKEN*|*SECRET*|*PASSWORD*|*PRIVATE_KEY*|*ACCESS_KEY*|*API_KEY*) XCB+=(-u "$name") ;;
    esac
  done < <(compgen -e)
  XCB+=(xcodebuild)
fi
command -v xcodegen >/dev/null && xcodegen generate --quiet
(cd Packages/HermesKit && swift test 2>&1 | grep -E "Test run with" | tail -1)

# --- Signing keychain (escrowed identities, temporary) ---------------------------------------
WORK="$(umask 077; mktemp -d -t hermes-release)"
KEYCHAIN="$WORK/signing.keychain-db"
# In Buildkite the keychain is the job's own, under a name the next job finds and deletes if this one
# was killed outright (.buildkite/steps/release.sh), alone in the search list and the default.
[ "$CI_RELEASE" = 1 ] && KEYCHAIN="$HOME/Library/Keychains/hermes-release-${BUILDKITE_JOB_ID:-$$}.keychain-db"
ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do ORIGINAL_KEYCHAINS+=("$(echo "$line" | tr -d '" ')"); done < <(security list-keychains -d user)
ORIGINAL_DEFAULT="$(security default-keychain -d user 2>/dev/null | tr -d '" ' || true)"
INSTALLED_PROFILES="$WORK/installed-profiles.txt"
cleanup() {
  if [ "$CI_RELEASE" = 1 ]; then
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    # What the user had, less any release keychain (a killed run's included) and anything gone;
    # the login keychain when nothing is left.
    local keep=() keychain login="$HOME/Library/Keychains/login.keychain-db" default="$ORIGINAL_DEFAULT"
    for keychain in ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}; do
      case "$keychain" in */hermes-release-*.keychain-db) continue ;; esac
      [ -e "$keychain" ] && keep+=("$keychain")
    done
    [ ${#keep[@]} -gt 0 ] || keep=("$login")
    security list-keychains -d user -s "${keep[@]}" 2>/dev/null || true
    case "$default" in */hermes-release-*.keychain-db) default="" ;; esac
    { [ -n "$default" ] && [ -e "$default" ]; } || default="$login"
    security default-keychain -d user -s "$default" 2>/dev/null || true
  else
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" 2>/dev/null || true
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  fi
  # Only the profiles this run added; one that was installed before stays.
  if [ -f "$INSTALLED_PROFILES" ]; then
    while IFS= read -r installed; do [ -n "$installed" ] && rm -f "$installed"; done < "$INSTALLED_PROFILES"
  fi
  find "$WORK" -type f -exec rm -P -f {} + 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
# A killed release (an ended session, Ctrl-C) must still delete the signing keychain: bash skips
# the EXIT trap on a fatal signal unless the signal is turned into an exit.
trap 'exit 130' INT HUP
trap 'exit 143' TERM

if [ "$CI_RELEASE" = 1 ]; then
  log "secrets (Buildkite cluster)"
  ci_asc_key "$WORK"
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  # No asc profile or keychain on the agent: the key comes from this job alone.
  ASC=(env -u ASC_PROFILE ASC_CONFIG_PATH="$WORK/asc-config.json" ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_PRIVATE_KEY_PATH="$ASC_KEY_PATH" asc)
  if [ $DRY_RUN = 0 ]; then
    GITHUB_TOKEN_FILE="$WORK/github-token"
    secret_file - GITHUB_TOKEN=HERMES_GITHUB_TOKEN "$GITHUB_TOKEN_FILE"
  fi
  echo "ASC key $ASC_KEY_ID$([ $DRY_RUN = 0 ] && echo ' and the GitHub token') loaded"
fi

log "signing keychain"
curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$WORK/AppleWWDRCAG3.cer"
curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$WORK/DeveloperIDG2CA.cer"
# Passwords travel on security's stdin, never argv; files are owner-only and shredded on exit.
# The Mac's keychain locks itself after two idle hours; a job's never does, so a long notarization
# wait can't lock it before the DMG is signed.
KEYCHAIN_SETTINGS="-lut 7200 "
[ "$CI_RELEASE" = 1 ] && KEYCHAIN_SETTINGS=""
secrets_json "$ESCROW" APPLE_DISTRIBUTION_CERT_BASE64 APPLE_DISTRIBUTION_CERT_PASSWORD \
    DEVELOPER_ID_APPLICATION_CERT_BASE64 DEVELOPER_ID_APPLICATION_CERT_PASSWORD \
  | WORK="$WORK" KEYCHAIN="$KEYCHAIN" KEYCHAIN_SETTINGS="$KEYCHAIN_SETTINGS" REDACT="$CI_RELEASE" python3 -c '
import base64, json, os, secrets, subprocess, sys
data = json.load(sys.stdin)
rows = data if isinstance(data, list) else data.get("secrets", data)
values = {(r.get("key") or r.get("secretKey")): (r.get("value") or r.get("secretValue")) for r in rows} if isinstance(rows, list) else rows
work, keychain = os.environ["WORK"], os.environ["KEYCHAIN"]
# OpenSSL 3 reads the escrow (AES-256/SHA-256 PKCS#12); /usr/bin/openssl is LibreSSL. Homebrew keeps
# it keg-only on some Macs, so its own prefix comes first.
OPENSSL = next((path for path in ("/opt/homebrew/opt/openssl@3/bin/openssl", "/opt/homebrew/bin/openssl")
                if os.access(path, os.X_OK)), None)
if not OPENSSL:
    sys.exit("OpenSSL 3 not found (brew install openssl@3)")
def one_time_password():
    # Made here and never printed; in Buildkite still given to the redactor, in case a tool echoes it.
    password = secrets.token_hex(24)
    if os.environ.get("REDACT") == "1":
        subprocess.run(["buildkite-agent", "redactor", "add"], input=password, text=True, capture_output=True, check=True)
    return password
def write_private(path, payload):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
def quoted(text):
    if any(ch in text for ch in "\"\\\n\r "):
        sys.exit("a password contains characters security -i cannot take safely")
    return "\"" + text + "\""
def security(command, tolerate=None):
    # One command per session; passwords ride on stdin, never argv.
    result = subprocess.run(["security", "-i"], input=command + "\n", text=True, capture_output=True)
    output = result.stdout + result.stderr
    if tolerate and tolerate in output:
        return
    if result.returncode != 0 or "returned 1" in output:
        sys.exit("security " + command.split()[0] + " failed")
password = one_time_password()
security(f"create-keychain -p {quoted(password)} {quoted(keychain)}")
security("set-keychain-settings " + os.environ["KEYCHAIN_SETTINGS"] + quoted(keychain))
security(f"unlock-keychain -p {quoted(password)} {quoted(keychain)}")
for name in ("APPLE_DISTRIBUTION", "DEVELOPER_ID_APPLICATION"):
    modern = os.path.join(work, name + ".p12")
    legacy = os.path.join(work, name + "-macos.p12")
    write_private(modern, base64.b64decode(values[name + "_CERT_BASE64"]))
    # macOS imports only 3DES/SHA-1 PKCS#12, so re-wrap it under a one-time password. The PEM
    # stage is owner-only inside the private temp folder and shredded at once; the escrow is unchanged.
    transfer = one_time_password()
    env = dict(os.environ, P12_IN=values[name + "_CERT_PASSWORD"], P12_OUT=transfer)
    stage = os.path.join(work, name + ".pem")
    unwrap = subprocess.run([OPENSSL, "pkcs12", "-in", modern, "-passin", "env:P12_IN", "-nodes"], env=env, capture_output=True)
    if unwrap.returncode != 0:
        sys.exit("could not read " + name)
    write_private(stage, unwrap.stdout)
    rewrap = subprocess.run([OPENSSL, "pkcs12", "-export", "-in", stage, "-passout", "env:P12_OUT",
                             "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-out", legacy],
                            env=env, capture_output=True)
    subprocess.run(["rm", "-P", "-f", stage, modern])
    if rewrap.returncode != 0:
        sys.exit("could not re-wrap " + name + ": " + rewrap.stderr.decode()[-200:])
    os.chmod(legacy, 0o600)
    security(f"import {quoted(legacy)} -k {quoted(keychain)} -P {quoted(transfer)} -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcrun")
    os.remove(legacy)
for cert in ("AppleWWDRCAG3.cer", "DeveloperIDG2CA.cer"):
    # The identities can carry these intermediates already.
    security(f"import {quoted(os.path.join(work, cert))} -k {quoted(keychain)}", tolerate="already exists")
security(f"set-key-partition-list -S apple-tool:,apple:,codesign: -s -k {quoted(password)} {quoted(keychain)}")
'
if [ "$CI_RELEASE" = 1 ]; then
  # Alone in the search list: a shared agent's other keychains make codesign fail (errSecInternalComponent).
  security list-keychains -d user -s "$KEYCHAIN"
  security default-keychain -d user -s "$KEYCHAIN"
else
  security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
fi
IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN")"
DIST_SHA="$(echo "$IDENTITIES" | awk '/Apple Distribution: .*\(29ZNGBT83H\)/ {print $2; exit}')"
DEVID_SHA="$(echo "$IDENTITIES" | awk '/Developer ID Application: .*\(29ZNGBT83H\)/ {print $2; exit}')"
[ -n "$DIST_SHA" ] && [ -n "$DEVID_SHA" ] || { echo "escrowed identities missing from the signing keychain"; exit 1; }
echo "Apple Distribution $DIST_SHA · Developer ID $DEVID_SHA (team $TEAM_ID)"

archive() { # <iOS|macOS>
  log "archive $1"
  # Both sign by hand with the escrowed identities, so no development certificate is ever minted:
  # iOS with project.yml's App Store profiles (push needs the production aps-environment), the Mac
  # with Developer ID (it has no entitlements, so no profile), re-signed after export below.
  local style=()
  [ "$1" = macOS ] && style=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVID_SHA" PROVISIONING_PROFILE_SPECIFIER=)
  "${XCB[@]}" archive -project Hermes.xcodeproj -scheme Hermes -configuration Release \
    -destination "generic/platform=$1" -archivePath "$OUT/Hermes-$1.xcarchive" -derivedDataPath "$RELEASE_DERIVED_DATA" \
    -allowProvisioningUpdates "${AUTH[@]}" DEVELOPMENT_TEAM="$TEAM_ID" ${style[@]+"${style[@]}"} \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" > "$OUT/archive-$1.log" 2>&1 \
    || { grep -E "error:" "$OUT/archive-$1.log" | head -20; exit 1; }
}

assert_release_app() { # <Info.plist> <binary> — the real app, never the demo build
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1")" = "$BUNDLE_ID" ] || { echo "wrong bundle id in $1"; exit 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1")" = "$BUILD_NUMBER" ] || { echo "wrong build number in $1"; exit 1; }
  if strings "$2" | grep -q HERMES_BOOTSTRAP; then echo "demo bootstrap compiled into a Release build"; exit 1; fi
}

# --- iOS → TestFlight ----------------------------------------------------------------------------
if [ $IOS = 1 ]; then
  log "App Store profiles"
  mkdir -p "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  PROFILE_MAP=""
  for entry in "${IOS_PROFILES[@]}"; do
    bundle="${entry%%|*}" name="${entry#*|}"
    id="$("${ASC[@]}" profiles list --name "$name" --profile-state ACTIVE --fields name --output json \
      | jq -r --arg name "$name" '[.data[] | select(.attributes.name == $name)] | if length == 1 then .[0].id else empty end')"
    [ -n "$id" ] || { echo "no single active profile named \"$name\""; exit 1; }
    profile="$WORK/$id.mobileprovision"
    "${ASC[@]}" profiles download --id "$id" --output "$profile" >/dev/null
    uuid="$(security cms -D -i "$profile" | plutil -extract UUID raw -o - -)"
    installed="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.mobileprovision"
    [ -e "$installed" ] || echo "$installed" >> "$INSTALLED_PROFILES"
    cp "$profile" "$installed"
    PROFILE_MAP+="<key>$bundle</key><string>$name</string>"
    echo "$name ($id) → $bundle"
  done

  archive iOS
  APP="$OUT/Hermes-iOS.xcarchive/Products/Applications/Hermes.app"
  assert_release_app "$APP/Info.plist" "$APP/Hermes"

  ios_options() { # <export|upload>
    cat > "$OUT/ExportOptions-iOS-$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$1</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$DIST_SHA</string>
  <key>provisioningProfiles</key><dict>$PROFILE_MAP</dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
  }
  log "export + validate iOS"
  ios_options export
  "${XCB[@]}" -exportArchive -archivePath "$OUT/Hermes-iOS.xcarchive" -exportPath "$OUT/ios" \
    -exportOptionsPlist "$OUT/ExportOptions-iOS-export.plist" "${AUTH[@]}" > "$OUT/export-iOS.log" 2>&1 \
    || { grep -E "error" "$OUT/export-iOS.log" | head -20; exit 1; }
  IPA="$(ls "$OUT"/ios/*.ipa)"
  # Push only works if the signed entitlements say so: production APNs, Time Sensitive and
  # communication notifications, and the App Group the extensions share with the app.
  unzip -q "$IPA" -d "$WORK/ipa"
  entitlement() { # <bundle> <key path>
    codesign -d --entitlements - --xml "$1" 2>/dev/null > "$WORK/entitlements.plist"
    /usr/libexec/PlistBuddy -c "Print :$2" "$WORK/entitlements.plist" 2>/dev/null || true
  }
  expect() { # <bundle> <key path> <value>
    [ "$(entitlement "$1" "$2")" = "$3" ] || { echo "$(basename "$1"): $2 isn't $3"; exit 1; }
  }
  PAYLOAD="$WORK/ipa/Payload/Hermes.app"
  expect "$PAYLOAD" aps-environment production
  expect "$PAYLOAD" com.apple.developer.usernotifications.time-sensitive true
  expect "$PAYLOAD" com.apple.developer.usernotifications.communication true
  for bundle in "$PAYLOAD" "$PAYLOAD"/PlugIns/*.appex; do
    expect "$bundle" com.apple.security.application-groups:0 "$APP_GROUP"
    expect "$bundle" keychain-access-groups:0 "$TEAM_ID.$BUNDLE_ID.push"
  done
  [ "$(ls -d "$PAYLOAD"/PlugIns/*.appex | wc -l | tr -d ' ')" = 3 ] || { echo "expected 3 extensions"; exit 1; }
  echo "push entitlements ok (app + 3 extensions)"
  # Pairing codes are universal links on hermesapp.dev (docs/connecting-and-voice.md §2): without
  # this the Camera opens them in Safari instead of Hermes.
  expect "$PAYLOAD" com.apple.developer.associated-domains:0 applinks:hermesapp.dev
  echo "pairing links ok (applinks:hermesapp.dev)"
  # altool finds the key only under ./private_keys.
  mkdir -p "$WORK/private_keys" && cp "$ASC_KEY_PATH" "$WORK/private_keys/"
  (cd "$WORK" && xcrun altool --validate-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json > "$OUT/validate-iOS.json" 2>&1) \
    || { cat "$OUT/validate-iOS.json" | head -40; exit 1; }
  echo "validated $(basename "$IPA")"
  if [ $DRY_RUN = 0 ]; then
    log "upload iOS to App Store Connect"
    ios_options upload
    "${XCB[@]}" -exportArchive -archivePath "$OUT/Hermes-iOS.xcarchive" -exportPath "$OUT/ios-upload" \
      -exportOptionsPlist "$OUT/ExportOptions-iOS-upload.plist" "${AUTH[@]}" > "$OUT/upload-iOS.log" 2>&1 \
      || { grep -E "error" "$OUT/upload-iOS.log" | head -20; exit 1; }
    echo "uploaded iOS $VERSION ($BUILD_NUMBER) — internal testers get it once processing finishes; Public Beta after the Mac"
  fi
fi

# --- macOS → notarized DMG + Sparkle ---------------------------------------------------------------
if [ $MAC = 1 ]; then
  archive macOS
  log "export macOS (Developer ID)"
  cat > "$OUT/ExportOptions-macOS.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$DEVID_SHA</string>
</dict></plist>
EOF
  "${XCB[@]}" -exportArchive -archivePath "$OUT/Hermes-macOS.xcarchive" -exportPath "$OUT/mac" \
    -exportOptionsPlist "$OUT/ExportOptions-macOS.plist" > "$OUT/export-macOS.log" 2>&1 \
    || { grep -E "error" "$OUT/export-macOS.log" | head -20; exit 1; }
  APP="$OUT/mac/Hermes.app"
  assert_release_app "$APP/Contents/Info.plist" "$APP/Contents/MacOS/Hermes"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" != "" ] || { echo "no SUFeedURL"; exit 1; }

  # Sparkle's nested code loses Hardened Runtime through -exportArchive; re-sign inside-out, never --deep.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  SV="$SPARKLE/Versions/B"
  for component in "$SV/XPCServices/Installer.xpc" "$SV/XPCServices/Downloader.xpc" "$SV/Autoupdate" "$SV/Updater.app" "$SPARKLE"; do
    extra=()
    [ "$(basename "$component")" = "Downloader.xpc" ] && extra=(--preserve-metadata=entitlements)
    # bash 3.2 (macOS) treats an empty array as unbound under set -u, hence the +-expansion.
    codesign --force --options runtime --timestamp ${extra[@]+"${extra[@]}"} --sign "$DEVID_SHA" "$component"
  done
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements,requirements,flags --sign "$DEVID_SHA" "$APP"
  codesign --verify --deep --strict "$APP"
  # The loader must find the embedded framework (the trap that once shipped dead DMGs).
  RPATHS="$(otool -l "$APP/Contents/MacOS/Hermes" | awk '/LC_RPATH/ {getline; getline; print $2}')"
  case "$RPATHS" in *"@executable_path/../Frameworks"*) ;; *) echo "missing @executable_path/../Frameworks rpath"; exit 1 ;; esac
  for component in "$APP" "$SPARKLE" "$SV/XPCServices/Installer.xpc" "$SV/Autoupdate"; do
    flags="$(codesign -dvv "$component" 2>&1 || true)"
    case "$flags" in *"runtime"*) ;; *) echo "no Hardened Runtime on $component"; exit 1 ;; esac
    case "$flags" in *"TeamIdentifier=$TEAM_ID"*) ;; *) echo "not signed by team $TEAM_ID: $component"; exit 1 ;; esac
  done

  notarize() { # <file>
    xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
      --wait --timeout 45m --output-format json > "$OUT/notary-$(basename "$1").json"
    status="$(plutil -extract status raw -o - "$OUT/notary-$(basename "$1").json" 2>/dev/null || python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$OUT/notary-$(basename "$1").json")"
    [ "$status" = "Accepted" ] || { echo "notarization of $(basename "$1"): $status"; cat "$OUT/notary-$(basename "$1").json"; exit 1; }
  }
  log "notarize app"
  ditto -c -k --keepParent "$APP" "$OUT/Hermes-app.zip"
  notarize "$OUT/Hermes-app.zip"
  xcrun stapler staple "$APP"

  log "DMG"
  DMG_NAME="Hermes-$VERSION-$BUILD_NUMBER.dmg"
  DMG="$OUT/$DMG_NAME"
  STAGE="$OUT/dmg-stage"
  rm -rf "$STAGE" && mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Hermes.app"
  ln -s /Applications "$STAGE/Applications"
  # diskutil, not hdiutil: hdiutil create is deprecated on macOS 27, and after a restart it can fail
  # with "Resource busy" for every image. diskutil doesn't overwrite, so an old DMG goes first.
  rm -f "$DMG"
  diskutil image create from --format UDZO --volumeName "Hermes" "$STAGE" "$DMG" >/dev/null
  codesign --force --timestamp --sign "$DEVID_SHA" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -t exec -v "$APP"

  log "Sparkle appcast"
  SPARKLE_BIN="$(dirname "$(find "$RELEASE_DERIVED_DATA/SourcePackages/artifacts" -type f -name sign_update -path '*/Sparkle/bin/*' 2>/dev/null | head -1)")"
  [ -x "$SPARKLE_BIN/sign_update" ] || { echo "Sparkle sign_update not found in $RELEASE_DERIVED_DATA"; exit 1; }
  ED_KEY="$WORK/sparkle-ed.key"
  secret_file /hermes/ci SPARKLE_ED_PRIVATE_KEY=HERMES_SPARKLE_ED_PRIVATE_KEY "$ED_KEY"
  SIGNATURE="$("$SPARKLE_BIN/sign_update" --ed-key-file "$ED_KEY" "$DMG")"   # sparkle:edSignature="…" length="…"
  rm -P -f "$ED_KEY"
  TAG="v$VERSION-$BUILD_NUMBER"
  DMG_URL="https://github.com/$RELEASES_REPO/releases/download/$TAG/$DMG_NAME"
  cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Hermes</title>
    <link>https://github.com/$RELEASES_REPO</link>
    <description>Updates for Hermes on the Mac.</description>
    <language>en</language>
    <item>
      <title>Hermes $VERSION ($BUILD_NUMBER)</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="$DMG_URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
  if [ $DRY_RUN = 0 ]; then
    log "publish $TAG on $RELEASES_REPO"
    # Hermes.dmg is the stable download link (…/releases/latest/download/Hermes.dmg) for the website.
    cp "$DMG" "$OUT/Hermes.dmg"
    github gh release create "$TAG" "$DMG" "$OUT/Hermes.dmg" "$OUT/appcast.xml" --repo "$RELEASES_REPO" --latest \
      --title "Hermes $VERSION beta ($BUILD_NUMBER)" --notes "Hermes $VERSION beta for Mac. Signed by Caffeinated Code (team 29ZNGBT83H), notarized by Apple. Existing installs update through Sparkle. What's new: https://github.com/$SOURCE_REPO/releases/tag/$TAG"
    # Verify what customers get, not the exit codes.
    FEED="https://github.com/$RELEASES_REPO/releases/latest/download/appcast.xml"
    curl -fsSL "$FEED" | grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" || { echo "feed doesn't serve $BUILD_NUMBER yet"; exit 1; }
    curl -fsSIL "$DMG_URL" -o /dev/null || { echo "DMG not downloadable"; exit 1; }
    echo "macOS: published $DMG_URL"
  else
    echo "macOS: dry run — $DMG"
  fi
fi

# The release before this one: notes run from it to HEAD (public TestFlight, GitHub release, CHANGELOG).
if [ $DRY_RUN = 0 ]; then
  git fetch --quiet --tags origin main
  PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude "v$VERSION-$BUILD_NUMBER" HEAD 2>/dev/null || true)"
fi

# --- iOS → public TestFlight (docs/releasing.md §Public TestFlight) ------------------------------------
# Every release goes to the "Public Beta" group and to beta review too (Vedran, 2026-10-20). Runs after
# the Mac so the build has processed meanwhile. A refusal (a build already waiting for review, a
# review still needed) is reported, and the release still succeeds.
PUBLIC_GROUP="Public Beta"
if [ $IOS = 1 ] && [ $DRY_RUN = 0 ]; then
  log "public TestFlight: $PUBLIC_GROUP"
  python3 -I Scripts/release_notes.py testflight "$VERSION" "$BUILD_NUMBER" "$PREVIOUS_TAG" > "$OUT/whats-new.txt"
  # App Store Connect lists an upload only after a few minutes, and publishing before that finds no
  # build, so wait for it (up to 30 min).
  for _ in $(seq 1 60); do
    "${ASC[@]}" builds list --app "$ASC_APP_ID" --build-number "$BUILD_NUMBER" --platform IOS --output json 2>/dev/null \
      | python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["data"] else 1)' 2>/dev/null && break
    sleep 30
  done
  if "${ASC[@]}" publish testflight --app "$ASC_APP_ID" --build-number "$BUILD_NUMBER" --platform IOS \
      --group "$PUBLIC_GROUP" --test-notes "$(cat "$OUT/whats-new.txt")" --locale en-US \
      --wait --timeout 60m --submit --confirm --output json > "$OUT/public-testflight.json" 2> "$OUT/public-testflight.log"; then
    echo "public TestFlight: $BUILD_NUMBER is in $PUBLIC_GROUP and submitted for beta review"
  else
    echo "public TestFlight: App Store Connect refused part of it; the release still stands:" >&2
    tail -5 "$OUT/public-testflight.log" >&2
  fi
  # Say where it stands, whatever happened above.
  BUILD_ID="$("${ASC[@]}" builds list --app "$ASC_APP_ID" --build-number "$BUILD_NUMBER" --platform IOS --output json 2>/dev/null \
    | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "")' 2>/dev/null || true)"
  if [ -n "$BUILD_ID" ]; then
    STATE="$("${ASC[@]}" testflight distribution view --build-id "$BUILD_ID" --output json 2>/dev/null \
      | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["attributes"]["externalBuildState"])' 2>/dev/null || echo unknown)"
    echo "public TestFlight: external state $STATE (https://testflight.apple.com/join/CVhbq8Ur)"
  fi
fi

# --- Source: tag, GitHub release and CHANGELOG (docs/releasing.md §Public release) ---------------
# Stays off hermes-releases' "latest": Sparkle and the website read that repo's latest release, and
# a pre-release there would never be served.
if [ $DRY_RUN = 0 ]; then
  TAG="v$VERSION-$BUILD_NUMBER"
  if [ "$(github gh repo view "$SOURCE_REPO" --json visibility --jq .visibility)" != PUBLIC ]; then
    echo "source: $SOURCE_REPO isn't public yet, so $TAG wasn't tagged"
  elif github gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
    echo "source: $TAG is already released on $SOURCE_REPO"
  elif ! git merge-base --is-ancestor HEAD origin/main; then
    echo "source: HEAD isn't on origin/main, so $TAG wasn't tagged; release from a clean checkout of main" >&2
    exit 1
  else
    log "tag $TAG on $SOURCE_REPO"
    python3 -I Scripts/release_notes.py notes "$VERSION" "$BUILD_NUMBER" "$TAG" "$PREVIOUS_TAG" > "$OUT/release-notes.md"
    PRERELEASE=(); [ $BETA = 1 ] && PRERELEASE=(--prerelease)
    github gh release create "$TAG" --repo "$SOURCE_REPO" --target "$(git rev-parse HEAD)" ${PRERELEASE[@]+"${PRERELEASE[@]}"} \
      --title "Hermes $VERSION$([ $BETA = 1 ] && echo ' beta') ($BUILD_NUMBER)" --notes-file "$OUT/release-notes.md"
    # The changelog commit lands after the tag, so the next release's notes skip it ("Changelog:").
    python3 -I Scripts/release_notes.py changelog "$VERSION" "$BUILD_NUMBER" "$PREVIOUS_TAG"
    if git diff --quiet -- CHANGELOG.md; then
      echo "source: CHANGELOG.md already has build $BUILD_NUMBER"
    else
      GIT_ID=(-c "user.name=$GIT_NAME" -c "user.email=$GIT_EMAIL")   # the repository's commit identity
      # In Buildkite the push signs in through gh with the job's token, never a token in a URL, and
      # goes over https whatever URL the pipeline cloned from: credential helpers serve https alone,
      # so an SSH origin would use the agent's own key instead.
      PUSH_AUTH=() PUSH_REMOTE=origin
      if [ "$CI_RELEASE" = 1 ]; then
        PUSH_AUTH=(-c credential.helper= -c 'credential.helper=!gh auth git-credential')
        PUSH_REMOTE="https://github.com/$SOURCE_REPO.git"
      fi
      git "${GIT_ID[@]}" commit --quiet -m "Changelog: Hermes $VERSION beta ($BUILD_NUMBER)" -- CHANGELOG.md
      CHANGELOG_COMMIT="$(git rev-parse HEAD)"
      # main usually moves during a release: replay the commit on the newest main in a clean worktree
      # (this checkout carries the test run's Package.resolved), and try a second time if it moves again.
      PUSHED=""
      for attempt in 1 2; do
        git fetch --quiet origin main
        git worktree remove --force "$OUT/changelog-main" 2>/dev/null || true
        git worktree add --quiet --detach "$OUT/changelog-main" origin/main
        if git -C "$OUT/changelog-main" "${GIT_ID[@]}" cherry-pick "$CHANGELOG_COMMIT" >/dev/null 2>&1 \
          && github git -C "$OUT/changelog-main" ${PUSH_AUTH[@]+"${PUSH_AUTH[@]}"} push --quiet "$PUSH_REMOTE" HEAD:main 2>/dev/null; then
          PUSHED="$(git -C "$OUT/changelog-main" rev-parse --short HEAD)"
        fi
        git worktree remove --force "$OUT/changelog-main"
        [ -n "$PUSHED" ] && break
      done
      if [ -n "$PUSHED" ]; then
        echo "source: CHANGELOG for $BUILD_NUMBER is on main ($PUSHED)"
      else
        echo "source: couldn't put the CHANGELOG commit $(git rev-parse --short "$CHANGELOG_COMMIT") on main; cherry-pick it there. The release still stands." >&2
      fi
    fi
    echo "source: https://github.com/$SOURCE_REPO/releases/tag/$TAG"
  fi
fi

log "done: Hermes $VERSION ($BUILD_NUMBER) → $OUT"
