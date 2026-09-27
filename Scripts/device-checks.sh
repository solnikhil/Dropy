#!/bin/zsh
# One-session device checks for the M1 exit and the M2 placement matrix.
#
#   Scripts/device-checks.sh [--skip-benchmark]
#
# Runs, and writes one dated report to .build/local/device-checks-<timestamp>.md:
#   1. Placement matrix: offscreen, parked, minimize and hideApp against TextEdit
#      (AppKit) and a self-animating Safari page (WebKit), plus any apps listed in
#      EXTRA_APPS="<bundle-id> ..." (their frontmost window is used, then restored).
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
work_dir="$(mktemp -d)"
report="$build_dir/device-checks-$(date +%Y%m%d-%H%M%S).md"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"

for app in TextEdit Safari; do
  if pgrep -xq "$app"; then
    print -u2 "Quit $app first; the checks open and close their own $app windows."
    exit 1
  fi
done

"$repo_dir/Scripts/build-local.sh" >/dev/null
swiftc -O -swift-version 6 -o "$tool" "$repo_dir/Scripts/bench/WindowTool.swift"
defaults export "$prefs_domain" "$work_dir/prefs.plist" 2>/dev/null || true

cleanup() {
  pkill -x Dropy 2>/dev/null || true
  # A placement left behind by an interrupted check is undone by one Dropy launch.
  if [[ -f "$journal" ]]; then
    DROPY_DEBUG_QUIT_AFTER=3 "$dropy" >/dev/null 2>&1 || true
  fi
  for app in TextEdit Safari; do
    pgrep -xq "$app" && osascript -e "tell application \"$app\" to quit saving no" >/dev/null 2>&1 || true
  done
  [[ -f "$work_dir/prefs.plist" ]] && defaults import "$prefs_domain" "$work_dir/prefs.plist"
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

set_direct_open() {
  local json="{\"trigger\":\"notchClick\",\"openBehavior\":\"direct\",\"dismissBehavior\":\"manual\",\"contentMode\":\"fit\",\"sizePreset\":\"medium\",\"selectedBundleIdentifier\":\"$1\",\"lastUsedBundleIdentifier\":\"$1\"}"
  defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
}

# Opens the target and leaves exactly one window of it on screen below the overlay area.
open_target() {
  case "$1" in
    com.apple.TextEdit)
      for i in {1..40}; do print "Dropy device check line $i"; done > "$work_dir/check.txt"
      open -a TextEdit "$work_dir/check.txt"; sleep 2
      osascript -e 'tell application "TextEdit"
        close (every window whose name is not "check.txt") saving no
        set bounds of window "check.txt" to {80, 560, 880, 1000}
      end tell' >/dev/null ;;
    com.apple.Safari)
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

# frames_match "<x y w h m>" "<x y w h m>": positions and sizes within 2 pt, same minimized state.
frames_match() {
  local a=(${=1}) b=(${=2})
  for i in 1 2 3 4; do (( ${a[i]} - ${b[i]} <= 2 && ${b[i]} - ${a[i]} <= 2 )) || return 1; done
  [[ ${a[5]} == ${b[5]} ]]
}

rows=()
record() { rows+=("| $1 | $2 | $3 | $4 | $5 |"); print -r -- "  $1 · $2: $3 · $4 ($5)"; }

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
    pkill -x Dropy 2>/dev/null || true; sleep 0.5
    DROPY_DEBUG_PLACEMENT="$mode,6" DROPY_DEBUG_QUIT_AFTER=16 "$dropy" --show > "$log" 2>&1 || true
    sleep 1.5
    line="$(grep -oE 'Dropy placement: mode=.*' "$log" | tail -1)"
    after="$("$tool" frame "$pid" "$window" 2>/dev/null || print gone)"
    local captured="$(grep -oE 'capture started: window=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$')"
    local independent="restored"
    frames_match "$before" "$after" 2>/dev/null || independent="NOT restored ($after vs $before)"
    [[ "$captured" == "$window" ]] || independent="$independent; previewed window $captured, expected $window"
    record "$bundle" "$mode" \
      "$(print -r -- "$line" | grep -oE 'capture=\[[^]]*\] presented=\+[0-9]+' || print '-')" \
      "$(print -r -- "$line" | grep -oE 'windowServerLeak=[0-9.]+|failed=[A-Za-z]+' || print 'no result')" \
      "$independent"
    if ! frames_match "$before" "$after" 2>/dev/null; then
      local b=(${=before}); "$tool" move "$pid" "$window" "${b[1]}" "${b[2]}" 2>/dev/null || true
    fi
  done
}

user_move_check() {
  local bundle=com.apple.TextEdit pid window before after log
  pid="$(pid_of "$bundle")"; window="$("$tool" find "$pid")"; before="$("$tool" frame "$pid" "$window")"
  set_direct_open "$bundle"; log="$work_dir/user-move.log"
  pkill -x Dropy 2>/dev/null || true; sleep 0.5
  DROPY_DEBUG_PLACEMENT="offscreen,8" DROPY_DEBUG_QUIT_AFTER=16 "$dropy" --show > "$log" 2>&1 &
  sleep 5; "$tool" move "$pid" "$window" 200 200
  wait || true; sleep 1
  after="$("$tool" frame "$pid" "$window")"
  local outcome="$(grep -oE 'restore=[A-Za-z]+' "$log" | tail -1)"
  local result="kept user move"
  [[ "${after%% *}" == 200 && "$outcome" == "restore=keptUserChange" ]] || result="FAILED: $outcome, window at $after"
  record "$bundle" "user move during offscreen" "-" "$outcome" "$result"
  local b=(${=before}); "$tool" move "$pid" "$window" "${b[1]}" "${b[2]}"
}

crash_check() {
  local bundle=com.apple.TextEdit pid window before parked after log
  pid="$(pid_of "$bundle")"; window="$("$tool" find "$pid")"; before="$("$tool" frame "$pid" "$window")"
  set_direct_open "$bundle"; log="$work_dir/crash.log"
  pkill -x Dropy 2>/dev/null || true; sleep 0.5
  DROPY_DEBUG_PLACEMENT="parked,30" DROPY_DEBUG_QUIT_AFTER=40 "$dropy" --show > "$log" 2>&1 &
  local dropy_pid=$!
  sleep 5; parked="$("$tool" frame "$pid" "$window")"
  kill -9 "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true
  local journaled=no; [[ -f "$journal" ]] && journaled=yes
  DROPY_DEBUG_QUIT_AFTER=4 "$dropy" > "$work_dir/recover.log" 2>&1 || true
  sleep 1; after="$("$tool" frame "$pid" "$window")"
  local outcome="$(grep -oE 'placement recovery: mode=[a-zA-Z]+ outcome=[a-zA-Z()]+' "$work_dir/recover.log" | tail -1)"
  local result="restored after crash"
  frames_match "$before" "$after" && [[ ! -f "$journal" ]] || result="FAILED: window at $after, journal present=$([[ -f $journal ]] && print yes || print no)"
  record "$bundle" "crash while parked" "parked at $parked; journal=$journaled" "${outcome:-no recovery logged}" "$result"
}

print "Device checks: placement matrix"
open_target com.apple.TextEdit
placement_checks com.apple.TextEdit
print "Device checks: user move and crash recovery"
if "$tool" axcheck "$(pid_of com.apple.TextEdit)" >/dev/null 2>&1; then
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
  print -r -- "## Manual: Screen Recording revocation"
  print
  print -r -- "Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with \`open\`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: \`failed.permissionDenied\`, preview cleared, source app untouched."
} > "$report"

if [[ $run_benchmark == yes ]]; then
  print "\nNext: the capture benchmark (~4 minutes). Leave the Mac idle; pause VPNs and media first."
  read -r "?Press Enter to start, or Ctrl-C to stop here (placement results are already saved). "
  caffeinate -d "$repo_dir/Scripts/benchmark.sh" 20 | tee "$work_dir/benchmark.txt"
  { print; print -r -- "## Benchmark"; print; sed -n '/^## /,$p' "$work_dir/benchmark.txt"; } >> "$report"
fi

print; cat "$report"; print; print -r -- "Report saved to $report"
