#!/usr/bin/env bash
# Hermes release, run on the trusted studio Mac (Caffeinated Code, team 29ZNGBT83H):
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
# Release builds are the real "Hermes" (co.caffeinatedcode.hermes) with no demo code; the demo
# lives only in Debug ("Hermes Dev", co.caffeinatedcode.hermes.dev).
#
# Usage: Scripts/release.sh [--ios-only | --mac-only] [--dry-run] [--build-number N]
#   --dry-run  sign, notarize and package, but upload/publish nothing.
set -euo pipefail
# A tight umask makes codesign write owner-only files that fail Mac validation (ITMS-90255).
umask 022
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ASC_BYPASS_KEYCHAIN=1
cd "$(dirname "$0")/.."

IOS=1 MAC=1 DRY_RUN=0
BUILD_NUMBER="$(date -u +%y%m%d%H%M)"
while [ $# -gt 0 ]; do
  case "$1" in
    --ios-only) MAC=0 ;;
    --mac-only) IOS=0 ;;
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

log "Hermes $VERSION ($BUILD_NUMBER)$([ $DRY_RUN = 1 ] && echo ' — dry run')"
[ -r "$ASC_KEY_PATH" ] || { echo "missing ASC key $ASC_KEY_PATH"; exit 1; }
command -v xcodegen >/dev/null && xcodegen generate --quiet
(cd Packages/HermesKit && swift test 2>&1 | grep -E "Test run with" | tail -1)

# --- Signing keychain (escrowed identities, temporary) ---------------------------------------
WORK="$(umask 077; mktemp -d -t hermes-release)"
KEYCHAIN="$WORK/signing.keychain-db"
ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do ORIGINAL_KEYCHAINS+=("$(echo "$line" | tr -d '" ')"); done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" 2>/dev/null || true
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  find "$WORK" -type f -exec rm -P -f {} + 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
# A killed release (an ended session, Ctrl-C) must still delete the signing keychain: bash skips
# the EXIT trap on a fatal signal unless the signal is turned into an exit.
trap 'exit 130' INT HUP
trap 'exit 143' TERM

log "signing keychain"
curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$WORK/AppleWWDRCAG3.cer"
curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$WORK/DeveloperIDG2CA.cer"
# Passwords travel on security's stdin, never argv; files are owner-only and shredded on exit.
infisical export --projectId "$INFISICAL_PROJECT" --env prod --path "$ESCROW" --format json 2>/dev/null \
  | WORK="$WORK" KEYCHAIN="$KEYCHAIN" python3 -c '
import base64, json, os, secrets, subprocess, sys
data = json.load(sys.stdin)
rows = data if isinstance(data, list) else data.get("secrets", data)
values = {(r.get("key") or r.get("secretKey")): (r.get("value") or r.get("secretValue")) for r in rows} if isinstance(rows, list) else rows
work, keychain = os.environ["WORK"], os.environ["KEYCHAIN"]
OPENSSL = "/opt/homebrew/bin/openssl"   # OpenSSL 3 reads the escrow (AES-256/SHA-256 PKCS#12)
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
password = secrets.token_hex(24)
security(f"create-keychain -p {quoted(password)} {quoted(keychain)}")
security(f"set-keychain-settings -lut 7200 {quoted(keychain)}")
security(f"unlock-keychain -p {quoted(password)} {quoted(keychain)}")
for name in ("APPLE_DISTRIBUTION", "DEVELOPER_ID_APPLICATION"):
    modern = os.path.join(work, name + ".p12")
    legacy = os.path.join(work, name + "-macos.p12")
    write_private(modern, base64.b64decode(values[name + "_CERT_BASE64"]))
    # macOS imports only 3DES/SHA-1 PKCS#12, so re-wrap it under a one-time password. The PEM
    # stage is owner-only inside the private temp folder and shredded at once; the escrow is unchanged.
    transfer = secrets.token_hex(24)
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
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
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
  xcodebuild archive -project Hermes.xcodeproj -scheme Hermes -configuration Release \
    -destination "generic/platform=$1" -archivePath "$OUT/Hermes-$1.xcarchive" \
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
    cp "$profile" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.mobileprovision"
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
  xcodebuild -exportArchive -archivePath "$OUT/Hermes-iOS.xcarchive" -exportPath "$OUT/ios" \
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
    xcodebuild -exportArchive -archivePath "$OUT/Hermes-iOS.xcarchive" -exportPath "$OUT/ios-upload" \
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
  xcodebuild -exportArchive -archivePath "$OUT/Hermes-macOS.xcarchive" -exportPath "$OUT/mac" \
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
  hdiutil create -volname "Hermes" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
  codesign --force --timestamp --sign "$DEVID_SHA" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -t exec -v "$APP"

  log "Sparkle appcast"
  SPARKLE_BIN="$(dirname "$(find build/DerivedData/SourcePackages/artifacts "$HOME/Library/Developer/Xcode/DerivedData" -type f -name sign_update -path '*/Sparkle/bin/*' 2>/dev/null | head -1)")"
  [ -x "$SPARKLE_BIN/sign_update" ] || { echo "Sparkle sign_update not found (resolve packages first)"; exit 1; }
  ED_KEY="$WORK/sparkle-ed.key"
  infisical export --projectId "$INFISICAL_PROJECT" --env prod --path /hermes/ci --format json 2>/dev/null \
    | ED_KEY="$ED_KEY" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
rows = data if isinstance(data, list) else data.get("secrets", data)
values = {(r.get("key") or r.get("secretKey")): (r.get("value") or r.get("secretValue")) for r in rows} if isinstance(rows, list) else rows
fd = os.open(os.environ["ED_KEY"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, values["SPARKLE_ED_PRIVATE_KEY"].strip().encode())
os.close(fd)
'
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
    gh release create "$TAG" "$DMG" "$OUT/Hermes.dmg" "$OUT/appcast.xml" --repo "$RELEASES_REPO" --latest \
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
  if [ "$(gh repo view "$SOURCE_REPO" --json visibility --jq .visibility)" != PUBLIC ]; then
    echo "source: $SOURCE_REPO isn't public yet, so $TAG wasn't tagged"
  elif gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
    echo "source: $TAG is already released on $SOURCE_REPO"
  elif ! git merge-base --is-ancestor HEAD origin/main; then
    echo "source: HEAD isn't on origin/main, so $TAG wasn't tagged; release from a clean checkout of main" >&2
    exit 1
  else
    log "tag $TAG on $SOURCE_REPO"
    python3 -I Scripts/release_notes.py notes "$VERSION" "$BUILD_NUMBER" "$TAG" "$PREVIOUS_TAG" > "$OUT/release-notes.md"
    PRERELEASE=(); [ $BETA = 1 ] && PRERELEASE=(--prerelease)
    gh release create "$TAG" --repo "$SOURCE_REPO" --target "$(git rev-parse HEAD)" ${PRERELEASE[@]+"${PRERELEASE[@]}"} \
      --title "Hermes $VERSION$([ $BETA = 1 ] && echo ' beta') ($BUILD_NUMBER)" --notes-file "$OUT/release-notes.md"
    # The changelog commit lands after the tag, so the next release's notes skip it ("Changelog:").
    python3 -I Scripts/release_notes.py changelog "$VERSION" "$BUILD_NUMBER" "$PREVIOUS_TAG"
    git add CHANGELOG.md
    git commit --quiet -m "Changelog: Hermes $VERSION beta ($BUILD_NUMBER)"
    git push --quiet origin HEAD:main \
      || echo "source: main moved, so the CHANGELOG commit $(git rev-parse --short HEAD) wasn't pushed: cherry-pick it onto main" >&2
    echo "source: https://github.com/$SOURCE_REPO/releases/tag/$TAG"
  fi
fi

log "done: Hermes $VERSION ($BUILD_NUMBER) → $OUT"
