#!/bin/zsh
# Text-semantics probe (M3): typing into prefilled fields, a selection, a multi-line
# textarea and a contenteditable region, plus button clicks, in window A of a web page
# while window B shows the same page. Judged from both pages' own state, read through
# Accessibility (Scripts/bench/text.html, Scripts/bench/InputProbe/PageProbe.swift).
#
#   TARGET=electron Scripts/text-probe.sh [route,...]   disposable Electron fixture (default)
#   TARGET=safari   Scripts/text-probe.sh [route,...]   Safari with two local copies of the page
#   routes: ax axValue axFocus pidWindow pid (default ax,axValue,pidWindow)
#
# Only local throwaway pages are opened. Safari must not be running (its saved windows
# are not restored: -ApplePersistenceIgnoreState). Safari windows cannot be moved to
# another desktop from outside the app, so for Safari the otherSpace condition switches
# the active desktop away (Control-arrow) after the focus state is set, verifies that
# the source's desktop and the active one differ, and switches back after each trial.
# PROBE_PAGE_CONDITIONS=otherSpace runs only that condition.
# Writes .build/local/text-probe-<target>-<timestamp>.md with raw results beside it.
set -euo pipefail
repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
probe="$build_dir/InputProbe"
target="${TARGET:-electron}"
routes="${1:-ax,axValue,pidWindow}"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$build_dir/text-probe-$target-$stamp.md"
logs="${report%.md}-logs"
[[ "$target" == electron || "$target" == safari ]] || { print -u2 "TARGET must be electron or safari"; exit 2; }

for app in Dropy DropyFixture DropyInputFixture; do
  pgrep -xq "$app" && { print -u2 "Quit $app first."; exit 1; }
done
if lsappinfo info -only pid -app org.dropy.electronfixture 2>/dev/null | grep -q '[0-9]'; then
  print -u2 "Quit DropyElectronFixture first."; exit 1
fi
[[ "$target" == safari ]] && pgrep -xq Safari && { print -u2 "Quit Safari first; the probe opens its own windows."; exit 1; }
[[ -e "$HOME/Library/Application Support/Dropy/placement-journal.json" ]] && { print -u2 "Recover pending Dropy placements first."; exit 1; }

source "$repo_dir/Scripts/lib/device-session.zsh"
device_session_begin "text-probe-$target" || exit 1
work="$(mktemp -d)"
sink_pid=""
target_pid=""
cleanup() {
  "$probe" release >/dev/null 2>&1 || true
  if [[ "$target" == electron && -f "$work/commands.txt" ]]; then
    print space:home >> "$work/commands.txt"; sleep 0.5; print quit >> "$work/commands.txt"; sleep 1
  fi
  [[ "$target" == safari && -n "$target_pid" ]] && { osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true; }
  [[ -n "$target_pid" ]] && { kill "$target_pid" 2>/dev/null || true; target_pid=""; }
  [[ -n "$sink_pid" ]] && { kill "$sink_pid" 2>/dev/null || true; sink_pid=""; }
  rm -rf "$work"
  device_session_end
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap '(( ZSH_SUBSHELL == 0 )) && cleanup' ZERR

"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null
[[ "$target" == electron ]] && "$repo_dir/Scripts/bench/build-electron-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$probe" "$repo_dir"/Scripts/bench/InputProbe/*.swift
swiftc -O -swift-version 6 -o "$build_dir/WindowTool" "$repo_dir"/Scripts/bench/WindowTool/*.swift
"$probe" check-modifiers
mkdir -p "$logs"

# Focus sink for "app inactive": the placement fixture with its window minimized.
open -n "$build_dir/DropyFixture.app"
for i in {1..40}; do
  sink_pid="$(lsappinfo info -only pid -app org.dropy.fixture 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [[ -n "$sink_pid" ]] && break; sleep 0.25
done
export PROBE_FOCUS_SINK_PID="$sink_pid"

if [[ "$target" == electron ]]; then
  : > "$work/commands.txt"
  export PROBE_COMMAND_FILE="$work/commands.txt" PROBE_ELECTRON=1
  open -n "$build_dir/DropyElectronFixture.app" --args --mode text --log "$logs/fixture.jsonl" \
    --commands "$work/commands.txt" --profile "$work/profile"
  for i in {1..60}; do grep -q '"kind":"ready"' "$logs/fixture.jsonl" 2>/dev/null && break; sleep 0.25; done
  ready="$(grep '"kind":"ready"' "$logs/fixture.jsonl")"
  target_pid="$(print -r -- "$ready" | grep -oE '"pid":[0-9]+' | cut -d: -f2)"
  A="$(print -r -- "$ready" | grep -oE '"A":[0-9]+' | cut -d: -f2)"
  B="$(print -r -- "$ready" | grep -oE '"B":[0-9]+' | cut -d: -f2)"
  version="Electron $(print -r -- "$ready" | grep -oE '"electron":"[^"]*"' | cut -d'"' -f4) (Chromium $(print -r -- "$ready" | grep -oE '"chrome":"[^"]*"' | cut -d'"' -f4))"
else
  for n in A B; do cp "$repo_dir/Scripts/bench/text.html" "$work/dropy-text-$n.html"; done
  open -a Safari "$work/dropy-text-A.html" --args -ApplePersistenceIgnoreState YES
  sleep 3
  osascript -e "tell application \"Safari\" to make new document with properties {URL:\"file://$work/dropy-text-B.html\"}" >/dev/null
  sleep 3
  # Close anything but the two probe pages, then place A left and B right.
  osascript <<APPLESCRIPT >/dev/null
tell application "Safari"
  repeat with w in (every window)
    set u to ""
    try
      set u to URL of current tab of w
    end try
    if u does not contain "dropy-text-" then close w
  end repeat
  repeat with w in (every window)
    if URL of current tab of w contains "dropy-text-A" then set bounds of w to {60, 120, 700, 640}
    if URL of current tab of w contains "dropy-text-B" then set bounds of w to {760, 120, 1400, 640}
  end repeat
end tell
APPLESCRIPT
  sleep 1
  target_pid="$(lsappinfo info -only pid -app com.apple.Safari | grep -oE '[0-9]+' | head -1)"
  ids=(${=$("$probe" windows "$target_pid")})
  (( ${#ids} == 2 )) || { print -u2 "expected two Safari windows, found ${#ids}"; exit 1; }
  first=(${=$("$build_dir/WindowTool" server "${ids[1]}")})
  if (( ${first[1]%.*} < 400 )); then A=${ids[1]}; B=${ids[2]}; else A=${ids[2]}; B=${ids[1]}; fi
  version="Safari $(mdls -raw -name kMDItemVersion /Applications/Safari.app)"
fi
[[ -n "$target_pid" && -n "$A" && -n "$B" ]] || { print -u2 "target did not start"; exit 1; }

desktop_start="$("$build_dir/WindowTool" spaces | cut -d' ' -f1)"
caffeinate -d "$probe" page "$target_pid" "$A" "$B" "$logs/results.jsonl" "$target" "$routes" | tee "$logs/probe.txt"

{
  print -r -- "# Dropy text-semantics probe: $target"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)); $(sysctl -n hw.model); target: $version, window A $A, decoy window B $B"
  print -r -- "- Desktop session: $device_session_summary; desktop at start $desktop_start, at end $("$build_dir/WindowTool" spaces | cut -d' ' -f1)"
  print -r -- "- $(grep -E '^tally' "$logs/probe.txt")"
  print
  print -r -- "Cases (Scripts/bench/text.html): middle = caret inside prefilled input, select = selection replaced, multi = caret inside line 2 of a textarea, edit = caret inside a contenteditable. \`pass\` = exact text and caret in A's field, an input event in A, A's other fields and all of B unchanged, no key-window, app, desktop or pointer change, nothing held. \`partialEffect(...)\` = A changed but not correctly; **wrongWindow** = B changed or received input. Undo is measured afterwards with the page's own undo."
  print
  "$probe" page-report "$logs/results.jsonl"
} > "$report"
cat "$report"
print -r -- "Report saved to $report"
