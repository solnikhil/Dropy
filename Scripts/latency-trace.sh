#!/bin/zsh
# Idle input-to-visible-update latency trace (measurement only; no pipeline change).
#
#   Scripts/latency-trace.sh [clicks] [gap-seconds]      default 20 clicks, 3 s apart
#
# Dropy previews window A of the disposable Electron fixture on the static text page
# (Scripts/bench/text.html) with the interactive preview on and DROPY_DEBUG_FRAME_TRACE=1.
# After a quiet period (spontaneous idle frames), real HID clicks land on the page's
# Press button in the preview. Each click is routed to A, the page updates its status
# text, and the first frame showing it is traced through capture, comparison,
# forwarding, main-thread delivery, draw (including drawable misses and retries) and
# compositor presentation. The gap lets capture fall back to its idle rate before each
# click, so every click measures the idle path. Raw Dropy log and a summary are written
# to .build/local/latency-trace-<timestamp>.md.
set -euo pipefail
repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
dropy="$build_dir/Dropy.app/Contents/MacOS/Dropy"
hid="$build_dir/HIDTool"
probe="$build_dir/InputProbe"
clicks="${1:-20}"
gap="${2:-3}"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$build_dir/latency-trace-$stamp.md"
logs="${report%.md}-logs"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"

pgrep -xq Dropy && { print -u2 "Quit Dropy first."; exit 1; }
if lsappinfo info -only pid -app org.dropy.electronfixture 2>/dev/null | grep -q '[0-9]'; then
  print -u2 "Quit DropyElectronFixture first."; exit 1
fi
[[ -e "$HOME/Library/Application Support/Dropy/placement-journal.json" ]] && { print -u2 "Recover pending Dropy placements first."; exit 1; }

source "$repo_dir/Scripts/lib/device-session.zsh"
device_session_begin latency-trace || exit 1
work="$(mktemp -d)"
dropy_pid=""
fixture_pid=""
pointer_start=()
cleanup() {
  [[ -n "$dropy_pid" ]] && { kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""; }
  [[ -f "$work/commands.txt" ]] && { print quit >> "$work/commands.txt"; sleep 1; }
  [[ -n "$fixture_pid" ]] && { kill "$fixture_pid" 2>/dev/null || true; fixture_pid=""; }
  "$hid" release >/dev/null 2>&1 || true
  (( ${#pointer_start} == 2 )) && "$hid" move "${pointer_start[1]}" "${pointer_start[2]}" >/dev/null 2>&1 || true
  rm -rf "$work"
  device_session_end   # restores Dropy's preferences
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap '(( ZSH_SUBSHELL == 0 )) && cleanup' ZERR

"$repo_dir/Scripts/build-local.sh" >/dev/null
"$repo_dir/Scripts/bench/build-electron-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$hid" "$repo_dir/Scripts/bench/HIDTool/main.swift"
swiftc -O -swift-version 6 -o "$probe" "$repo_dir"/Scripts/bench/InputProbe/*.swift
"$probe" check-modifiers
mkdir -p "$logs"
pointer_start=(${=$("$hid" pointer)})

: > "$work/commands.txt"
open -n "$build_dir/DropyElectronFixture.app" --args --mode text --log "$logs/fixture.jsonl" \
  --commands "$work/commands.txt" --profile "$work/profile"
for i in {1..60}; do grep -q '"kind":"ready"' "$logs/fixture.jsonl" 2>/dev/null && break; sleep 0.25; done
ready="$(grep '"kind":"ready"' "$logs/fixture.jsonl")"
fixture_pid="$(print -r -- "$ready" | grep -oE '"pid":[0-9]+' | cut -d: -f2)"
A="$(print -r -- "$ready" | grep -oE '"A":[0-9]+' | cut -d: -f2)"
version="$(print -r -- "$ready" | grep -oE '"electron":"[^"]*"' | cut -d'"' -f4)"
button="$(PROBE_ELECTRON=1 "$probe" element "$fixture_pid" "$A" t-button)"
window_size="$(print -r -- "$button" | grep -oE 'size=[0-9]+x[0-9]+' | cut -d= -f2 | tr x ,)"
at=(${(s:,:)$(print -r -- "$button" | grep -oE 'at=[0-9,]+' | cut -d= -f2)})

json='{"trigger":"shortcut","openBehavior":"direct","dismissBehavior":"manual","contentMode":"fit","sizePreset":"wide","selectedBundleIdentifier":"org.dropy.electronfixture","lastUsedBundleIdentifier":"org.dropy.electronfixture","interactivePreview":true}'
defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
quiet=10
log="$logs/dropy.log"
DROPY_DEBUG_FRAME_TRACE=1 DROPY_DEBUG_WINDOW_ID="$A" DROPY_DEBUG_QUIT_AFTER=$(( quiet + clicks * gap + 20 )) \
  "$dropy" --show > "$log" 2>&1 &
dropy_pid=$!
for i in {1..80}; do grep -q 'Dropy input: preview=' "$log" && break; sleep 0.25; done
grep -q 'Dropy input: preview=' "$log" || { print -u2 "interactive preview not ready"; exit 1; }
preview="$(grep -oE 'preview=[0-9.,-]+' "$log" | tail -1 | cut -d= -f2)"
point=($(python3 -c "
px,py,pw,ph=$preview
ww,wh=$window_size
s=min(pw/ww, ph/wh)
print(int(px+(pw-ww*s)/2+${at[1]}*s), int(py+(ph-wh*s)/2+${at[2]}*s))"))
# Park the pointer away from the preview during the quiet period, then click.
"$hid" move 20 900
sleep 3
print "quiet ${quiet}s"
print -r -- "QUIET_START $(date +%s)" >> "$logs/marks.txt"
sleep "$quiet"
print -r -- "CLICKS_START $(date +%s)" >> "$logs/marks.txt"
for i in $(seq 1 "$clicks"); do
  "$hid" click "${point[1]}" "${point[2]}"
  "$hid" move 20 900
  sleep "$gap"
done
kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""

summary="$(python3 "$repo_dir/Scripts/bench/latency-summary.py" "$log")"
{
  print -r -- "# Dropy idle input-to-visible latency trace"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)); $(sysctl -n hw.model); source: Electron $version fixture window A, static text page; overlay wide, fit"
  print -r -- "- ${quiet}s quiet, then $clicks HID clicks on the preview's Press button, ${gap}s apart; desktop session: $device_session_summary"
  print
  print -r -- "$summary"
  print
  print -r -- "## Capture metrics"
  print
  print -r -- '```'
  grep -oE 'Dropy (reveal|capture metrics): .*' "$log" || true
  grep -oE 'Dropy input: kind=pointerClick [^ ]+ (route|refused|gate|notApplicable)=[^ ]+' "$log" | sort | uniq -c || true
  print -r -- '```'
} > "$report"
cat "$report"
print -r -- "Report saved to $report"
