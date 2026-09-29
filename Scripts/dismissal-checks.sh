#!/bin/zsh
# Dismissal and focus-handback checks with real HID events (keyboard and mouse), so they
# exercise the same paths as a person: the Carbon global shortcut, Esc in the panel,
# clicks in other apps and in Dropy's own menu-bar item, and the pointer leaving.
#
#   Scripts/dismissal-checks.sh
#
# A disposable fixture app is frontmost before each open; after each close it must be
# frontmost again (focus handback). The pointer is moved during the run and put back at
# the end. Leave the Mac alone for about two minutes. Needs Accessibility for the terminal
# (to post events), no running Dropy, and no pending placement journal.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
dropy="$build_dir/Dropy.app/Contents/MacOS/Dropy"
hid="$build_dir/HIDTool"
journal="$HOME/Library/Application Support/Dropy/placement-journal.json"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$build_dir/dismissal-checks-$stamp.md"
logs="${report%.md}-logs"

for app in Dropy DropyFixture DropyInputFixture; do
  pgrep -xq "$app" && { print -u2 "Quit $app first."; exit 1; }
done
[[ -e "$journal" ]] && { print -u2 "Recover the pending placement journal first."; exit 1; }
source "${0:A:h}/lib/device-session.zsh"

"$repo_dir/Scripts/build-local.sh" >/dev/null
"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$hid" "$repo_dir/Scripts/bench/HIDTool/main.swift"
swiftc -O -swift-version 6 -o "$build_dir/WindowTool" "$repo_dir"/Scripts/bench/WindowTool/*.swift
device_session_begin dismissal-checks || exit 1
mkdir -p "$logs"
work="$(mktemp -d)"
defaults export "$prefs_domain" "$work/prefs.plist" 2>/dev/null || true
pointer_start=(${=$("$hid" pointer)})
dropy_pid=""
fixture_pid=""
rows=()

cleanup() {
  "$hid" release >/dev/null 2>&1 || true
  [[ -n "$dropy_pid" ]] && { kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""; }
  [[ -n "$fixture_pid" ]] && { kill "$fixture_pid" 2>/dev/null || true; fixture_pid=""; }
  if [[ -f "$work/prefs.plist" ]]; then defaults import "$prefs_domain" "$work/prefs.plist" || true
  else defaults delete "$prefs_domain" "$prefs_key" 2>/dev/null || true; fi
  (( ${#pointer_start} == 2 )) && "$hid" move "${pointer_start[1]}" "${pointer_start[2]}" >/dev/null 2>&1 || true
  rm -rf "$work"
  device_session_end
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap '(( ZSH_SUBSHELL == 0 )) && cleanup' ZERR

set_prefs() {
  local json="{\"trigger\":\"shortcut\",\"openBehavior\":\"picker\",\"dismissBehavior\":\"$1\",\"contentMode\":\"fit\",\"sizePreset\":\"medium\"}"
  defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
}

record() {
  rows+=("| $1 | $2 | $3 |")
  print -r -- "  $1: $2 ($3)"
}

# Starts Dropy with the given dismiss behaviour and the fixture frontmost.
start() {
  set_prefs "$1"
  local log="$logs/$2.log"
  DROPY_DEBUG_QUIT_AFTER=90 "$dropy" > "$log" 2>&1 &
  dropy_pid=$!
  sleep 2
  osascript -e 'tell application id "org.dropy.fixture" to activate' >/dev/null 2>&1 || true
  sleep 0.8
}

stop() {
  [[ -n "$dropy_pid" ]] || return 0
  kill "$dropy_pid" 2>/dev/null || true
  wait "$dropy_pid" 2>/dev/null || true
  dropy_pid=""
}

is_open() { [[ "$("$hid" panel "$dropy_pid")" != none ]]; }
fixture_center() { print -r -- "$((fx + fw / 2)) $((fy + fh / 2))"; }
open_by_shortcut() { "$hid" key 2 opt,cmd; sleep 1.2; }

result() {
  # result <check> <expected open state after> <expect handback yes|no>
  local check="$1" want_open="$2" want_front="$3" open=no front
  is_open && open=yes
  front="$("$hid" frontmost)"
  local verdict=PASS
  [[ "$open" == "$want_open" ]] || verdict=FAIL
  if [[ "$want_front" == yes && "$front" != org.dropy.fixture ]]; then verdict=FAIL; fi
  record "$check" "$verdict" "open=$open frontmost=$front"
}

# The fixture window gives the clicks a target in another app.
open -n --stdout "$work/fixture.out" "$build_dir/DropyFixture.app"
for i in {1..40}; do grep -q 'window=' "$work/fixture.out" 2>/dev/null && break; sleep 0.25; done
fixture_pid="$(lsappinfo info -only pid -app org.dropy.fixture | grep -oE '[0-9]+' | head -1)"
fixture_window="$(grep -oE 'window=[0-9]+' "$work/fixture.out" | head -1 | cut -d= -f2)"
geometry=(${=$("$build_dir/WindowTool" server "$fixture_window")})
fx=${geometry[1]} fy=${geometry[2]} fw=${geometry[3]} fh=${geometry[4]}
far=(${=$(fixture_center)})

print "Dismissal checks"
# 1. Esc closes and hands focus back; opened by the shortcut with the pointer elsewhere.
start manual esc
"$hid" move "${far[1]}" "${far[2]}"
open_by_shortcut
is_open && record "shortcut opens" PASS "panel on screen" || record "shortcut opens" FAIL "no panel"
"$hid" key 53
sleep 1
result "Esc closes, focus returns" no yes
# 2. The shortcut closes an open overlay.
open_by_shortcut
open_by_shortcut
result "shortcut closes, focus returns" no yes
# 3. Manual mode ignores a click in another app.
open_by_shortcut
"$hid" click "${far[1]}" "${far[2]}"
sleep 1
result "manual: click outside keeps it open" yes no
open_by_shortcut
stop

# 4. Click outside, in another app.
start clickOutside click-outside
open_by_shortcut
"$hid" click "${far[1]}" "${far[2]}"
sleep 1
result "click outside (other app) closes, focus returns" no yes
# 5. Click outside, on Dropy's own menu-bar item.
open_by_shortcut
item=(${=$("$hid" statusitem "$dropy_pid")})
if (( ${#item} == 4 )); then
  "$hid" click "$((item[1] + item[3] / 2))" "$((item[2] + item[4] / 2))"
  sleep 1
  open_now=no; is_open && open_now=yes
  "$hid" key 53   # dismiss the menu the click opened
  sleep 0.8
  [[ "$open_now" == no ]] && record "click outside (Dropy menu) closes" PASS "menu opened, overlay closed" \
    || record "click outside (Dropy menu) closes" FAIL "overlay still open"
else
  record "click outside (Dropy menu) closes" "NOT RUN" "menu-bar item not found"
fi
stop

# 6. Pointer leave: open with the pointer away (must stay open), then enter and leave.
start pointerLeave pointer-leave
"$hid" move "${far[1]}" "${far[2]}"
open_by_shortcut
sleep 1.5
result "pointer-leave: opened with pointer elsewhere stays open" yes no
panel=(${=$("$hid" panel "$dropy_pid")})
if (( ${#panel} == 4 )); then
  "$hid" move "$((panel[1] + panel[3] / 2))" "$((panel[2] + panel[4] / 2))"
  sleep 0.6
  "$hid" move "${far[1]}" "${far[2]}"
  sleep 1.5
  result "pointer-leave: leaving closes, focus returns" no yes
else
  record "pointer-leave: leaving closes" "NOT RUN" "panel not found"
fi
stop

{
  print -r -- "# Dropy dismissal checks"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); real HID events; fixture app frontmost before each open"
  print
  print -r -- "| Check | Result | Observed |"
  print -r -- "|---|---|---|"
  for row in $rows; do print -r -- "$row"; done
} > "$report"
cat "$report"
print -r -- "Report saved to $report"

# A report containing failures or skipped checks is not a successful verification run.
(( ${#rows} == 8 )) || { print -u2 "Expected 8 completed checks; see $report"; exit 1; }
for row in $rows; do
  [[ "$row" == *"| PASS |"* ]] || { print -u2 "A check failed or was skipped; see $report"; exit 1; }
done
