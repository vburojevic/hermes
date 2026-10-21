#!/bin/bash
# docs/web.md §8: after a full sign-in and a card fill against the mock, no password, master
# password, card number, security code or one-time code appears in the app's logs or files.
#
#   Scripts/dev/web-secret-search.sh --secrets <file> [--udid <simulator>] [--mac] [--mac-home <dir>]
#       [--mock-log <file>] [--since 2h] [--bundle co.caffeinatedcode.hermes.dev] [--mac-bundle <id>]
#
# <file> holds the values typed during the run, one per line, and is read from disk only: the
# values never go on a command line. Each is looked for as typed, JSON-escaped, percent-encoded,
# as bare digits (a card number typed with spaces) and in UTF-16 (binary plists), byte for byte.
# Searched: the simulator's unified log (info and debug too) and the app's data and group
# containers (--udid); this Mac's unified log and the app's files, including the folders an
# unsandboxed build shares under ~/Library/Caches and Application Support (--mac; --mac-home for a
# run under CFFIXED_USER_HOME); the mock's own output (--mock-log). Prints where a value was found
# (by its line number in <file>, never the value) and exits 1; exits 2 when something couldn't be
# searched or nothing was asked for; says nothing was found and exits 0 only after a full search.
set -uo pipefail

secrets_file="" udid="" mac=0 mac_home="$HOME" mock_log="" since="2h" bundle="co.caffeinatedcode.hermes.dev" mac_bundle=""
while [ $# -gt 0 ]; do
  case "$1" in
    --secrets) secrets_file="$2"; shift 2 ;;
    --udid) udid="$2"; shift 2 ;;
    --mac) mac=1; shift ;;
    --mac-home) mac_home="$2"; shift 2 ;;
    --mock-log) mock_log="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    --mac-bundle) mac_bundle="$2"; shift 2 ;;
    *) sed -n '2,17p' "$0"; exit 2 ;;
  esac
done
[ -r "$secrets_file" ] || { echo "Give the values to look for: --secrets <file>, one per line." >&2; exit 2; }
[ -n "$udid" ] || [ "$mac" = 1 ] || [ -n "$mock_log" ] || { echo "Say where to look: --udid, --mac and/or --mock-log." >&2; exit 2; }
[ -n "$mac_bundle" ] || mac_bundle="$bundle"

# Paths and options go to the scanner in the environment, never the values.
export WSS_SECRETS="$secrets_file" WSS_UDID="$udid" WSS_MAC="$mac" WSS_MAC_HOME="$mac_home" WSS_MOCK_LOG="$mock_log" \
       WSS_SINCE="$since" WSS_BUNDLE="$bundle" WSS_MAC_BUNDLE="$mac_bundle"
exec python3 -I - <<'PY'
import glob, json, os, subprocess, sys, urllib.parse

env = os.environ
with open(env["WSS_SECRETS"], encoding="utf-8") as f:
    values = [line.rstrip("\r\n") for line in f if line.strip()]
if not values:
    print(f"{env['WSS_SECRETS']} has no values.", file=sys.stderr)
    sys.exit(2)

def variants(value):
    texts = {value, json.dumps(value)[1:-1], urllib.parse.quote(value, safe=""), urllib.parse.quote_plus(value)}
    digits = "".join(ch for ch in value if ch.isdigit())
    if len(digits) >= 12 and digits != value:
        texts.add(digits)
    out = set()
    for text in texts:
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            data = text.encode(encoding)
            if len(data) >= 3:
                out.add(data)
    return out

patterns = [(index + 1, variant) for index, value in enumerate(values) for variant in variants(value)]
longest = max(len(p) for _, p in patterns)
found, problems = [], []

def scan_bytes(data):
    return sorted({index for index, pattern in patterns if pattern in data})

def report(place, indexes, where=None):
    for index in indexes:
        found.append(index)
        print(f"FOUND value #{index} in {place}" + (f": {where}" if where else ""))

def scan_stream(place, command):
    """A command's output, in chunks that overlap by the longest pattern; its failure is a problem."""
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as error:
        problems.append(f"{place}: {error.strerror}")
        return
    hits, tail = set(), b""
    while True:
        chunk = process.stdout.read(1 << 20)
        if not chunk:
            break
        data = tail + chunk
        hits.update(scan_bytes(data))
        tail = data[-longest:]
    if process.wait() != 0:
        problems.append(f"{place}: the command exited {process.returncode}")
    report(place, sorted(hits))

def scan_file(place, path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as error:
        problems.append(f"{path}: {error.strerror}")
        return
    report(place, scan_bytes(data), path)

def scan_tree(place, root):
    if not os.path.lexists(root):
        return
    if os.path.isfile(root):
        scan_file(place, root)
        return
    for directory, _, files in os.walk(root, onerror=lambda error: problems.append(f"{error.filename}: {error.strerror}")):
        for name in files:
            path = os.path.join(directory, name)
            if os.path.isfile(path) and not os.path.islink(path):
                scan_file(place, path)

def output(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        problems.append(f"{' '.join(command[:3])}: {error.strerror}")
        return ""
    if result.returncode != 0:
        problems.append(f"{' '.join(command[:4])}: exited {result.returncode}")
        return ""
    return result.stdout.strip()

udid, since, bundle = env["WSS_UDID"], env["WSS_SINCE"], env["WSS_BUNDLE"]
if udid:
    print(f"Simulator {udid}: unified log (last {since}, info and debug) and {bundle}'s containers")
    scan_stream("the simulator's unified log", ["xcrun", "simctl", "spawn", udid, "log", "show", "--style", "compact", "--info", "--debug", "--last", since])
    data = output(["xcrun", "simctl", "get_app_container", udid, bundle, "data"])
    if data:
        scan_tree("the app's data container", data)
    for line in output(["xcrun", "simctl", "get_app_container", udid, bundle, "groups"]).splitlines():
        group = line.split()[-1] if line.split() else ""
        if os.path.isdir(group):
            scan_tree("an app group container", group)
    scan_tree("crash reports", os.path.expanduser("~/Library/Logs/DiagnosticReports"))

if env["WSS_MAC"] == "1":
    home, mac_bundle = env["WSS_MAC_HOME"], env["WSS_MAC_BUNDLE"]
    library = os.path.join(home, "Library")
    print(f"This Mac: unified log (last {since}, info and debug) and {mac_bundle}'s files under {home}")
    scan_stream("this Mac's unified log", ["/usr/bin/log", "show", "--style", "compact", "--info", "--debug", "--last", since])
    places = [
        f"Preferences/{mac_bundle}.plist", f"Caches/{mac_bundle}", f"Containers/{mac_bundle}",
        f"Application Support/{mac_bundle}", f"HTTPStorages/{mac_bundle}", f"WebKit/{mac_bundle}",
        f"Saved Application State/{mac_bundle}.savedState",
        # An unsandboxed build's caches and queues sit straight under Caches and Application Support.
        "Caches/Transcripts", "Caches/LastLines", "Caches/Sessions", "Caches/Rosters", "Caches/Widgets",
        "Caches/Models", "Caches/VoiceMessages", "Application Support/Outbox", "Application Support/FollowUpQueues",
    ]
    for place in places:
        scan_tree(place, os.path.join(library, place))
    for group in glob.glob(os.path.join(library, "Group Containers", "*caffeinatedcode*")):
        scan_tree("an app group container", group)

if env["WSS_MOCK_LOG"]:
    print(f"The mock's output: {env['WSS_MOCK_LOG']}")
    scan_file("the mock's output", env["WSS_MOCK_LOG"])

if found:
    sys.exit(1)
if problems:
    print(f"Couldn't search everything ({len(problems)}):")
    for problem in problems[:20]:
        print(f"    {problem}")
    sys.exit(2)
print(f"Nothing found: none of the {len(values)} values appears anywhere searched.")
PY
