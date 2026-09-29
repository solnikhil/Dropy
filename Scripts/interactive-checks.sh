#!/bin/zsh
# End-to-end interactive preview check (M3): real HID clicks, scrolls and keys on Dropy's
# preview must reach window A of the input fixture, and never window B, while B is the
# fixture's key window. Runs with A visible and with A moved beyond the displays.
#
#   Scripts/interactive-checks.sh
#
# Uses the shipped Resources/InputEvidence.json, so it checks the evidence, the planner,
# the router and the preview mapping together. The pointer moves during the run and is
# put back. Leave the Mac alone for about a minute.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
dropy="$build_dir/Dropy.app/Contents/MacOS/Dropy"
hid="$build_dir/HIDTool"
probe="$build_dir/InputProbe"
tool="$build_dir/WindowTool"
journal="$HOME/Library/Application Support/Dropy/placement-journal.json"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$build_dir/interactive-checks-$stamp.md"
logs="${report%.md}-logs"

for app in Dropy DropyFixture DropyInputFixture; do
  pgrep -xq "$app" && { print -u2 "Quit $app first."; exit 1; }
done
[[ -e "$journal" ]] && { print -u2 "Recover the pending placement journal first."; exit 1; }

source "${0:A:h}/lib/device-session.zsh"
device_session_begin interactive-checks || exit 1
# Protect builds too: another run must not replace a running app or its dylib.
trap device_session_end EXIT
"$repo_dir/Scripts/build-local.sh" >/dev/null
"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$hid" "$repo_dir/Scripts/bench/HIDTool/main.swift"
swiftc -O -swift-version 6 -o "$probe" "$repo_dir"/Scripts/bench/InputProbe/*.swift
swiftc -O -swift-version 6 -o "$tool" "$repo_dir"/Scripts/bench/WindowTool/*.swift
swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker "$build_dir" -o "$build_dir/DeviceInputRouterChecks" \
  "$repo_dir/Tests/DeviceInputRouterCheck.swift" "$repo_dir/Sources/Dropy/InputRouter.swift" \
  "$repo_dir/Sources/Dropy/PlacementJournal.swift" "$repo_dir/Sources/Dropy/WindowPlacer.swift" \
  "$repo_dir/Sources/Dropy/WindowCatalog.swift"
"$probe" check-modifiers
mkdir -p "$logs"
work="$(mktemp -d)"
defaults export "$prefs_domain" "$work/prefs.plist" 2>/dev/null || true
pointer_start=(${=$("$hid" pointer)})
fixture_log="$logs/fixture.jsonl"
dropy_pid=""
rows=()
owned_textedit=false

cleanup() {
  [[ -n "${electron_pid:-}" ]] && { kill "$electron_pid" 2>/dev/null || true; electron_pid=""; }
  if [[ "$owned_textedit" == true ]]; then
    osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true
    owned_textedit=false
  fi
  "$hid" release >/dev/null 2>&1 || true
  [[ -n "$dropy_pid" ]] && { kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""; }
  "$probe" send quit >/dev/null 2>&1 || true
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

record() {
  rows+=("| $1 | $2 | $3 | $4 |")
  print -r -- "  $1 · $2: $3 ($4)"
}

# Counts effect lines per window since a log line number: "A=<n> B=<n>".
effects_since() {
  local from="$1" effect="$2"
  tail -n +"$((from + 1))" "$fixture_log" | python3 -c "
import json,sys
counts={'A':0,'B':0}
for line in sys.stdin:
    try: d=json.loads(line)
    except: continue
    if d.get('kind')=='effect' and d.get('effect')=='$effect' and d.get('w') in counts: counts[d['w']]+=1
print('A=%d B=%d' % (counts['A'], counts['B']))"
}
log_mark() { wc -l < "$fixture_log" | tr -d ' '; }

# Global point on the preview for a point in window A (fit, centred), from Dropy's log.
preview_point() {
  local wx="$1" wy="$2"
  python3 -c "
px,py,pw,ph=$preview
ww,wh=$window_size
s=min(pw/ww, ph/wh)
print(int(px+(pw-ww*s)/2+$wx*s), int(py+(ph-wh*s)/2+$wy*s))"
}

open -n "$build_dir/DropyInputFixture.app" --args --log "$fixture_log"
for i in {1..40}; do grep -q '"kind":"ready"' "$fixture_log" 2>/dev/null && break; sleep 0.25; done
A="$(grep '"kind":"ready"' "$fixture_log" | grep -oE '"A":[0-9]+' | cut -d: -f2)"
fixture_pid="$(lsappinfo info -only pid -app org.dropy.inputfixture | grep -oE '[0-9]+' | head -1)"
"$probe" send key:B; sleep 0.5

json='{"trigger":"shortcut","openBehavior":"direct","dismissBehavior":"manual","contentMode":"fit","sizePreset":"wide","selectedBundleIdentifier":"org.dropy.inputfixture","lastUsedBundleIdentifier":"org.dropy.inputfixture","interactivePreview":true}'
defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"

run_case() {
  local condition="$1" log="$logs/dropy-$1.log"
  DROPY_DEBUG_INPUT_EVENTS=1 DROPY_DEBUG_WINDOW_ID="$A" DROPY_DEBUG_QUIT_AFTER=45 "$dropy" --show > "$log" 2>&1 &
  dropy_pid=$!
  for i in {1..60}; do grep -q 'Dropy input: preview=' "$log" && break; sleep 0.25; done
  if ! grep -q 'Dropy input: preview=' "$log"; then
    record "$condition" all "-" "NOT RUN: interactive preview not ready ($(grep -oE 'state: [a-z.()A-Za-z]+' "$log" | tail -1))"
    kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""; return
  fi
  sleep 1
  preview="$(grep -oE 'preview=[0-9.,-]+' "$log" | tail -1 | cut -d= -f2)"
  local label="$(grep -oE 'support=.*' "$log" | tail -1 | cut -d= -f2-)"
  local elements="$("$probe" elements "$fixture_log" | grep '^A ')"
  window_size="$(print -r -- "$elements" | grep -oE 'size=[0-9]+x[0-9]+' | cut -d= -f2 | tr x ,)"
  local text=(${(s:,:)$(print -r -- "$elements" | grep -oE 'text=[0-9,]+' | cut -d= -f2)})
  local button=(${(s:,:)$(print -r -- "$elements" | grep -oE 'button=[0-9,]+' | cut -d= -f2)})
  local scroll=(${(s:,:)$(print -r -- "$elements" | grep -oE 'scroll=[0-9,]+' | cut -d= -f2)})
  local key_before="$("$probe" send "state:k$condition" >/dev/null; sleep 0.3; grep '"nonce":"k'$condition'"' "$fixture_log" | tail -1 | grep -oE '"B":\{[^}]*"main":(true|false)' | grep -oE '(true|false)$')"
  print -r -- "  $condition: preview=$preview window=$window_size label=\"$label\" B main=$key_before"

  local mark point
  mark="$(log_mark)"; point=($(preview_point "${button[1]}" "${button[2]}"))
  "$hid" click "${point[1]}" "${point[2]}"; sleep 1
  local presses="$(effects_since "$mark" press)"
  [[ "$presses" == "A=1 B=0" ]] && record "$condition" click PASS "$presses; $(grep -oE 'kind=pointerClick [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
    || record "$condition" click FAIL "$presses; $(grep -E 'kind=pointerClick' "$log" | tail -1 | cut -c 60-)"

  mark="$(log_mark)"
  "$hid" click "${point[1]}" "${point[2]}" cmd; sleep 0.5
  local modified="$(effects_since "$mark" press)"
  [[ "$modified" == "A=0 B=0" ]] && record "$condition" "modified click refused" PASS "$modified" \
    || record "$condition" "modified click refused" FAIL "$modified"

  mark="$(log_mark)"; point=($(preview_point "${text[1]}" "${text[2]}"))
  "$hid" click "${point[1]}" "${point[2]}"; sleep 0.6
  for key in 2 7 26; do "$hid" key "$key"; done   # d x 7
  sleep 1
  local typed="$(effects_since "$mark" text)"
  [[ "$typed" == A=[1-9]*" B=0" ]] && record "$condition" typing PASS "$typed; $(grep -oE 'kind=text [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
    || record "$condition" typing FAIL "$typed; $(grep -E 'kind=text' "$log" | tail -1 | cut -c 60-)"

  mark="$(log_mark)"; point=($(preview_point "${scroll[1]}" "${scroll[2]}"))
  "$hid" move "${point[1]}" "${point[2]}"
  print -r -- "  $condition scroll target=${point[1]},${point[2]} actual=$("$hid" pointer)"
  for i in {1..3}; do "$hid" scroll -120; sleep 0.2; done
  sleep 1
  local scrolled="$(effects_since "$mark" scroll)"
  [[ "$scrolled" == A=[1-9]*" B=0" ]] && record "$condition" scroll PASS "$scrolled; $(grep -oE 'kind=scroll [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
    || record "$condition" scroll FAIL "$scrolled; $(grep -E 'kind=scroll' "$log" | tail -1 | cut -c 60-)"

  local front="$("$hid" frontmost)"
  [[ "$front" == org.dropy.app ]] && record "$condition" "focus stays with Dropy" PASS "frontmost=$front" \
    || record "$condition" "focus stays with Dropy" FAIL "frontmost=$front"
  kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""
  "$probe" send reset; "$probe" send key:B; sleep 0.5
}

print "Interactive preview checks"
run_case visible
# Move A beyond every display, as parking does, without a Dropy placement.
home="$("$tool" frame "$fixture_pid" "$A")"
"$tool" move "$fixture_pid" "$A" 5000 3000; sleep 0.8
"$probe" send key:B; sleep 0.4
run_case offDisplay
h=(${=home}); "$tool" move "$fixture_pid" "$A" "${h[1]}" "${h[2]}"

# A real app: two TextEdit documents; the preview shows A while B is TextEdit's main window.
textedit_case() {
  pgrep -xq TextEdit && { record TextEdit all "-" "NOT RUN: TextEdit was already running"; return; }
  for n in A B; do for i in {1..60}; do print "Dropy interactive check $n line $i"; done > "$work/interactive-$n.txt"; done
  owned_textedit=true
  open -a TextEdit "$work/interactive-A.txt" "$work/interactive-B.txt" --args -ApplePersistenceIgnoreState YES; sleep 3
  osascript -e 'tell application "TextEdit"
    close (every window whose name is not "interactive-A.txt" and name is not "interactive-B.txt") saving no
    set bounds of window "interactive-A.txt" to {60, 120, 700, 700}
    set bounds of window "interactive-B.txt" to {760, 120, 1400, 640}
    set index of window "interactive-B.txt" to 1
  end tell' >/dev/null
  local pid="$(lsappinfo info -only pid -app com.apple.TextEdit | grep -oE '[0-9]+' | head -1)"
  local ids=(${=$("$probe" windows "$pid")}) wa wb
  (( ${#ids} == 2 )) || { record TextEdit all "-" "NOT RUN: expected two TextEdit windows, found ${#ids}"; return; }
  # A was placed on the left.
  local first=(${=$("$tool" server "${ids[1]}")})
  if (( first[1] < 400 )); then wa=${ids[1]}; wb=${ids[2]}; else wa=${ids[2]}; wb=${ids[1]}; fi
  local json='{"trigger":"shortcut","openBehavior":"direct","dismissBehavior":"manual","contentMode":"fit","sizePreset":"wide","selectedBundleIdentifier":"com.apple.TextEdit","lastUsedBundleIdentifier":"com.apple.TextEdit","interactivePreview":true}'
  defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
  local log="$logs/dropy-textedit.log"
  DROPY_DEBUG_WINDOW_ID="$wa" DROPY_DEBUG_QUIT_AFTER=30 "$dropy" --show > "$log" 2>&1 &
  dropy_pid=$!
  for i in {1..60}; do grep -q 'Dropy input: preview=' "$log" && break; sleep 0.25; done
  if ! grep -q 'Dropy input: preview=' "$log"; then
    record TextEdit all "-" "NOT RUN: interactive preview not ready"
  else
    sleep 1
    preview="$(grep -oE 'preview=[0-9.,-]+' "$log" | tail -1 | cut -d= -f2)"
    local sa=(${=$("$probe" textstate "$pid" "$wa")}) sb=(${=$("$probe" textstate "$pid" "$wb")})
    window_size="$(print -r -- "${sa[3]}" | cut -d= -f2 | tr x ,)"
    local target=(${(s:,:)${sa[4]#text=}})
    local point=($(preview_point "${target[1]}" "${target[2]}"))
    "$hid" click "${point[1]}" "${point[2]}"; sleep 0.8
    local ca=(${=$("$probe" textstate "$pid" "$wa")}) cb=(${=$("$probe" textstate "$pid" "$wb")})
    [[ "${ca[2]}" != "${sa[2]}" && "${cb[2]}" == "${sb[2]}" ]] && record TextEdit click PASS "caret A ${sa[2]}→${ca[2]}, B unchanged; $(grep -oE 'kind=pointerClick [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
      || record TextEdit click FAIL "caret A ${sa[2]}→${ca[2]} B ${sb[2]}→${cb[2]}; $(grep -E 'kind=pointerClick' "$log" | tail -1 | cut -c 60-)"
    for key in 2 7 26; do "$hid" key "$key"; done
    sleep 0.8
    local ta=(${=$("$probe" textstate "$pid" "$wa")}) tb=(${=$("$probe" textstate "$pid" "$wb")})
    [[ "${ta[1]}" == "$(( sa[1] + 3 ))" && "${tb[1]}" == "${sb[1]}" && "${ta[2]}" == "$(( ca[2] + 3 ))" ]] \
      && record TextEdit typing PASS "A +3 chars at the clicked caret, B unchanged; $(grep -oE 'kind=text [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
      || record TextEdit typing FAIL "A ${sa[1]}→${ta[1]} caret ${ca[2]}→${ta[2]}, B ${sb[1]}→${tb[1]}; $(grep -E 'kind=text' "$log" | tail -1 | cut -c 60-)"
    local front="$("$hid" frontmost)"
    [[ "$front" == org.dropy.app ]] && record TextEdit "focus stays with Dropy" PASS "frontmost=$front" || record TextEdit "focus stays with Dropy" FAIL "frontmost=$front"
  fi
  kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""
  osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true
  owned_textedit=false
}
# Router regressions (Tests/DeviceInputRouterCheck.swift): stale geometry, a real source
# resize, rapid source switching, a replaced text field and a hidden source; then the
# fixture quits and relaunches, and the old identity must be refused.
router_status=0
"$build_dir/DeviceInputRouterChecks" "$fixture_pid" "$A" "$(grep '"kind":"ready"' "$fixture_log" | grep -oE '"B":[0-9]+' | cut -d: -f2)" \
  > "$logs/router-regressions.txt" 2>&1 || router_status=$?
cat "$logs/router-regressions.txt"
old_identity=(${=$(grep '^old-identity ' "$logs/router-regressions.txt" | cut -d' ' -f2-)})
"$probe" send quit
for i in {1..40}; do kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
if (( ${#old_identity} == 3 )); then
  relaunch_log="$logs/fixture-relaunched.jsonl"
  open -n "$build_dir/DropyInputFixture.app" --args --log "$relaunch_log"
  for i in {1..40}; do grep -q '"kind":"ready"' "$relaunch_log" 2>/dev/null && break; sleep 0.25; done
  new_pid="$(grep '"kind":"ready"' "$relaunch_log" | grep -oE '"pid":[0-9]+' | cut -d: -f2)"
  "$build_dir/DeviceInputRouterChecks" relaunched "${old_identity[@]}" "$new_pid" >> "$logs/router-regressions.txt" 2>&1 \
    || router_status=$?
  tail -n +"$(( $(grep -n '^old-identity' "$logs/router-regressions.txt" | cut -d: -f1) + 1 ))" "$logs/router-regressions.txt"
  "$probe" send quit; sleep 1
else
  print -r -- "FAIL relaunch check not run: no old identity" >> "$logs/router-regressions.txt"
  router_status=1
fi
textedit_case

# The disposable Electron fixture (Chromium): A shown while B is its key window. Evidence
# verifies clicks on pressable elements (Accessibility press, with Chromium's tree switched
# on by Dropy) and window-targeted scrolling; typing has no verified route and must be
# refused without reaching either window.
electron_case() {
  "$repo_dir/Scripts/bench/build-electron-fixture.sh" >/dev/null
  local elog="$logs/electron.jsonl" commands="$work/electron-commands.txt"
  : > "$commands"
  open -n "$build_dir/DropyElectronFixture.app" --args --log "$elog" --commands "$commands" --profile "$work/electron-profile"
  for i in {1..60}; do grep -q '"kind":"ready"' "$elog" 2>/dev/null && break; sleep 0.25; done
  electron_pid="$(grep '"kind":"ready"' "$elog" | grep -oE '"pid":[0-9]+' | cut -d: -f2)"
  local ea="$(grep '"kind":"ready"' "$elog" | grep -oE '"A":[0-9]+' | cut -d: -f2)"
  [[ -n "$electron_pid" && -n "$ea" ]] || { record Electron all "-" "NOT RUN: fixture did not start"; return; }
  PROBE_COMMAND_FILE="$commands" "$probe" send key:B; sleep 0.6
  local json='{"trigger":"shortcut","openBehavior":"direct","dismissBehavior":"manual","contentMode":"fit","sizePreset":"wide","selectedBundleIdentifier":"org.dropy.electronfixture","lastUsedBundleIdentifier":"org.dropy.electronfixture","interactivePreview":true}'
  defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
  local log="$logs/dropy-electron.log"
  DROPY_DEBUG_WINDOW_ID="$ea" DROPY_DEBUG_QUIT_AFTER=40 "$dropy" --show > "$log" 2>&1 &
  dropy_pid=$!
  for i in {1..60}; do grep -q 'Dropy input: preview=' "$log" && break; sleep 0.25; done
  if ! grep -q 'Dropy input: preview=' "$log"; then
    record Electron all "-" "NOT RUN: interactive preview not ready"
  else
    sleep 2 # Chromium builds its Accessibility tree after Dropy switches it on
    preview="$(grep -oE 'preview=[0-9.,-]+' "$log" | tail -1 | cut -d= -f2)"
    print -r -- "  Electron: label=\"$(grep -oE 'support=.*' "$log" | tail -1 | cut -d= -f2-)\" $(grep -oE 'manualAccessibility pid=[0-9]+ result=-?[0-9]+' "$log" | tail -1)"
    local elements="$(PROBE_COMMAND_FILE="$commands" "$probe" elements "$elog" | grep '^A ')"
    window_size="$(print -r -- "$elements" | grep -oE 'size=[0-9]+x[0-9]+' | cut -d= -f2 | tr x ,)"
    local button=(${(s:,:)$(print -r -- "$elements" | grep -oE 'button=[0-9,]+' | cut -d= -f2)})
    local list=(${(s:,:)$(print -r -- "$elements" | grep -oE 'scroll=[0-9,]+' | cut -d= -f2)})
    local text=(${(s:,:)$(print -r -- "$elements" | grep -oE 'text=[0-9,]+' | cut -d= -f2)})
    local saved_log="$fixture_log" mark point
    fixture_log="$elog"
    if (( ${#button} == 2 && ${#list} == 2 && ${#text} == 2 )); then
      mark="$(log_mark)"; point=($(preview_point "${button[1]}" "${button[2]}"))
      "$hid" click "${point[1]}" "${point[2]}"; sleep 1
      local presses="$(effects_since "$mark" press)"
      [[ "$presses" == "A=1 B=0" ]] && record Electron click PASS "$presses; $(grep -oE 'kind=pointerClick [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
        || record Electron click FAIL "$presses; $(grep -E 'kind=pointerClick' "$log" | tail -1 | cut -c 60-)"
      mark="$(log_mark)"; point=($(preview_point "${list[1]}" "${list[2]}"))
      "$hid" move "${point[1]}" "${point[2]}"
      for i in {1..3}; do "$hid" scroll -120; sleep 0.2; done
      sleep 1
      local scrolled="$(effects_since "$mark" scroll)"
      [[ "$scrolled" == A=[1-9]*" B=0" ]] && record Electron scroll PASS "$scrolled; $(grep -oE 'kind=scroll [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
        || record Electron scroll FAIL "$scrolled; $(grep -E 'kind=scroll' "$log" | tail -1 | cut -c 60-)"
      print animate:A >> "$commands"; sleep 1
      mark="$(log_mark)"; point=($(preview_point "${button[1]}" "${button[2]}"))
      "$hid" click "${point[1]}" "${point[2]}"; sleep 1
      presses="$(effects_since "$mark" press)"
      [[ "$presses" == "A=1 B=0" ]] && record Electron "click while animating" PASS "$presses" \
        || record Electron "click while animating" FAIL "$presses; $(grep -E 'kind=pointerClick' "$log" | tail -1)"
      print animate:stop >> "$commands"; sleep 0.5
      mark="$(log_mark)"; point=($(preview_point "${text[1]}" "${text[2]}"))
      "$hid" click "${point[1]}" "${point[2]}"; sleep 0.6
      for key in 2 7 26; do "$hid" key "$key"; done
      sleep 1
      local typed="$(effects_since "$mark" text)"
      [[ "$typed" == "A=0 B=0" ]] && record Electron "typing refused" PASS "$typed; $(grep -oE 'kind=text [^ ]+ refused=[a-zA-Z]+' "$log" | tail -1)" \
        || record Electron "typing refused" FAIL "$typed"
    else
      record Electron all "-" "NOT RUN: fixture elements not exposed ($elements)"
    fi
    fixture_log="$saved_log"
    local front="$("$hid" frontmost)"
    [[ "$front" == org.dropy.app ]] && record Electron "focus stays with Dropy" PASS "frontmost=$front" \
      || record Electron "focus stays with Dropy" FAIL "frontmost=$front"
  fi
  kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""
  print quit >> "$commands"; sleep 1
  kill "$electron_pid" 2>/dev/null || true
  electron_pid=""
}
electron_pid=""
electron_case

{
  print -r -- "# Dropy interactive preview checks"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); real HID input on Dropy's preview of input-fixture window A while window B is the fixture's key window"
  print
  print -r -- "| Source | Input | Result | Observed |"
  print -r -- "|---|---|---|---|"
  for row in $rows; do print -r -- "$row"; done
  print
  print -r -- "## Router regressions"
  print
  print -r -- "Direct \`InputRouter\` sends against the input fixture (Tests/DeviceInputRouterCheck.swift)."
  print
  print -r -- '```'
  grep -E '^(PASS|FAIL|Native)' "$logs/router-regressions.txt"
  print -r -- '```'
} > "$report"
cat "$report"
print -r -- "Report saved to $report"

# A report containing failures or skipped checks is not a successful verification run.
(( router_status == 0 )) && ! grep -q '^FAIL' "$logs/router-regressions.txt" \
  || { print -u2 "A router regression failed; see $report"; exit 1; }
(( ${#rows} == 18 )) || { print -u2 "Expected 18 completed checks; see $report"; exit 1; }
for row in $rows; do
  [[ "$row" == *"| PASS |"* ]] || { print -u2 "A check failed or was skipped; see $report"; exit 1; }
done
