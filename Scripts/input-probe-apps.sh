#!/bin/zsh
# Real-app part of the exact-window input probe (M3, issue #8). Each app gets a target
# window A and a decoy window B; InputProbe judges typing and scrolling from each
# window's Accessibility state and undoes typed text.
#
#   Scripts/input-probe-apps.sh [textedit] [safari] [notion]
#
# TextEdit and Safari use only disposable temp documents and a local test page. Notion
# is scroll-only against its two frontmost windows (nothing is typed), and it must
# already have two windows open. Leave the Mac alone while it runs.
set -euo pipefail
repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
probe="$build_dir/InputProbe"
stamp="$(date +%Y%m%d-%H%M%S)"
logs="$build_dir/input-probe-apps-$stamp-logs"
report="$build_dir/input-probe-apps-$stamp.md"
apps=("${@:-textedit safari}")
apps=(${=apps})
for app in Dropy DropyFixture DropyInputFixture; do
  if pgrep -xq "$app"; then print -u2 "Quit $app before running the input probe."; exit 1; fi
done
source "${0:A:h}/lib/device-session.zsh"
device_session_begin input-probe-apps || exit 1
work="$(mktemp -d)"
owned=()
sink_pid=""
# Refuse shared recovery state before changing windows or preferences.
if [[ -e "$HOME/Library/Application Support/Dropy/placement-journal.json" ]]; then
  print -u2 "Recover pending Dropy placements before running the input probe."
  exit 1
fi
mkdir -p "$logs"
swiftc -O -swift-version 6 -o "$probe" "$repo_dir/Scripts/bench/InputProbe/main.swift"
"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null

"$probe" check-modifiers

cleanup() {
  "$probe" release 2>/dev/null || true
  [[ -n "${sink_pid:-}" ]] && { kill "$sink_pid" 2>/dev/null || true; sink_pid=""; }
  for app in $owned; do osascript -e "tell application \"$app\" to quit saving no" >/dev/null 2>&1 || true; done
  rm -rf "$work"
  device_session_end
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap '(( ZSH_SUBSHELL == 0 )) && cleanup' ZERR

pid_of() { lsappinfo info -only pid -app "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true; }

probe_app() {
  local name="$1" bundle="$2" actions="$3" pid ids
  pid="$(pid_of "$bundle")"
  ids=(${=$("$probe" windows "$pid")})
  if (( ${#ids} < 2 )); then print -r -- "| $name | - | only ${#ids} window(s) reachable; NOT RUN |" >> "$work/rows"; return; fi
  "$probe" app "$pid" "${ids[1]}" "${ids[2]}" "$logs/$name.jsonl" "$actions" | tee "$logs/$name.txt"
  "$probe" report "$logs/$name.jsonl" | sed "s/^| \\([a-zA-Z]*\\) |/| $name \\1 |/" >> "$work/tables"
  print >> "$work/tables"
}

# Focus sink for "app inactive" trials: the placement fixture with its window minimized.
open -n "$build_dir/DropyFixture.app"
for i in {1..40}; do
  sink_pid="$(lsappinfo info -only pid -app org.dropy.fixture 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [[ -n "$sink_pid" ]] && break
  sleep 0.25
done
export PROBE_FOCUS_SINK_PID="$sink_pid"
sleep 1
: > "$work/tables"; : > "$work/rows"
for app in $apps; do
  case "$app" in
    textedit)
      pgrep -xq TextEdit && { print -u2 "Quit TextEdit first"; exit 1; }
      owned+=(TextEdit)
      for n in A B; do for i in {1..200}; do print "Dropy input probe document $n line $i"; done > "$work/probe-$n.txt"; done
      open -a TextEdit "$work/probe-A.txt" "$work/probe-B.txt" --args -ApplePersistenceIgnoreState YES; sleep 3
      osascript -e 'tell application "TextEdit"
        close (every window whose name is not "probe-A.txt" and name is not "probe-B.txt") saving no
        set bounds of window "probe-A.txt" to {60, 120, 700, 700}
        set bounds of window "probe-B.txt" to {760, 120, 1400, 640}
      end tell' >/dev/null
      probe_app TextEdit com.apple.TextEdit type,click,scroll
      osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true ;;
    safari)
      pgrep -xq Safari && { print -u2 "Quit Safari first"; exit 1; }
      owned+=(Safari)
      for n in A B; do
        { print "<!doctype html><title>Dropy input $n</title><textarea rows=6 cols=60></textarea>"
          for i in {1..300}; do print "<p>Dropy input probe page $n paragraph $i</p>"; done } > "$work/input-$n.html"
      done
      open -a Safari "$work/input-A.html" --args -ApplePersistenceIgnoreState YES; sleep 3
      # A new document is a separate window; `open` would add a tab.
      osascript -e "tell application \"Safari\" to make new document with properties {URL:\"file://$work/input-B.html\"}" >/dev/null
      sleep 3
      osascript -e 'tell application "Safari"
        close (every window whose name is not "Dropy input A" and name is not "Dropy input B")
        set bounds of (first window whose name is "Dropy input A") to {60, 120, 700, 700}
        set bounds of (first window whose name is "Dropy input B") to {760, 120, 1400, 640}
      end tell' >/dev/null 2>&1 || true
      probe_app Safari com.apple.Safari type,click,scroll
      osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true ;;
    notion)
      probe_app Notion notion.id scroll ;;
  esac
done

{
  print -r -- "# Dropy exact-window input probe: real apps"
  print
  print -r -- "- Date: $(date '+%Y-%m-%d %H:%M %Z'); revision: $(git -C "$repo_dir" rev-parse --short HEAD)"
  print -r -- "- Target window A, decoy window B of the same app; judged from each window's AX text value and scroll position."
  print
  cat "$work/rows" "$work/tables"
} > "$report"
cat "$report"
print -r -- "Report saved to $report"
