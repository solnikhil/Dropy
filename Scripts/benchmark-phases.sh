#!/bin/zsh
# Coordinated idle-Mac benchmark (M4 baseline): one session, the same two source windows
# throughout, and four phases measured back to back:
#
#   none     Dropy not running
#   closed   Dropy running, overlay closed (menu-bar item and notch trigger only)
#   idle     overlay open on a static page (nothing changes; adaptive rate should engage)
#   active   overlay open on a page animating at display rate
#
#   Scripts/benchmark-phases.sh [seconds-per-phase]      default 30
#
# Both sources are disposable Electron fixture windows (Scripts/bench/ElectronFixture,
# throwaway profiles) showing Scripts/bench/static.html and Scripts/bench/animation.html
# side by side, so no personal app, window or document is opened, moved or closed, and
# the idle/active difference is only the content. Dropy selects each window by exact ID.
# Each phase samples once per second after a 3 s warm-up: Dropy CPU, footprint and
# wakeups, WindowServer CPU and system GPU utilization (Scripts/bench/Sampler.swift);
# open phases add Dropy's own capture metrics (rate, presented frames, frame age).
# The report records the heaviest other processes before and after, because "idle"
# is only as idle as the rest of the Mac.
set -euo pipefail
repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
dropy="$build_dir/Dropy.app/Contents/MacOS/Dropy"
seconds="${1:-30}"
report="$build_dir/benchmark-phases-$(date +%Y%m%d-%H%M%S).md"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"

pgrep -xq Dropy && { print -u2 "Quit Dropy first."; exit 1; }
if lsappinfo info -only pid -app org.dropy.electronfixture 2>/dev/null | grep -q '[0-9]'; then
  print -u2 "Quit DropyElectronFixture first."; exit 1
fi
"$repo_dir/Scripts/build-local.sh" >/dev/null
"$repo_dir/Scripts/bench/build-electron-fixture.sh" >/dev/null
swiftc -O -swift-version 6 -o "$build_dir/Sampler" "$repo_dir/Scripts/bench/Sampler.swift"
"$build_dir/Sampler" self-check
swiftc -O -swift-version 6 -o "$build_dir/WindowTool" "$repo_dir"/Scripts/bench/WindowTool/*.swift

source "${0:A:h}/lib/device-session.zsh"
device_session_begin benchmark-phases || exit 1
work_dir="$(mktemp -d)"
defaults export "$prefs_domain" "$work_dir/prefs.plist" 2>/dev/null || true
dropy_pid=""
sources=()
cleaned_up=no
cleanup() {
  [[ "$cleaned_up" == no ]] || return 0
  cleaned_up=yes
  if [[ -n "$dropy_pid" ]]; then kill "$dropy_pid" 2>/dev/null || true; wait "$dropy_pid" 2>/dev/null || true; dropy_pid=""; fi
  for name in static animation; do print quit >> "$work_dir/$name-commands.txt" 2>/dev/null || true; done
  sleep 1
  for pid in $sources; do kill "$pid" 2>/dev/null || true; done
  if [[ -f "$work_dir/prefs.plist" ]]; then defaults import "$prefs_domain" "$work_dir/prefs.plist" || true
  else defaults delete "$prefs_domain" "$prefs_key" 2>/dev/null || true; fi
  mkdir -p "${report%.md}-logs"
  cp "$work_dir"/*.log(N) "$work_dir"/samples-*.txt(N) "${report%.md}-logs/" 2>/dev/null || true
  rm -rf "$work_dir"
  device_session_end
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap '(( ZSH_SUBSHELL == 0 )) && cleanup' ZERR

# Starts one fixture window showing a page; prints "<pid> <window>".
start_source() {
  local name="$1" x="$2"
  local log="$work_dir/$name.jsonl"
  : > "$work_dir/$name-commands.txt"
  open -n "$build_dir/DropyElectronFixture.app" --args --mode animation --page "$name.html" \
    --log "$log" --commands "$work_dir/$name-commands.txt" --profile "$work_dir/$name-profile"
  for i in {1..60}; do grep -q '"kind":"ready"' "$log" 2>/dev/null && break; sleep 0.25; done
  local pid="$(grep '"kind":"ready"' "$log" | grep -oE '"pid":[0-9]+' | cut -d: -f2)"
  local window="$(grep '"kind":"ready"' "$log" | grep -oE '"A":[0-9]+' | cut -d: -f2)"
  [[ -n "$pid" && -n "$window" ]] || { print -u2 "fixture $name did not start"; exit 1; }
  # Side by side below the overlay area; a failed move only changes the layout.
  "$build_dir/WindowTool" move "$pid" "$window" "$x" 450 >/dev/null 2>&1 || print -u2 "could not move fixture $name"
  print "$pid $window"
}

# awk reads the whole listing (head would end ps with SIGPIPE, a failure under pipefail).
top_processes() { ps -Ao pcpu=,comm= -r | awk 'NR <= 8 { n=$NF; sub(".*/", "", n); printf "%s %.0f%%; ", n, $1 }'; }

static=(${=$(start_source static 60)})
animation=(${=$(start_source animation 620)})
sources=("${static[1]}" "${animation[1]}")
windowserver="$(pgrep -x WindowServer)"
load_before="$(top_processes)"
sleep 3

set_prefs() {
  local json='{"trigger":"notchClick","openBehavior":"direct","dismissBehavior":"manual","contentMode":"fit","sizePreset":"medium","selectedBundleIdentifier":"org.dropy.electronfixture","lastUsedBundleIdentifier":"org.dropy.electronfixture"}'
  defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
}
set_prefs

typeset -A samples metrics
phase() {
  local name="$1" window="${2:-}"
  print -r -- "== $name"
  if [[ "$name" == none ]]; then
    samples[$name]="$("$build_dir/Sampler" "$seconds" "windowserver=$windowserver")"
    print -r -- "${samples[$name]}" > "$work_dir/samples-$name.txt"
    return
  fi
  local log="$work_dir/dropy-$name.log"
  if [[ -n "$window" ]]; then
    DROPY_DEBUG_WINDOW_ID="$window" DROPY_DEBUG_QUIT_AFTER=$(( seconds + 6 )) "$dropy" --show > "$log" 2>&1 &
  else
    DROPY_DEBUG_QUIT_AFTER=$(( seconds + 6 )) "$dropy" > "$log" 2>&1 &
  fi
  dropy_pid=$!
  sleep 3
  if [[ -n "$window" ]] && ! grep -q "capture started: window=$window" "$log"; then
    print -u2 "phase $name: capture of window $window did not start"
  fi
  samples[$name]="$("$build_dir/Sampler" "$seconds" "dropy=$dropy_pid" "windowserver=$windowserver")"
  print -r -- "${samples[$name]}" > "$work_dir/samples-$name.txt"
  wait "$dropy_pid" 2>/dev/null || true
  dropy_pid=""
  metrics[$name]="$(grep -oE 'Dropy (reveal|capture metrics): .*' "$log" || print 'no capture metrics')"
  sleep 2
}

phase none
phase closed
phase idle "${static[2]}"
phase active "${animation[2]}"
load_after="$(top_processes)"

field() { print -r -- "$1" | grep -oE "$2=[^ ]+" | awk 'NR == 1' | cut -d= -f2 || true; }

# One report row from a phase's sampler output and Dropy's capture metrics.
table_row() {
  local name="$1"
  local s="${samples[$name]}"
  local d="" w="" g="" m="" cpu="—" mem="—" wake="—" rate="—" shown="—" age="—"
  d="$(print -r -- "$s" | grep '^dropy:' || true)"
  w="$(print -r -- "$s" | grep '^windowserver:' || true)"
  g="$(print -r -- "$s" | grep '^gpu:' || true)"
  m="$(print -r -- "${metrics[$name]:-}" | grep 'Dropy capture metrics:' || true)"
  if [[ -n "$d" ]]; then
    cpu="$(field "$d" cpuMean) / $(field "$d" cpuP95)"; mem="$(field "$d" memMax)"
    wake="$(field "$d" idleWakeups) / $(field "$d" interruptWakeups)"
  fi
  if [[ -n "$m" ]]; then
    rate="$(field "$m" completeRate) ($(field "$m" unchanged) unchanged)"
    shown="$(field "$m" presented) / $(field "$m" notPresented)"
    age="$(print -r -- "$m" | grep -oE 'frameAge=\[[^]]*\]' | awk 'NR == 1' || true)"
  fi
  print -r -- "| $name | $cpu | $mem | $wake | $(field "$w" cpuMean) | $(field "$g" utilMean) / $(field "$g" utilP95) | $rate | $shown | ${age:-—} |"
}
{
  print -r -- "# Dropy coordinated benchmark: closed, idle and active"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); Dropy $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)); $(sysctl -n hw.model); displays: $(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution/ {print $2}' | paste -sd ';' -)"
  print -r -- "- Sources: Electron fixture $(grep -oE '"electron":"[^"]*"' "$work_dir/static.jsonl" | cut -d'"' -f4) windows, 520×380 pt, static.html and animation.html side by side; overlay medium, fit"
  print -r -- "- ${seconds}s per phase, sampled once per second after 3 s; desktop session: $device_session_summary"
  print -r -- "- Heaviest processes before: $load_before"
  print -r -- "- Heaviest processes after: $load_after"
  print
  print -r -- "| Phase | Dropy CPU mean / p95 | Dropy footprint | Dropy wakeups (idle / interrupt) | WindowServer CPU | GPU util mean / p95 | Capture rate | Presented / not | Frame age p50 / p95 / p99 |"
  print -r -- "|---|---|---|---|---|---|---|---|---|"
  for name in none closed idle active; do table_row "$name"; done
  print
  print -r -- "## Raw samples"
  for name in none closed idle active; do
    print; print -r -- "### $name"; print; print -r -- '```'; print -r -- "${samples[$name]}"; print -r -- "${metrics[$name]:-}"; print -r -- '```'
  done
} > "$report"
cat "$report"
print -r -- "Report saved to $report"
