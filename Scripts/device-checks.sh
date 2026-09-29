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
#   4. Space recovery, against a disposable fixture app (Scripts/bench/Fixture) that
#      moves its own window to another desktop: a restore must still find the exact
#      window there, or keep the journal entry and finish once the window is back,
#      including after a crash. Needs at least two desktops in Mission Control.
#   5. The capture benchmark (Scripts/benchmark.sh), unless --skip-benchmark.
# Screen Recording revocation cannot be automated; the report lists the manual steps.
#
# Every step records the active Space and frontmost app before and after, so a
# person switching desktops during a run is reported rather than misread as a
# placement side effect, and a failed step saves an Accessibility snapshot
# (WindowTool snapshot) to the logs.
#
#   ONLY=fixture Scripts/device-checks.sh --skip-benchmark   runs only the fixture checks.
#   ONLY=textedit Scripts/device-checks.sh --skip-benchmark  runs only TextEdit, user move and crash recovery.
#   ONLY=electron Scripts/device-checks.sh --skip-benchmark  the same against the disposable Electron
#                 fixture (Scripts/bench/ElectronFixture, throwaway profile) showing the animation page.
#
#   ONLY=safari Scripts/device-checks.sh --skip-benchmark  Safari (animating local page) placement,
#                 user move and crash recovery.
#   ONLY=media Scripts/device-checks.sh --skip-benchmark  the same against QuickTime Player playing a
#                 generated test movie (Scripts/bench/MovieMaker.swift); needs QuickTime not running.
#                 QuickTime is driven without Apple Events (no Automation permission).
#   CHECK_OTHER_DESKTOP=1 adds normal/crash parked recovery on another desktop.
#
# Needs a terminal with Screen Recording and Accessibility permission, the display
# awake, and TextEdit, Safari and the fixture not running. Every window is restored afterwards.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
dropy="$build_dir/Dropy.app/Contents/MacOS/Dropy"
tool="$build_dir/WindowTool"
fixture_app="$build_dir/DropyFixture.app"
only="${ONLY:-all}"
journal="$HOME/Library/Application Support/Dropy/placement-journal.json"
run_benchmark=yes
[[ "${1:-}" == "--skip-benchmark" ]] && run_benchmark=no
report="$build_dir/device-checks-$(date +%Y%m%d-%H%M%S).md"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"

if lsappinfo info -only pid -app org.dropy.electronfixture 2>/dev/null | grep -q '[0-9]'; then
  print -u2 "Quit DropyElectronFixture first."; exit 1
fi
[[ "$only" == media ]] && pgrep -xq "QuickTime Player" && { print -u2 "Quit QuickTime Player first."; exit 1; }
for app in Dropy TextEdit Safari DropyFixture; do
  if pgrep -xq "$app"; then
    print -u2 "Quit $app first; the checks open and close their own $app windows."
    exit 1
  fi
done

if [[ -f "$journal" ]]; then
  print -u2 "Recover the existing placement journal before running device checks."
  exit 1
fi
source "${0:A:h}/lib/device-session.zsh"
device_session_begin device-checks || exit 1
work_dir="$(mktemp -d)"
dropy_pid=""
fixture_pid=""
owned_apps=()
rows=()
prefs_touched=no
space_return_key=""
space_home=""

cleaned_up=no
cleanup() {
  [[ "$cleaned_up" == no ]] || return 0
  cleaned_up=yes
  stop_dropy
  stop_fixture
  stop_electron
  return_test_desktop
  # A placement left behind by an interrupted check is undone by one Dropy launch.
  if [[ -f "$journal" ]]; then
    DROPY_DEBUG_QUIT_AFTER=3 "$dropy" >/dev/null 2>&1 || true
  fi
  for app in $owned_apps; do
    # QuickTime is ended without Apple Events: its only documents are generated movies.
    if [[ "$app" == "QuickTime Player" ]]; then pkill -x "QuickTime Player" 2>/dev/null || true; continue; fi
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
  for logfile in "$work_dir"/*.log(N) "$work_dir"/*.jsonl(N) "$work_dir"/ax.err(N); do
    cp "$logfile" "$logs/"
  done
  rm -rf "$work_dir"
  device_session_end
}
trap cleanup EXIT
# zsh 5.9 skips EXIT traps (and `always` blocks) when errexit fires inside a function,
# which left a fixture window and test preferences behind. ZERR fires in the same cases.
on_error() {
  (( ZSH_SUBSHELL == 0 )) || return 0
  print -u2 "device-checks: stopped by a failed command near line $1; restoring state"
  cleanup
  exit 1
}
trap 'on_error $LINENO' ZERR
# A signal also interrupts the command being waited on; restore state and report the
# signal instead of the interrupted command.
on_signal() {
  trap - ZERR
  print -u2 "device-checks: stopped by $1; restoring state"
  cleanup
  exit "$2"
}
trap 'on_signal SIGINT 130' INT
trap 'on_signal SIGTERM 143' TERM

stop_dropy() {
  if [[ -n "$dropy_pid" ]]; then
    kill "$dropy_pid" 2>/dev/null || true
    wait "$dropy_pid" 2>/dev/null || true
    dropy_pid=""
  fi
}

stop_fixture() {
  if [[ -n "$fixture_pid" ]]; then
    # Bring the window home first, so no fixture window is left on another desktop.
    "$tool" fixture space:home 2>/dev/null || true
    "$tool" fixture quit 2>/dev/null || true
    for i in {1..20}; do kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
    kill "$fixture_pid" 2>/dev/null || true
    fixture_pid=""
  fi
}

electron_pid=""
stop_electron() {
  # Ask through the command channel even when the fixture never reported ready.
  [[ -f "$work_dir/electron-commands.txt" ]] && { print quit >> "$work_dir/electron-commands.txt" 2>/dev/null || true; }
  [[ -n "$electron_pid" ]] || return 0
  for i in {1..30}; do kill -0 "$electron_pid" 2>/dev/null || break; sleep 0.1; done
  kill "$electron_pid" 2>/dev/null || true
  electron_pid=""
}

# Active Space and frontmost app, e.g. "active=4 frontmost=com.apple.Terminal".
desktop_state() { "$tool" spaces 2>/dev/null || print "active=unknown frontmost=unknown"; }

# Describes a desktop change between two desktop_state readings, or nothing.
interference() {
  local before_space="${${1#active=}%% *}" after_space="${${2#active=}%% *}"
  [[ "$before_space" == "$after_space" ]] || print -rn -- "; person switched desktop $before_space→$after_space during the step"
}

# Appends one Accessibility snapshot of the window to the logs.
snapshot() {
  local label="$1" pid="$2" window="$3"
  { print -rn -- "{\"step\":\"$label\",\"snapshot\":"; "$tool" snapshot "$pid" "$window" 2>/dev/null || print -n null; print "}"; } \
    >> "$work_dir/snapshots.jsonl"
}

# The classification from a fresh snapshot, e.g. "found" or "space:otherSpace".
classification() {
  "$tool" snapshot "$1" "$2" 2>/dev/null | grep -oE '"classification":"[^"]*"' | cut -d'"' -f4
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
      open -a TextEdit "$work_dir/check.txt" --args -ApplePersistenceIgnoreState YES; sleep 2
      osascript -e 'tell application "TextEdit"
        close (every window whose name is not "check.txt") saving no
        set bounds of window "check.txt" to {80, 560, 880, 1000}
      end tell' >/dev/null ;;
    com.apple.Safari)
      owned_apps+=(Safari)
      open -a Safari "$repo_dir/Scripts/bench/animation.html" --args -ApplePersistenceIgnoreState YES
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
    com.apple.QuickTimePlayerX)
      owned_apps+=("QuickTime Player")
      swiftc -O -swift-version 6 -o "$build_dir/MovieMaker" "$repo_dir/Scripts/bench/MovieMaker.swift"
      swiftc -O -swift-version 6 -o "$build_dir/HIDTool" "$repo_dir/Scripts/bench/HIDTool/main.swift"
      "$build_dir/MovieMaker" "$work_dir/dropy-media.mov" 240 >/dev/null
      open -a "QuickTime Player" "$work_dir/dropy-media.mov" --args -ApplePersistenceIgnoreState YES
      sleep 3
      local qt="$(pid_of com.apple.QuickTimePlayerX)" qw
      qw="$("$tool" find "$qt" 2>/dev/null || true)"
      [[ -n "$qw" ]] && "$tool" move "$qt" "$qw" 80 560 >/dev/null 2>&1 || true
      # Start playback as a person would: QuickTime is frontmost after opening; Space plays.
      if [[ "$("$build_dir/HIDTool" frontmost)" == com.apple.QuickTimePlayerX ]]; then "$build_dir/HIDTool" key 49
      else print -u2 "QuickTime not frontmost; playback not started"; fi
      sleep 1 ;;
    org.dropy.electronfixture)
      : > "$work_dir/electron-commands.txt"
      open -n "$build_dir/DropyElectronFixture.app" --args --mode animation --page animation.html \
        --log "$work_dir/electron.jsonl" --commands "$work_dir/electron-commands.txt" --profile "$work_dir/electron-profile"
      for i in {1..60}; do grep -q '"kind":"ready"' "$work_dir/electron.jsonl" 2>/dev/null && break; sleep 0.25; done
      electron_pid="$(grep '"kind":"ready"' "$work_dir/electron.jsonl" | grep -oE '"pid":[0-9]+' | cut -d: -f2)"
      local window="$(grep '"kind":"ready"' "$work_dir/electron.jsonl" | grep -oE '"A":[0-9]+' | cut -d: -f2)"
      "$tool" move "$electron_pid" "$window" 80 560 >/dev/null 2>&1 || true
      sleep 1 ;;
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
  local bundle="$1" pid window before after log line observation desk_before desk_after captured independent driver
  pid="$(pid_of "$bundle")"
  [[ -n "$pid" ]] || { record "$bundle" all "-" "not running" "skipped"; return; }
  window="$("$tool" find "$pid" 2>/dev/null || true)"
  if [[ -z "$window" ]] || ! "$tool" axcheck "$pid" "$window" >/dev/null 2>"$work_dir/ax.err"; then
    [[ -n "$window" ]] && snapshot "$bundle-precheck" "$pid" "$window"
    record "$bundle" all "-" "window not reachable: $(cat "$work_dir/ax.err" 2>/dev/null || true)" "skipped"
    return
  fi
  before="$("$tool" frame "$pid" "$window")"
  set_direct_open "$bundle"
  for mode in offscreen parked minimize hideApp; do
    log="$work_dir/$bundle-$mode.log"
    observation="placement not confirmed"
    desk_before="$(desktop_state)"
    snapshot "$bundle-$mode-before" "$pid" "$window"
    if start_placement "$mode" "$window" "$log" 6; then
      observation="$("$tool" visibility "$window" "$dropy_pid")"
    fi
    wait "$dropy_pid" 2>/dev/null || true
    dropy_pid=""
    sleep 1.5
    desk_after="$(desktop_state)"
    line="$(grep -oE 'Dropy placement: mode=.*' "$log" | tail -1 || true)"
    after="$("$tool" frame "$pid" "$window" 2>/dev/null || print "gone:$(classification "$pid" "$window")")"
    captured="$(grep -oE 'capture started: window=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$' || true)"
    independent="restored; $observation"
    if [[ "$observation" == "placement not confirmed" ]]; then
      independent="NOT RUN: placement not confirmed"
    elif [[ "$mode" == parked && "$observation" != *"uncovered=0.000000"* ]]; then
      independent="LEAK: $observation"
    fi
    frames_match "$before" "$after" 2>/dev/null || independent="NOT restored ($after vs $before)"
    [[ "$captured" == "$window" && "$observation" != "placement not confirmed" ]] || independent="$independent; previewed window $captured, expected $window"
    independent="$independent$(interference "$desk_before" "$desk_after")"
    driver="$(print -r -- "$line" | grep -oE 'windowServerLeak=[0-9.]+|failed=[^ ]+|skipped=[^ ]+' || true)"
    [[ -n "$driver" ]] || driver="$(grep -oE 'placement: mode=[a-zA-Z]+ (failed|skipped)=[^ ]+' "$log" | tail -1 | cut -d' ' -f3- || print 'no result')"
    frames_match "$before" "$after" 2>/dev/null || snapshot "$bundle-$mode-after" "$pid" "$window"
    record "$bundle" "$mode" \
      "$(print -r -- "$line" | grep -oE 'capture=\[[^]]*\] presented=\+[0-9]+' || print '-')" \
      "$driver; $(print -r -- "$line" | grep -oE 'restore=[^ ]+' || print 'restore=none')" \
      "$independent"
    if ! frames_match "$before" "$after" 2>/dev/null; then
      record "$bundle" remaining "-" "source state changed" "stopped: recovery requires attention"
      break
    fi
  done
}

user_move_check() {
  local bundle="${1:-com.apple.TextEdit}" pid window before after log
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
  local outcome="$(grep -oE 'restore=[^ ]+' "$log" | tail -1 || true)"
  local result="kept user move"
  local expected=(${=before}); expected[1]=200; expected[2]=200
  frames_match "${(j: :)expected}" "$after" && [[ "$outcome" == "restore=keptUserChange" ]] || result="FAILED: $outcome, window at $after"
  # Restore only the scripted position; preserve every other source property.
  record "$bundle" "user move during offscreen" "-" "$outcome" "$result"
  local b=(${=before}); "$tool" move "$pid" "$window" "${b[1]}" "${b[2]}"
}

crash_check() {
  local bundle="${1:-com.apple.TextEdit}" pid window before parked after log
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
  local outcome="$(grep -oE 'placement recovery: mode=[a-zA-Z]+ window=[0-9]+ outcome=[^ ]+' "$work_dir/recover.log" | tail -1 || true)"
  local result="restored after crash"
  frames_match "$before" "$after" && ! frames_match "$before" "$parked" && [[ "$journaled" == yes && "$outcome" == "placement recovery: mode=parked window=$window outcome=restored" && ! -f "$journal" ]] || result="FAILED: window at $after, journal present=$([[ -f $journal ]] && print yes || print no)"
  record "$bundle" "crash while parked" "parked at $parked; journal=$journaled" "${outcome:-no recovery logged}" "$result"
}

# Starts the fixture and sets fixture_window to its window ID.
start_fixture() {
  stop_fixture
  : > "$work_dir/fixture.out"
  # Launch through LaunchServices: a directly executed binary has no launch date, and
  # Dropy rightly refuses to form an exact window identity without one.
  open -n --stdout "$work_dir/fixture.out" --stderr "$work_dir/fixture.out" "$fixture_app"
  fixture_window=""
  for i in {1..40}; do
    fixture_window="$(grep -oE 'window=[0-9]+' "$work_dir/fixture.out" | head -1 | cut -d= -f2)"
    [[ -n "$fixture_window" ]] && break
    sleep 0.25
  done
  fixture_pid="$(pid_of org.dropy.fixture)"
  [[ -n "$fixture_window" && -n "$fixture_pid" ]]
}

# Moves the fixture window to another desktop and waits for it to report the move.
# Returns 1 when there is no other desktop.
# Return only the desktop change this check made; never drive an app's UI.
return_test_desktop() {
  [[ -n "$space_return_key" ]] || return 0
  "$build_dir/HIDTool" key "$space_return_key" ctrl
  sleep 1.5
  space_return_key=""
  [[ "${$(desktop_state)#active=}" == "$space_home "* ]] || {
    print -u2 "Could not return to the starting desktop; stop device verification."
    return 1
  }
}

# Recovery while the source lives on another desktop. Electron moves its own
# disposable window; TextEdit stays put while the harness changes desktop and
# returns afterwards. Both normal dismissal and a killed Dropy are checked.
source_space_recovery() {
  local bundle="$1" pid window before after log outcome result active direction
  pid="$(pid_of "$bundle")"; window="$("$tool" find "$pid")"
  before="$("$tool" frame "$pid" "$window")"
  set_direct_open "$bundle"
  if [[ "$bundle" == com.apple.TextEdit ]]; then
    swiftc -O -swift-version 6 -o "$build_dir/HIDTool" "$repo_dir/Scripts/bench/HIDTool/main.swift"
  fi
  for crash in no yes; do
    log="$work_dir/$bundle-other-desktop-$crash.log"
    local hold=8; [[ "$crash" == yes ]] && hold=30
    start_placement parked "$window" "$log" "$hold" || { stop_dropy; record "$bundle" "other desktop ($crash crash)" - - FAILED; return; }
    if [[ "$bundle" == org.dropy.electronfixture ]]; then
      print space:other >> "$work_dir/electron-commands.txt"
      sleep 1
      local moved="$(grep '"kind":"space"' "$work_dir/electron.jsonl" | tail -1)"
      if [[ "$moved" == *'"error"'* || -z "$moved" ]]; then
        stop_dropy; print space:home >> "$work_dir/electron-commands.txt"
        record "$bundle" "other desktop ($crash crash)" - "$moved" "NOT RUN: needs another desktop"; return
      fi
    else
      space_home="${${$(desktop_state)#active=}%% *}"
      for direction in 124 123; do
        "$build_dir/HIDTool" key "$direction" ctrl; sleep 1.5
        active="${${$(desktop_state)#active=}%% *}"
        if [[ "$active" != "$space_home" ]]; then
          [[ "$direction" == 124 ]] && space_return_key=123 || space_return_key=124
          break
        fi
      done
      if [[ -z "$space_return_key" ]]; then
        stop_dropy; record "$bundle" "other desktop ($crash crash)" - - "NOT RUN: cannot switch desktop"; return
      fi
    fi
    if ! "$tool" snapshot "$pid" "$window" | python3 -c 'import json,sys; d=json.load(sys.stdin); w=next((w for w in d.get("serverWindows",[]) if w["id"]==int(sys.argv[1])),{}); a=set(d.get("activeSpaces",[])); b=set(w.get("spaces",[])); sys.exit(0 if a and b and a.isdisjoint(b) else 1)' "$window"; then
      stop_dropy
      [[ "$bundle" == org.dropy.electronfixture ]] && print space:home >> "$work_dir/electron-commands.txt"
      return_test_desktop
      record "$bundle" "other desktop ($crash crash)" - - "FAILED: source is not on another desktop"
      return 1
    fi
    snapshot "$bundle-other-desktop-before-restore-$crash" "$pid" "$window"
    if [[ "$crash" == yes ]]; then
      kill -9 "$dropy_pid"; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""
      DROPY_DEBUG_QUIT_AFTER=5 "$dropy" > "$log.relaunch.log" 2>&1 || true
      outcome="$(grep -oE "placement recovery: mode=parked window=$window outcome=[^ ]+" "$log.relaunch.log" | tail -1 || true)"
    else
      wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""
      outcome="$(grep -oE 'restore=[^ ]+' "$log" | tail -1 || true)"
    fi
    after="$("$tool" frame "$pid" "$window" 2>/dev/null || true)"
    result="restored on another desktop"
    frames_match "$before" "$after" && [[ "$outcome" == *restored && ! -f "$journal" ]] || result="FAILED: $outcome; $after"
    record "$bundle" "parked recovery on another desktop (crash=$crash)" - "$outcome" "$result"
    if [[ "$bundle" == org.dropy.electronfixture ]]; then
      print space:home >> "$work_dir/electron-commands.txt"; sleep 1
    else
      return_test_desktop || return 1
    fi
    [[ "$result" != FAILED* ]] || return 1
  done
}

fixture_to_other_space() {
  local out="$work_dir/fixture.out" reports now active
  reports="$(grep -c 'space=' "$out")"
  "$tool" fixture space:other
  for i in {1..30}; do
    grep -q 'error=unsupported' "$out" && return 1
    (( $(grep -c 'space=' "$out") > reports )) && break
    sleep 0.1
  done
  now="$(grep -oE 'space=[0-9,]+' "$out" | tail -1 | cut -d= -f2)"
  active="$(desktop_state | cut -d' ' -f1 | cut -d= -f2)"
  [[ -n "$now" && ",$active," != *",$now,"* ]]
}

fixture_home() { "$tool" fixture space:home; sleep 0.8; }

# Parks the fixture, then moves its window to another desktop while it is still the
# app's main window. The restore must reach it there through the main window.
fixture_space_main_check() {
  local check="parked, moved to another desktop" log="$work_dir/fixture-space-main.log" before after outcome
  start_fixture || { record fixture "$check" "-" "fixture did not start" "NOT RUN"; return; }
  before="$("$tool" frame "$fixture_pid" "$fixture_window")"
  set_direct_open org.dropy.fixture
  if ! start_placement parked "$fixture_window" "$log" 6; then
    stop_dropy; record fixture "$check" "-" "placement not confirmed" "FAILED"; return
  fi
  if ! fixture_to_other_space; then
    stop_dropy; fixture_home; record fixture "$check" "-" "only one desktop" "NOT RUN: add a second desktop"; return
  fi
  local where="$(classification "$fixture_pid" "$fixture_window")"
  snapshot "fixture-space-main-away" "$fixture_pid" "$fixture_window"
  wait "$dropy_pid" 2>/dev/null || true
  dropy_pid=""
  outcome="$(grep -oE 'restore=[^ ]+' "$log" | tail -1 || true)"
  fixture_home
  after="$("$tool" frame "$fixture_pid" "$fixture_window" 2>/dev/null || print gone)"
  local result="restored on the other desktop"
  frames_match "$before" "$after" && [[ "$outcome" == restore=restored && ! -f "$journal" ]] || \
    result="FAILED: $outcome, window at $after, journal present=$([[ -f $journal ]] && print yes || print no)"
  record fixture "$check" "window while away: $where" "$outcome" "$result"
}

# Parks the fixture, opens a second fixture window (so the parked one is neither main
# nor focused), then moves the parked window to another desktop. Its app no longer
# lists it, so the restore must defer and keep the journal, then finish on its own
# once the window is back on the active desktop. With crash=yes, Dropy is killed
# while the window is away and a fresh launch must do the same from the journal.
fixture_space_deferred_check() {
  local crash="$1" check log before after outcome deferred_outcome retry="" journal_while_away=no
  check="parked, moved to another desktop, not main"
  [[ $crash == no ]] || check="$check, Dropy killed"
  log="$work_dir/fixture-space-deferred-$crash.log"
  start_fixture || { record fixture "$check" "-" "fixture did not start" "NOT RUN"; return; }
  before="$("$tool" frame "$fixture_pid" "$fixture_window")"
  set_direct_open org.dropy.fixture
  local hold=6
  [[ $crash == no ]] || hold=60
  if ! start_placement parked "$fixture_window" "$log" "$hold"; then
    stop_dropy; record fixture "$check" "-" "placement not confirmed" "FAILED"; return
  fi
  "$tool" fixture second; sleep 0.8
  if ! fixture_to_other_space; then
    stop_dropy; fixture_home; record fixture "$check" "-" "only one desktop" "NOT RUN: add a second desktop"; return
  fi
  local where="$(classification "$fixture_pid" "$fixture_window")"
  snapshot "fixture-space-deferred-$crash-away" "$fixture_pid" "$fixture_window"
  if [[ $crash == yes ]]; then
    kill -9 "$dropy_pid" 2>/dev/null || true
    wait "$dropy_pid" 2>/dev/null || true
    dropy_pid=""
    log="$work_dir/fixture-space-deferred-relaunch.log"
    DROPY_DEBUG_QUIT_AFTER=20 "$dropy" > "$log" 2>&1 &
    dropy_pid=$!
  fi
  # Wait for the deferred restore while the window is away.
  for i in {1..60}; do
    deferred_outcome="$(grep -oE '(restore|outcome)=deferred[^ ]*' "$log" | tail -1 || true)"
    [[ -n "$deferred_outcome" ]] && break
    kill -0 "$dropy_pid" 2>/dev/null || break
    sleep 0.25
  done
  [[ -f "$journal" ]] && journal_while_away=yes
  fixture_home
  # Automatic recovery retries within its backoff (1, 2, 4… seconds).
  for i in {1..40}; do
    retry="$(grep -oE "placement recovery: mode=parked window=$fixture_window outcome=[^ ]+" "$log" | grep -v deferred | tail -1 || true)"
    [[ -n "$retry" && ! -f "$journal" ]] && break
    sleep 0.25
  done
  stop_dropy
  after="$("$tool" frame "$fixture_pid" "$fixture_window" 2>/dev/null || print gone)"
  local result="kept the record while away, restored automatically on return"
  frames_match "$before" "$after" && [[ -n "$deferred_outcome" && $journal_while_away == yes && \
    "$retry" == *outcome=restored && ! -f "$journal" ]] || \
    result="FAILED: deferred=${deferred_outcome:-none} journalWhileAway=$journal_while_away retry=${retry:-none} window at $after, journal present=$([[ -f $journal ]] && print yes || print no)"
  record fixture "$check" "window while away: $where" "${deferred_outcome:-no deferral}; then ${retry##*outcome=}" "$result"
}

"$repo_dir/Scripts/build-local.sh" >/dev/null
swiftc -O -swift-version 6 -o "$tool" "$repo_dir"/Scripts/bench/WindowTool/*.swift
"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null
defaults export "$prefs_domain" "$work_dir/prefs.plist" 2>/dev/null || true
mkdir -p "$build_dir"
{
  print -r -- "# Dropy device checks (in progress)"
  print -r -- "Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)"
  print
  print -r -- "| App | Check | Capture while placed | Driver result | Independent check |"
  print -r -- "|---|---|---|---|---|"
} > "$report"
desktop_at_start="$(desktop_state)"
if [[ "$only" == all || "$only" == fixture ]]; then
  print "Device checks: Space recovery (fixture)"
  start_fixture && placement_checks org.dropy.fixture
  stop_fixture
  fixture_space_main_check
  fixture_space_deferred_check no
  fixture_space_deferred_check yes
  stop_fixture
fi
if [[ "$only" == all || "$only" == textedit ]]; then
  print "Device checks: placement matrix"
  open_target com.apple.TextEdit
  placement_checks com.apple.TextEdit
  print "Device checks: user move and crash recovery"
  if [[ ! -f "$journal" ]] && "$tool" axcheck "$(pid_of com.apple.TextEdit)" >/dev/null 2>&1; then
    user_move_check
    crash_check
    [[ "${CHECK_OTHER_DESKTOP:-0}" == 1 ]] && source_space_recovery com.apple.TextEdit
  else
    record com.apple.TextEdit "user move and crash recovery" "-" "$([[ -f $journal ]] && print 'journal still present' || print 'Accessibility unhealthy')" "skipped"
  fi
  osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true
fi
if [[ "$only" == safari ]]; then
  print "Device checks: Safari (WebKit) placement, user move and crash recovery"
  open_target com.apple.Safari
  placement_checks com.apple.Safari
  if [[ ! -f "$journal" ]] && "$tool" axcheck "$(pid_of com.apple.Safari)" >/dev/null 2>&1; then
    user_move_check com.apple.Safari
    crash_check com.apple.Safari
  else
    record com.apple.Safari "user move and crash recovery" "-" "$([[ -f $journal ]] && print 'journal still present' || print 'Accessibility unhealthy')" "skipped"
  fi
  osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true
fi
if [[ "$only" == media ]]; then
  print "Device checks: QuickTime Player (media) placement, user move and crash recovery"
  open_target com.apple.QuickTimePlayerX
  qt_pid="$(pid_of com.apple.QuickTimePlayerX)"
  placement_checks com.apple.QuickTimePlayerX
  if [[ ! -f "$journal" ]] && "$tool" axcheck "$qt_pid" >/dev/null 2>&1; then
    user_move_check com.apple.QuickTimePlayerX
    crash_check com.apple.QuickTimePlayerX
  else
    record com.apple.QuickTimePlayerX "user move and crash recovery" "-" "$([[ -f $journal ]] && print 'journal still present' || print 'Accessibility unhealthy')" "skipped"
  fi
  pkill -x "QuickTime Player" 2>/dev/null || true
fi
if [[ "$only" == all || "$only" == electron ]]; then
  print "Device checks: Electron fixture placement, user move and crash recovery"
  "$repo_dir/Scripts/bench/build-electron-fixture.sh" >/dev/null
  open_target org.dropy.electronfixture
  placement_checks org.dropy.electronfixture
  if [[ ! -f "$journal" ]] && "$tool" axcheck "$electron_pid" >/dev/null 2>&1; then
    user_move_check org.dropy.electronfixture
    crash_check org.dropy.electronfixture
    [[ "${CHECK_OTHER_DESKTOP:-0}" == 1 ]] && source_space_recovery org.dropy.electronfixture
  else
    record org.dropy.electronfixture "user move and crash recovery" "-" "$([[ -f $journal ]] && print 'journal still present' || print 'Accessibility unhealthy')" "skipped"
  fi
  stop_electron
fi
if [[ "$only" == all ]]; then
  open_target com.apple.Safari
  placement_checks com.apple.Safari
  osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true
  for bundle in ${=EXTRA_APPS:-}; do
    open_target "$bundle"
    placement_checks "$bundle"
  done
fi

{
  print -r -- "# Dropy device checks"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z')"
  print -r -- "- Dropy: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); hardware: $(sysctl -n hw.model)"
  print -r -- "- Displays: $(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution/ {print $2}' | paste -sd ';' -)"
  print -r -- "- TextEdit $(mdls -raw -name kMDItemVersion /System/Applications/TextEdit.app); Safari $(mdls -raw -name kMDItemVersion /Applications/Safari.app); Electron fixture $(grep -oE '"electron":"[^"]*"' "$work_dir/electron.jsonl" 2>/dev/null | head -1 | cut -d'"' -f4 || print 'not run')"
  print -r -- "- Checks: $only; extra apps: ${EXTRA_APPS:-none}"
  print -r -- "- Desktop session: $device_session_summary"
  print -r -- "- Desktop at start: $desktop_at_start; at end: $(desktop_state)"
  print
  print -r -- "## Placement and recovery"
  print
  print -r -- "| App | Check | Capture while placed | Driver result | Independent check |"
  print -r -- "|---|---|---|---|---|"
  for row in $rows; do print -r -- "$row"; done
  print
  print -r -- "Dismissal (Esc, shortcut, click-outside, pointer-leave, focus handback) is checked separately by \`Scripts/dismissal-checks.sh\`; input routing by \`Scripts/interactive-checks.sh\`."
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

# Keep the report on failure, but never let an incomplete recovery run look passing.
if (( ${#rows} == 0 )) || print -r -- "$rows" | grep -Eq 'FAILED|NOT RUN|NOT restored|LEAK:|skipped|stopped:|person switched desktop'; then
  print -u2 "Device checks failed or were incomplete; see the report above."
  exit 1
fi
