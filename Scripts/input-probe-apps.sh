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
work="$(mktemp -d)"
owned=()
mkdir -p "$logs"
swiftc -O -swift-version 6 -o "$probe" "$repo_dir/Scripts/bench/InputProbe/main.swift"

cleanup() {
  "$probe" release 2>/dev/null || true
  for app in $owned; do osascript -e "tell application \"$app\" to quit saving no" >/dev/null 2>&1 || true; done
  rm -rf "$work"
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

: > "$work/tables"; : > "$work/rows"
for app in $apps; do
  case "$app" in
    textedit)
      pgrep -xq TextEdit && { print -u2 "Quit TextEdit first"; exit 1; }
      owned+=(TextEdit)
      for n in A B; do for i in {1..200}; do print "Dropy input probe document $n line $i"; done > "$work/probe-$n.txt"; done
      open -a TextEdit "$work/probe-A.txt" "$work/probe-B.txt"; sleep 3
      osascript -e 'tell application "TextEdit"
        close (every window whose name is not "probe-A.txt" and name is not "probe-B.txt") saving no
        set bounds of window "probe-A.txt" to {60, 120, 700, 700}
        set bounds of window "probe-B.txt" to {760, 120, 1400, 640}
      end tell' >/dev/null
      probe_app TextEdit com.apple.TextEdit type,scroll
      osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true ;;
    safari)
      pgrep -xq Safari && { print -u2 "Quit Safari first"; exit 1; }
      owned+=(Safari)
      for n in A B; do
        { print "<!doctype html><title>Dropy input $n</title><textarea rows=6 cols=60></textarea>"
          for i in {1..300}; do print "<p>Dropy input probe page $n paragraph $i</p>"; done } > "$work/input-$n.html"
      done
      open -a Safari "$work/input-A.html"; sleep 3
      # A new document is a separate window; `open` would add a tab.
      osascript -e "tell application \"Safari\" to make new document with properties {URL:\"file://$work/input-B.html\"}" >/dev/null
      sleep 3
      osascript -e 'tell application "Safari"
        close (every window whose name is not "Dropy input A" and name is not "Dropy input B")
        set bounds of (first window whose name is "Dropy input A") to {60, 120, 700, 700}
        set bounds of (first window whose name is "Dropy input B") to {760, 120, 1400, 640}
      end tell' >/dev/null 2>&1 || true
      probe_app Safari com.apple.Safari type,scroll
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
