#!/bin/zsh
# Repeatable capture benchmark. For each workload it measures the system without
# Dropy, then with Dropy previewing the workload window, and reports Dropy's own
# capture metrics next to CPU, memory, wakeups, WindowServer and GPU samples.
#
#   Scripts/benchmark.sh [seconds-per-phase] [workload ...]
#   workloads: static scroll animation (default: all three)
#
# Run it from a terminal that has Screen Recording permission, on an otherwise idle
# Mac with the display awake. TextEdit and Safari must not be running: the script
# opens its own windows and quits those apps afterwards. Automation permission for
# TextEdit and Safari is used to position the windows.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
dropy="$build_dir/Dropy.app/Contents/MacOS/Dropy"
seconds="${1:-20}"
shift $(( $# > 0 ? 1 : 0 ))
workloads=("${@:-static scroll animation}")
workloads=(${=workloads})
work_dir="$(mktemp -d)"
report="$build_dir/benchmark-$(date +%Y%m%d-%H%M%S).md"
prefs_domain="org.dropy.app"
prefs_key="org.dropy.preferences.v1"

for app in TextEdit Safari Dropy; do
  if pgrep -xq "$app"; then
    print -u2 "Quit $app first; the benchmark opens and closes its own $app windows."
    exit 1
  fi
done

"$repo_dir/Scripts/build-local.sh" >/dev/null
swiftc -O -swift-version 6 -o "$build_dir/Sampler" "$repo_dir/Scripts/bench/Sampler.swift"

defaults export "$prefs_domain" "$work_dir/prefs.plist" 2>/dev/null || true
dropy_pid=""
cleanup() {
  if [[ -n "$dropy_pid" ]]; then
    kill "$dropy_pid" 2>/dev/null || true
    wait "$dropy_pid" 2>/dev/null || true
  fi
  for app in TextEdit Safari; do
    pgrep -xq "$app" && osascript -e "tell application \"$app\" to quit saving no" >/dev/null 2>&1 || true
  done
  if [[ -f "$work_dir/prefs.plist" ]]; then
    defaults import "$prefs_domain" "$work_dir/prefs.plist"
  else
    defaults delete "$prefs_domain" "$prefs_key" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

set_direct_open() {
  local json="{\"trigger\":\"notchClick\",\"openBehavior\":\"direct\",\"dismissBehavior\":\"manual\",\"contentMode\":\"fit\",\"sizePreset\":\"medium\",\"selectedBundleIdentifier\":\"$1\",\"lastUsedBundleIdentifier\":\"$1\"}"
  defaults write "$prefs_domain" "$prefs_key" -data "$(print -rn -- "$json" | xxd -p | tr -d '\n')"
}

# Opens the workload window below the overlay area, closes any restored windows so
# direct-open can only pick this one, and prints the target bundle identifier.
prepare() {
  local app window
  case "$1" in
    static)
      app=TextEdit
      for i in {1..60}; do print "Dropy benchmark static document, line $i"; done > "$work_dir/static.txt"
      open -a TextEdit "$work_dir/static.txt"; window="static.txt" ;;
    scroll)
      app=Safari; open -a Safari "$repo_dir/Scripts/bench/scroll.html"; window="Dropy bench scroll" ;;
    animation)
      app=Safari; open -a Safari "$repo_dir/Scripts/bench/animation.html"; window="Dropy bench animation" ;;
    *) print -u2 "unknown workload $1"; exit 2 ;;
  esac
  for i in {1..40}; do
    osascript -e "tell application \"$app\" to exists (first window whose name is \"$window\")" 2>/dev/null \
      | grep -q true && break
    sleep 0.25
  done
  osascript -e "with timeout of 10 seconds
tell application \"$app\"
  close (every window whose name is not \"$window\")
  set bounds of (first window whose name is \"$window\") to {80, 360, 1080, 960}
end tell
end timeout" >/dev/null
  [[ $app == TextEdit ]] && print com.apple.TextEdit || print com.apple.Safari
}

finish_app() {
  osascript -e "tell application \"$1\" to quit saving no" >/dev/null 2>&1 || true
  for i in {1..40}; do pgrep -xq "$1" || break; sleep 0.25; done
}

{
  print -r -- "# Dropy capture benchmark"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z')"
  print -r -- "- Dropy: $(git -C "$repo_dir" rev-parse --short HEAD)$(git -C "$repo_dir" diff --quiet || print ' (uncommitted changes)')"
  print -r -- "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); hardware: $(sysctl -n hw.model)"
  print -r -- "- Displays: $(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution/ {print $2}' | paste -sd ';' -)"
  print -r -- "- TextEdit $(mdls -raw -name kMDItemVersion /System/Applications/TextEdit.app); Safari $(mdls -raw -name kMDItemVersion /Applications/Safari.app)"
  print -r -- "- Phase length: ${seconds}s each, sampled once per second after a 3s warm-up"
  print
} > "$report"

for workload in $workloads; do
  print -r -- "== $workload"
  bundle="$(prepare "$workload")"
  app_name=$([[ $bundle == com.apple.TextEdit ]] && print TextEdit || print Safari)
  sleep 3
  windowserver=$(pgrep -x WindowServer)
  baseline="$("$build_dir/Sampler" "$seconds" "windowserver=$windowserver")"

  set_direct_open "$bundle"
  DROPY_DEBUG_QUIT_AFTER=$(( seconds + 5 )) "$dropy" --show > "$work_dir/$workload.log" 2>&1 &
  dropy_pid=$!
  sleep 3
  with_dropy="$("$build_dir/Sampler" "$seconds" "dropy=$dropy_pid" "windowserver=$windowserver")"
  wait "$dropy_pid" || true
  dropy_pid=""
  finish_app "$app_name"

  {
    print -r -- "## $workload ($app_name)"
    print
    print -r -- '```'
    print -r -- "without Dropy"
    print -r -- "$baseline"
    print
    print -r -- "with Dropy"
    print -r -- "$with_dropy"
    grep -oE "Dropy (reveal|capture metrics|state: failed).*" "$work_dir/$workload.log" || print "no Dropy metrics logged"
    print -r -- '```'
    print
  } >> "$report"
done

cat "$report"
print; print -r -- "Report saved to $report"
