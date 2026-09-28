#!/bin/zsh
# One-session device checks for the M1 exit and the M2 placement matrix.
#
#   Scripts/device-checks.sh [--skip-benchmark]
#
# Runs, and writes one dated report to .build/local/device-checks-<timestamp>.md:
#   1. Placement matrix: offscreen, parked, minimize and hideApp against TextEdit
#      (AppKit) and a self-animating Safari page (WebKit), plus any apps listed in
#      EXTRA_APPS="<bundle-id> ..." (one exact window is selected and used by both driver and checker).
#   2. A later user move wins: the window is moved during a placement and must stay put.
#   3. Crash recovery: Dropy is killed while a window is parked; the next launch
#      must restore it from the journal.
#   4. The capture benchmark (Scripts/benchmark.sh), unless --skip-benchmark.
# Screen Recording revocation cannot be automated; the report lists the manual steps.
#
# Needs a terminal with Screen Recording and Accessibility permission, the display
# awake, and TextEdit and Safari not running. Every window is restored afterwards.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
dropy="$build_dir/Dropy.app/Contents/MacOS/Dropy"
tool="$build_dir/WindowTool"
journal="$HOME/Library/Application Support/Dropy/placement-journal.json"
run_benchmark=yes
[[ "${1:-}" == "--skip-benchmark" ]] && run_benchmark=no
report="$build_dir/device-checks-$(date +%Y%m%d-%H%M%S).md"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"

for app in Dropy TextEdit Safari; do
  if pgrep -xq "$app"; then
    print -u2 "Quit $app first; the checks open and close their own $app windows."
    exit 1
  fi
done

if [[ -f "$journal" ]]; then
  print -u2 "Recover the existing placement journal before running device checks."
  exit 1
fi
work_dir="$(mktemp -d)"
dropy_pid=""
owned_apps=()
rows=()
prefs_touched=no

cleanup() {
  stop_dropy
  # A placement left behind by an interrupted check is undone by one Dropy launch.
  if [[ -f "$journal" ]]; then
    DROPY_DEBUG_QUIT_AFTER=3 "$dropy" >/dev/null 2>&1 || true
  fi
  for app in $owned_apps; do
    pgrep -xq "$app" && osascript -e "tell application \"$app\" to quit saving no" >/dev/null 2>&1 || true
  done
  if [[ "$prefs_touched" == yes ]]; then
  if [[ -f "$work_dir/prefs.plist" ]]; then
    defaults import "$prefs_domain" "$work_dir/prefs.plist" || true
  else
    defaults delete "$prefs_domain" "$prefs_key" 2>/dev/null || true
  fi
  fi
  local logs="${report%.md}-logs"
  mkdir -p "$logs"
  for logfile in "$work_dir"/*.log(N) "$work_dir"/ax.err(N); do
    cp "$logfile" "$logs/"
  done
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stop_dropy() {
  if [[ -n "$dropy_pid" ]]; then
    kill "$dropy_pid" 2>/dev/null || true
    wait "$dropy_pid" 2>/dev/null || true
    dropy_pid=""
  fi
}

start_placement() {
  local mode="$1" window="$2" log="$3" hold="$4"
  DROPY_DEBUG_WINDOW_ID="$window" DROPY_DEBUG_PLACEMENT="$mode,$hold" DROPY_DEBUG_QUIT_AFTER=30 "$dropy" --show > "$log" 2>&1 &
  dropy_pid=$!
  for i in {1..60}; do
    if grep -q "placement applied: window=$window mode=$mode" "$log"; then
      sleep 1.5 # wait for parked covers and compositor visibility
      return 0
    fi
    kill -0 "$dropy_pid" 2>/dev/null || break
    sleep 0.25
  done
  return 1
}

set_direct_open() {
  prefs_touched=yes
  local json="{\"trigger\":\"notchClick\",\"openBehavior\":\"direct\",\"dismissBehavior\":\"manual\",\"contentMode\":\"fit\",\"sizePreset\":\"medium\",\"selectedBundleIdentifier\":\"$1\",\"lastUsedBundleIdentifier\":\"$1\"}"
  defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
}

# Opens the target and leaves exactly one window of it on screen below the overlay area.
open_target() {
  case "$1" in
    com.apple.TextEdit)
      owned_apps+=(TextEdit)
      for i in {1..40}; do print "Dropy device check line $i"; done > "$work_dir/check.txt"
      open -a TextEdit "$work_dir/check.txt"; sleep 2
      osascript -e 'tell application "TextEdit"
        close (every window whose name is not "check.txt") saving no
        set bounds of window "check.txt" to {80, 560, 880, 1000}
      end tell' >/dev/null ;;
    com.apple.Safari)
      owned_apps+=(Safari)
      open -a Safari "$repo_dir/Scripts/bench/animation.html"
      # Wait for the page title; closing "other" windows too early closes the page itself.
      for i in {1..40}; do
        osascript -e 'tell application "Safari" to exists (first window whose name is "Dropy bench animation")' \
          2>/dev/null | grep -q true && break
        sleep 0.25
      done
      osascript -e 'tell application "Safari"
        close (every window whose name is not "Dropy bench animation")
        set bounds of (first window whose name is "Dropy bench animation") to {80, 560, 880, 1000}
      end tell' >/dev/null ;;
    *)
      open -b "$1"; sleep 3 ;;
  esac
}

pid_of() { lsappinfo info -only pid -app "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1; }

# Compare geometry within 2 pt, plus exact minimized and application-hidden states.
frames_match() {
  local a=(${=1}) b=(${=2})
  [[ ${#a} == 6 && ${#b} == 6 ]] || return 1
  for i in 1 2 3 4; do (( ${a[i]} - ${b[i]} <= 2 && ${b[i]} - ${a[i]} <= 2 )) || return 1; done
  [[ ${#a} == 6 && ${#b} == 6 && ${a[5]} == ${b[5]} && ${a[6]} == ${b[6]} ]]
}

record() {
  local row="| $1 | $2 | $3 | $4 | $5 |"
  rows+=("$row")
  print -r -- "$row" >> "$report"
  print -r -- "  $1 · $2: $3 · $4 ($5)"
}

placement_checks() {
  local bundle="$1" pid window before after log line
  pid="$(pid_of "$bundle")"
  [[ -n "$pid" ]] || { record "$bundle" all "-" "not running" "skipped"; return; }
  if ! "$tool" axcheck "$pid" >/dev/null 2>"$work_dir/ax.err"; then
    record "$bundle" all "-" "Accessibility unhealthy: $(cat "$work_dir/ax.err")" "skipped"
    return
  fi
  window="$("$tool" find "$pid")"
  before="$("$tool" frame "$pid" "$window")"
  set_direct_open "$bundle"
  for mode in offscreen parked minimize hideApp; do
    log="$work_dir/$bundle-$mode.log"
    local observation="placement not confirmed"
    if start_placement "$mode" "$window" "$log" 6; then
      observation="$("$tool" visibility "$window" "$dropy_pid")"
    fi
    wait "$dropy_pid" 2>/dev/null || true
    dropy_pid=""
    sleep 1.5
    line="$(grep -oE 'Dropy placement: mode=.*' "$log" | tail -1 || true)"
    after="$("$tool" frame "$pid" "$window" 2>/dev/null || print gone)"
    local captured="$(grep -oE 'capture started: window=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$' || true)"
    local independent="restored; $observation"
    if [[ "$observation" == "placement not confirmed" ]]; then
      independent="NOT RUN: placement not confirmed"
    elif [[ "$mode" == parked && "$observation" != *"uncovered=0.000000"* ]]; then
      independent="LEAK: $observation"
    fi
    frames_match "$before" "$after" 2>/dev/null || independent="NOT restored ($after vs $before)"
    [[ "$captured" == "$window" && "$observation" != "placement not confirmed" ]] || independent="$independent; previewed window $captured, expected $window"
    record "$bundle" "$mode" \
      "$(print -r -- "$line" | grep -oE 'capture=\[[^]]*\] presented=\+[0-9]+' || print '-')" \
      "$(print -r -- "$line" | grep -oE 'windowServerLeak=[0-9.]+|failed=[A-Za-z]+' || print 'no result')" \
      "$independent"
    if ! frames_match "$before" "$after" 2>/dev/null; then
      record "$bundle" remaining "-" "source state changed" "stopped: recovery requires attention"
      break
    fi
  done
}

user_move_check() {
  local bundle=com.apple.TextEdit pid window before after log
  pid="$(pid_of "$bundle")"; window="$("$tool" find "$pid")"; before="$("$tool" frame "$pid" "$window")"
  set_direct_open "$bundle"; log="$work_dir/user-move.log"
  if ! start_placement offscreen "$window" "$log" 8; then
    stop_dropy
    record "$bundle" "user move during offscreen" "-" "placement not confirmed" "FAILED"
    return
  fi
  "$tool" move "$pid" "$window" 200 200
  wait "$dropy_pid" 2>/dev/null || true
  dropy_pid=""
  sleep 1
  after="$("$tool" frame "$pid" "$window")"
  local outcome="$(grep -oE 'restore=[A-Za-z]+' "$log" | tail -1 || true)"
  local result="kept user move"
  local expected=(${=before}); expected[1]=200; expected[2]=200
  frames_match "${(j: :)expected}" "$after" && [[ "$outcome" == "restore=keptUserChange" ]] || result="FAILED: $outcome, window at $after"
  # Restore only the scripted position; preserve every other source property.
  record "$bundle" "user move during offscreen" "-" "$outcome" "$result"
  local b=(${=before}); "$tool" move "$pid" "$window" "${b[1]}" "${b[2]}"
}

crash_check() {
  local bundle=com.apple.TextEdit pid window before parked after log
  pid="$(pid_of "$bundle")"; window="$("$tool" find "$pid")"; before="$("$tool" frame "$pid" "$window")"
  set_direct_open "$bundle"; log="$work_dir/crash.log"
  if ! start_placement parked "$window" "$log" 30; then
    stop_dropy
    record "$bundle" "crash while parked" "-" "placement not confirmed" "FAILED"
    return
  fi
  parked="$("$tool" frame "$pid" "$window")"
  kill -9 "$dropy_pid" 2>/dev/null || true
  wait "$dropy_pid" 2>/dev/null || true
  dropy_pid=""
  local journaled=no; [[ -f "$journal" ]] && journaled=yes
  DROPY_DEBUG_QUIT_AFTER=4 "$dropy" > "$work_dir/recover.log" 2>&1 || true
  sleep 1; after="$("$tool" frame "$pid" "$window")"
  local outcome="$(grep -oE 'placement recovery: mode=[a-zA-Z]+ outcome=[a-zA-Z()]+' "$work_dir/recover.log" | tail -1)"
  local result="restored after crash"
  frames_match "$before" "$after" && ! frames_match "$before" "$parked" && [[ "$journaled" == yes && "$outcome" == "placement recovery: mode=parked outcome=restored" && ! -f "$journal" ]] || result="FAILED: window at $after, journal present=$([[ -f $journal ]] && print yes || print no)"
  record "$bundle" "crash while parked" "parked at $parked; journal=$journaled" "${outcome:-no recovery logged}" "$result"
}

"$repo_dir/Scripts/build-local.sh" >/dev/null
swiftc -O -swift-version 6 -o "$tool" "$repo_dir/Scripts/bench/WindowTool.swift"
defaults export "$prefs_domain" "$work_dir/prefs.plist" 2>/dev/null || true
mkdir -p "$build_dir"
{
  print -r -- "# Dropy device checks (in progress)"
  print -r -- "Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)"
  print
  print -r -- "| App | Check | Capture while placed | Driver result | Independent check |"
  print -r -- "|---|---|---|---|---|"
} > "$report"
print "Device checks: placement matrix"
open_target com.apple.TextEdit
placement_checks com.apple.TextEdit
print "Device checks: user move and crash recovery"
if [[ ! -f "$journal" ]] && "$tool" axcheck "$(pid_of com.apple.TextEdit)" >/dev/null 2>&1; then
  user_move_check
  crash_check
else
  record com.apple.TextEdit "user move and crash recovery" "-" "Accessibility unhealthy" "skipped"
fi
osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true
open_target com.apple.Safari
placement_checks com.apple.Safari
osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true
for bundle in ${=EXTRA_APPS:-}; do
  open_target "$bundle"
  placement_checks "$bundle"
done

{
  print -r -- "# Dropy device checks"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z')"
  print -r -- "- Dropy: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); hardware: $(sysctl -n hw.model)"
  print -r -- "- Displays: $(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution/ {print $2}' | paste -sd ';' -)"
  print -r -- "- TextEdit $(mdls -raw -name kMDItemVersion /System/Applications/TextEdit.app); Safari $(mdls -raw -name kMDItemVersion /Applications/Safari.app)"
  print
  print -r -- "## Placement and recovery"
  print
  print -r -- "| App | Check | Capture while placed | Driver result | Independent check |"
  print -r -- "|---|---|---|---|---|"
  for row in $rows; do print -r -- "$row"; done
  print
  print -r -- "## Manual: dismissal"
  print
  print -r -- "Click-outside and pointer-leave: NOT RUN. Open the overlay with each preference; click another app and the Dropy menu, then enter and leave the overlay. Confirm close and focus handback, and that shortcut-open with the pointer elsewhere stays open."
  print
  print -r -- "## Manual: Screen Recording revocation"
  print
  print -r -- "Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with \`open\`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: \`failed.permissionDenied\`, preview cleared, source app untouched."
} > "$report"

if [[ $run_benchmark == yes ]]; then
  print "\nNext: the capture benchmark (~4 minutes). Leave the Mac idle; pause VPNs and media first."
  if [[ -t 0 ]]; then
    read -r "?Press Enter to start, or Ctrl-C to stop here (placement results are already saved). "
  fi
  caffeinate -d "$repo_dir/Scripts/benchmark.sh" 20 | tee "$work_dir/benchmark.txt"
  { print; print -r -- "## Benchmark"; print; sed -n '/^## /,$p' "$work_dir/benchmark.txt"; } >> "$report"
fi

print; cat "$report"; print; print -r -- "Report saved to $report"
