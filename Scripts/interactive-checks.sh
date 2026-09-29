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
if pgrep -f 'Scripts/(device-checks|input-probe|dismissal-checks|interactive-checks).*\.sh' | grep -vqx "$$"; then
  print -u2 "Another Dropy device check is running."; exit 1
fi

"$repo_dir/Scripts/build-local.sh" >/dev/null
"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$hid" "$repo_dir/Scripts/bench/HIDTool/main.swift"
swiftc -O -swift-version 6 -o "$probe" "$repo_dir/Scripts/bench/InputProbe/main.swift"
swiftc -O -swift-version 6 -o "$tool" "$repo_dir"/Scripts/bench/WindowTool/*.swift
mkdir -p "$logs"
work="$(mktemp -d)"
defaults export "$prefs_domain" "$work/prefs.plist" 2>/dev/null || true
pointer_start=(${=$("$hid" pointer)})
fixture_log="$logs/fixture.jsonl"
dropy_pid=""
rows=()

cleanup() {
  "$hid" release >/dev/null 2>&1 || true
  [[ -n "$dropy_pid" ]] && { kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""; }
  "$probe" send quit >/dev/null 2>&1 || true
  if [[ -f "$work/prefs.plist" ]]; then defaults import "$prefs_domain" "$work/prefs.plist" || true
  else defaults delete "$prefs_domain" "$prefs_key" 2>/dev/null || true; fi
  (( ${#pointer_start} == 2 )) && "$hid" move "${pointer_start[1]}" "${pointer_start[2]}" >/dev/null 2>&1 || true
  rm -rf "$work"
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
  DROPY_DEBUG_WINDOW_ID="$A" DROPY_DEBUG_QUIT_AFTER=45 "$dropy" --show > "$log" 2>&1 &
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

  mark="$(log_mark)"; point=($(preview_point "${text[1]}" "${text[2]}"))
  "$hid" click "${point[1]}" "${point[2]}"; sleep 0.6
  for key in 2 7 26; do "$hid" key "$key"; done   # d x 7
  sleep 1
  local typed="$(effects_since "$mark" text)"
  [[ "$typed" == A=[1-9]*" B=0" ]] && record "$condition" typing PASS "$typed; $(grep -oE 'kind=text [^ ]+ route=[a-zA-Z]+' "$log" | tail -1)" \
    || record "$condition" typing FAIL "$typed; $(grep -E 'kind=text' "$log" | tail -1 | cut -c 60-)"

  mark="$(log_mark)"; point=($(preview_point "${scroll[1]}" "${scroll[2]}"))
  "$hid" move "${point[1]}" "${point[2]}"
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
  open -a TextEdit "$work/interactive-A.txt" "$work/interactive-B.txt"; sleep 3
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
}
"$probe" send quit; sleep 1
textedit_case

{
  print -r -- "# Dropy interactive preview checks"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); real HID input on Dropy's preview of input-fixture window A while window B is the fixture's key window"
  print
  print -r -- "| Source | Input | Result | Observed |"
  print -r -- "|---|---|---|---|"
  for row in $rows; do print -r -- "$row"; done
} > "$report"
cat "$report"
print -r -- "Report saved to $report"
