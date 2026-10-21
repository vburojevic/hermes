#!/bin/zsh
# The app switcher's picture of the app matches the appearance it opens in
# (docs/design-to-swiftui.md §1). For each Settings → Appearance (System, Light, Dark) and each
# device appearance (Light, Dark), it opens Hermes Dev on a booted simulator, sends it to the
# background, and reads the pictures iOS kept (Library/SplashBoard): every one must be as light or
# dark as the app was. Needs a Debug build installed on the simulator; no gateway.
#
#   Scripts/check-switcher-snapshots.sh <simulator udid> [output folder]
set -u
UDID=${1:?usage: check-switcher-snapshots.sh <simulator udid> [output folder]}
OUT=${2:-${TMPDIR:-/tmp}/switcher-snapshots}
BUNDLE=co.caffeinatedcode.hermes.dev
mkdir -p "$OUT"
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data) || { echo "Hermes Dev isn't installed on $UDID"; exit 2; }
SNAPS="$DATA/Library/SplashBoard/Snapshots"
failed=0

# Mean brightness (0…1) of a picture, from a 16×16 copy.
brightness() {
    sips -s format bmp -z 16 16 "$1" --out "$OUT/probe.bmp" >/dev/null 2>&1
    python3 -I -c '
import struct, sys
data = open(sys.argv[1], "rb").read()
offset = struct.unpack_from("<I", data, 10)[0]
width, height = struct.unpack_from("<ii", data, 18)
bits = struct.unpack_from("<H", data, 28)[0] // 8
row = (width * bits + 3) & ~3
total = 0
for y in range(abs(height)):
    for x in range(width):
        b, g, r = data[offset + y * row + x * bits: offset + y * row + x * bits + 3]
        total += (r + g + b) / 765
print(round(total / (width * abs(height)), 2))
' "$OUT/probe.bmp"
}

for app in system light dark; do
    for device in light dark; do
        xcrun simctl ui "$UDID" appearance "$device"
        xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
        rm -f "$SNAPS"/sceneID*/*.ktx(N)
        xcrun simctl launch "$UDID" "$BUNDLE" -appearance "$app" -HERMES_TIPS hide -HERMES_WHATS_NEW NO >/dev/null
        sleep 8
        xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
        sleep 6
        expected=$([[ $app == system ]] && echo "$device" || echo "$app")
        seen=()
        n=0
        for snap in "$SNAPS"/sceneID*/*.ktx(N); do
            n=$((n + 1))
            png="$OUT/$app-app-$device-device-$n.png"
            sips -s format png "$snap" --out "$png" >/dev/null 2>&1
            level=$(brightness "$png")
            style=$( (( level > 0.5 )) && echo light || echo dark )
            seen+=("$style")
        done
        # Following the device, iOS keeps one picture per appearance; set by the app, one in its own.
        if [[ $app == system ]]; then
            ok=$([[ " ${seen[*]} " == *" $device "* ]] && echo yes || echo no)
        else
            ok=$([[ ${#seen[@]} -gt 0 && " ${seen[*]} " != *" $([[ $app == light ]] && echo dark || echo light) "* ]] && echo yes || echo no)
        fi
        printf '%-7s app, %-5s device: pictures %-12s expected %-5s %s\n' "$app" "$device" "${seen[*]:-none}" "$expected" "$([[ $ok == yes ]] && echo ok || echo WRONG)"
        [[ $ok == yes ]] || failed=1
    done
done
xcrun simctl terminate "$UDID" com.apple.Preferences >/dev/null 2>&1
echo "Pictures in $OUT"
exit $failed
