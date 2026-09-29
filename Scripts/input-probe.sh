#!/bin/zsh
# Exact-window input harness (M3, issue #8): runs Scripts/bench/InputProbe against the
# disposable input fixture and writes a dated report to .build/local/input-probe-<timestamp>.md
# with the raw fixture log and per-trial results beside it.
#
#   Scripts/input-probe.sh [route,...]     routes: pid pidWindow activate ax (default: all)
#   TARGET=electron Scripts/input-probe.sh [route,...]
#
# TARGET=appkit (default) drives Scripts/bench/InputFixture; TARGET=electron drives the
# disposable Electron fixture (Scripts/bench/ElectronFixture, pinned Electron release,
# throwaway profile) through the same trials, with Chromium's Accessibility tree enabled
# through AXManualAccessibility.
#
# The activate route moves the pointer and switches the frontmost app during each
# trial, and every route sends synthetic input, so leave the Mac alone while it runs
# (about five minutes). Needs a terminal with Accessibility permission, two desktops
# for the otherSpace condition, and no other Dropy check running.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$build_dir/input-probe-$stamp.md"
logs="${report%.md}-logs"
routes="${1:-pid,pidWindow,activate,ax}"
target="${TARGET:-appkit}"
case "$target" in
  appkit) bundle=org.dropy.inputfixture; fixture_app="$build_dir/DropyInputFixture.app" ;;
  electron) bundle=org.dropy.electronfixture; fixture_app="$build_dir/DropyElectronFixture.app"
    report="$build_dir/input-probe-electron-$stamp.md"; logs="${report%.md}-logs" ;;
  *) print -u2 "TARGET must be appkit or electron"; exit 2 ;;
esac
source "$repo_dir/Scripts/lib/device-session.zsh"

if lsappinfo info -only pid -app org.dropy.electronfixture 2>/dev/null | grep -q '[0-9]'; then
  print -u2 "Quit DropyElectronFixture first."; exit 1
fi
for app in Dropy DropyFixture DropyInputFixture; do
  if pgrep -xq "$app"; then
    print -u2 "Quit $app first; the probe needs the Mac to itself."
    exit 1
  fi
done

"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null
[[ "$target" == electron ]] && "$repo_dir/Scripts/bench/build-electron-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$build_dir/InputProbe" "$repo_dir/Scripts/bench/InputProbe/main.swift"
# Refuse shared recovery state before changing windows or preferences.
if [[ -e "$HOME/Library/Application Support/Dropy/placement-journal.json" ]]; then
  print -u2 "Recover pending Dropy placements before running the input probe."
  exit 1
fi
device_session_begin input-probe-$target || exit 1
mkdir -p "$logs"
profile_dir="$(mktemp -d)"
fixture_log="$logs/fixture.jsonl"
results="$logs/results.jsonl"
fixture_pid=""
sink_pid=""
"$build_dir/InputProbe" check-modifiers

cleanup() {
  "$build_dir/InputProbe" release 2>/dev/null || true
  [[ -n "${sink_pid:-}" ]] && { kill "$sink_pid" 2>/dev/null || true; sink_pid=""; }
  if [[ -n "$fixture_pid" ]]; then
    "$build_dir/InputProbe" send space:home 2>/dev/null || true
    "$build_dir/InputProbe" send quit 2>/dev/null || true
    for i in {1..30}; do kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
    kill "$fixture_pid" 2>/dev/null || true
    fixture_pid=""
  fi
  # The Electron fixture's throwaway profile and command channel.
  [[ -n "${profile_dir:-}" ]] && { rm -rf "$profile_dir"; profile_dir=""; }
  device_session_end
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
# zsh skips EXIT traps when errexit fires inside a function; ZERR covers that.
trap '(( ZSH_SUBSHELL == 0 )) && cleanup' ZERR

# Focus sink for "app inactive" trials: the placement fixture with its window minimized.
open -n "$build_dir/DropyFixture.app"
for i in {1..40}; do
  sink_pid="$(lsappinfo info -only pid -app org.dropy.fixture 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [[ -n "$sink_pid" ]] && break
  sleep 0.25
done
export PROBE_FOCUS_SINK_PID="$sink_pid"
sleep 1
# LaunchServices launch, so the fixture has a real launch date like any app Dropy targets.
if [[ "$target" == electron ]]; then
  export PROBE_COMMAND_FILE="$profile_dir/commands.txt" PROBE_ELECTRON=1
  : > "$PROBE_COMMAND_FILE"
  open -n "$fixture_app" --args --log "$fixture_log" --commands "$PROBE_COMMAND_FILE" --profile "$profile_dir/profile"
else
  open -n "$fixture_app" --args --log "$fixture_log"
fi
for i in {1..60}; do
  grep -q '"kind":"ready"' "$fixture_log" 2>/dev/null && break
  sleep 0.25
done
fixture_pid="$(grep '"kind":"ready"' "$fixture_log" 2>/dev/null | grep -oE '"pid":[0-9]+' | head -1 | cut -d: -f2 || true)"
[[ -n "$fixture_pid" ]] || { print -u2 "input fixture did not start"; exit 1; }
fixture_version="$(grep '"kind":"ready"' "$fixture_log" | grep -oE '"(electron|chrome)":"[^"]*"' | tr -d '"' | paste -sd ' ' - || true)"

caffeinate -d "$build_dir/InputProbe" matrix "$fixture_log" "$results" "$routes" | tee "$logs/probe.txt"

{
  print -r -- "# Dropy exact-window input probe"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); hardware: $(sysctl -n hw.model)"
  print -r -- "- Target: $bundle ${fixture_version:-} window A; decoy: window B of the same app"
  print -r -- "- Desktop session: $device_session_summary"
  print -r -- "- $(grep -E '^tally' "$logs/probe.txt")"
  print
  print -r -- "Cells: \`pass\` = effect in A only; **wrongWindow** = effect in B (fail); \`noEffect\` = nothing happened;"
  print -r -- "notes: front = frontmost app changed and was not restored, key = A's key state changed, desktop = active desktop changed, pointer = the pointer moved, cached = A reached through an element resolved earlier (verified by window ID); MODIFIER/BUTTON HELD = the trial left a modifier or mouse button down (released, trial failed)."
  print
  "$build_dir/InputProbe" report "$results"
} > "$report"
cat "$report"
print -r -- "Report saved to $report"
