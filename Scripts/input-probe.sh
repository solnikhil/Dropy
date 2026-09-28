#!/bin/zsh
# Exact-window input harness (M3, issue #8): runs Scripts/bench/InputProbe against the
# disposable input fixture and writes a dated report to .build/local/input-probe-<timestamp>.md
# with the raw fixture log and per-trial results beside it.
#
#   Scripts/input-probe.sh [route,...]     routes: pid pidWindow activate ax (default: all)
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

for app in Dropy DropyFixture DropyInputFixture; do
  if pgrep -xq "$app"; then
    print -u2 "Quit $app first; the probe needs the Mac to itself."
    exit 1
  fi
done
if pgrep -f 'Scripts/(device-checks|input-probe)\.sh' | grep -vqx "$$"; then
  print -u2 "Another Dropy device check is running."
  exit 1
fi

"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$build_dir/InputProbe" "$repo_dir/Scripts/bench/InputProbe/main.swift"
mkdir -p "$logs"
fixture_log="$logs/fixture.jsonl"
results="$logs/results.jsonl"
fixture_pid=""

cleanup() {
  "$build_dir/InputProbe" release 2>/dev/null || true
  [[ -n "$fixture_pid" ]] || return 0
  "$build_dir/InputProbe" send space:home 2>/dev/null || true
  "$build_dir/InputProbe" send quit 2>/dev/null || true
  for i in {1..30}; do kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
  kill "$fixture_pid" 2>/dev/null || true
  fixture_pid=""
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
# zsh skips EXIT traps when errexit fires inside a function; ZERR covers that.
trap '(( ZSH_SUBSHELL == 0 )) && cleanup' ZERR

# LaunchServices launch, so the fixture has a real launch date like any app Dropy targets.
open -n "$build_dir/DropyInputFixture.app" --args --log "$fixture_log"
for i in {1..40}; do
  fixture_pid="$(lsappinfo info -only pid -app org.dropy.inputfixture 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [[ -n "$fixture_pid" ]] && break
  sleep 0.25
done
[[ -n "$fixture_pid" ]] || { print -u2 "input fixture did not start"; exit 1; }

caffeinate -d "$build_dir/InputProbe" matrix "$fixture_log" "$results" "$routes" | tee "$logs/probe.txt"

{
  print -r -- "# Dropy exact-window input probe"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); hardware: $(sysctl -n hw.model)"
  print -r -- "- Target: Dropy input fixture, window A; decoy: window B of the same app"
  print -r -- "- $(grep -E '^tally' "$logs/probe.txt")"
  print
  print -r -- "Cells: \`pass\` = effect in A only; **wrongWindow** = effect in B (fail); \`noEffect\` = nothing happened;"
  print -r -- "notes: front = frontmost app changed and was not restored, key = A's key state changed, desktop = active desktop changed, cached = A reached through an element resolved earlier (verified by window ID)."
  print
  "$build_dir/InputProbe" report "$results"
} > "$report"
cat "$report"
print -r -- "Report saved to $report"
