#!/bin/bash
# docs/web.md §8: after a full sign-in and a card fill against the mock, no password, master
# password, card number, security code or one-time code appears in the app's logs or files.
#
#   Scripts/dev/web-secret-search.sh --secrets <file> [--udid <simulator>] [--mac] [--mock-log <file>]
#                                    [--since 2h] [--bundle co.caffeinatedcode.hermes.dev]
#
# <file> holds the values typed during the run, one per line; they never go on a command line.
# Searched: the simulator's unified log and the app's data and group containers (--udid); this
# Mac's unified log and the Debug app's preferences, caches, containers, web data and saved state
# (--mac); the mock's own output (--mock-log), where the mock may keep a value it was given but must
# never print it. Prints where a value was found (by its line number in <file>, never the value) and
# exits 1, or says nothing was found and exits 0.
set -uo pipefail

secrets_file="" udid="" mac=0 mock_log="" since="2h" bundle="co.caffeinatedcode.hermes.dev"
while [ $# -gt 0 ]; do
  case "$1" in
    --secrets) secrets_file="$2"; shift 2 ;;
    --udid) udid="$2"; shift 2 ;;
    --mac) mac=1; shift ;;
    --mock-log) mock_log="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
  esac
done
[ -r "$secrets_file" ] || { echo "Give the values to look for: --secrets <file>, one per line." >&2; exit 2; }

secrets=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] && secrets+=("$line")
done < "$secrets_file"
[ ${#secrets[@]} -gt 0 ] || { echo "$secrets_file has no values." >&2; exit 2; }

found=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Searches one text file for every value; names the place and the value's line number.
search_text() {
  local place="$1" file="$2" i=0
  for value in "${secrets[@]}"; do
    i=$((i + 1))
    if grep -a -F -q -- "$value" "$file"; then
      echo "FOUND value #$i in $place"
      found=1
    fi
  done
}

# Searches every file under a folder (binary plists and databases too, as bytes).
search_tree() {
  local place="$1" root="$2" i=0
  [ -e "$root" ] || return 0
  for value in "${secrets[@]}"; do
    i=$((i + 1))
    local hits
    hits=$(grep -a -r -F -l -- "$value" "$root" 2>/dev/null | head -5)
    if [ -n "$hits" ]; then
      echo "FOUND value #$i in $place:"
      echo "$hits" | sed 's/^/    /'
      found=1
    fi
  done
}

if [ -n "$udid" ]; then
  echo "Simulator $udid: unified log (last $since) and $bundle's containers"
  xcrun simctl spawn "$udid" log show --style compact --last "$since" > "$work/sim.log" 2>/dev/null
  search_text "the simulator's unified log" "$work/sim.log"
  data=$(xcrun simctl get_app_container "$udid" "$bundle" data 2>/dev/null)
  [ -n "$data" ] && search_tree "the app's data container" "$data"
  while read -r group; do
    [ -d "$group" ] && search_tree "an app group container" "$group"
  done < <(xcrun simctl get_app_container "$udid" "$bundle" groups 2>/dev/null | awk '{print $NF}')
  # Crash and diagnostic reports the simulator wrote for the app.
  search_tree "the simulator's crash reports" "$HOME/Library/Logs/DiagnosticReports"
fi

if [ "$mac" = 1 ]; then
  echo "This Mac: unified log (last $since) and $bundle's files"
  /usr/bin/log show --style compact --last "$since" > "$work/mac.log" 2>/dev/null
  search_text "this Mac's unified log" "$work/mac.log"
  for path in "$HOME/Library/Preferences/$bundle.plist" "$HOME/Library/Caches/$bundle" "$HOME/Library/Containers/$bundle" \
              "$HOME/Library/Application Support/$bundle" "$HOME/Library/HTTPStorages/$bundle" "$HOME/Library/WebKit/$bundle" \
              "$HOME/Library/Saved Application State/$bundle.savedState"; do
    search_tree "$path" "$path"
  done
fi

if [ -n "$mock_log" ]; then
  echo "The mock's output: $mock_log"
  search_text "the mock's output" "$mock_log"
fi

if [ "$found" = 0 ]; then
  echo "Nothing found: none of the ${#secrets[@]} values appears anywhere searched."
  exit 0
fi
exit 1
