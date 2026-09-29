#!/bin/zsh
# Real-app part of the exact-window input probe (M3, issue #8). Each app gets a target
# window A and a decoy window B; InputProbe judges typing and scrolling from each
# window's Accessibility state and undoes typed text.
#
#   Scripts/input-probe-apps.sh [textedit] [safari] [notion] [vscode]
#
# vscode: Visual Studio Code with a throwaway --user-data-dir and --extensions-dir,
# extensions disabled, two scratch text files in a temp directory, typing, clicks and
# scrolling, with Chromium's Accessibility tree switched on (AXManualAccessibility) and
# the matrix widened to covered and minimized. Refused while any VS Code is running, so
# a personal window can never be mistaken for a scratch one.
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
swiftc -O -swift-version 6 -o "$probe" "$repo_dir"/Scripts/bench/InputProbe/*.swift
"$repo_dir/Scripts/bench/build-fixture.sh" >/dev/null

"$probe" check-modifiers

# Ends only the scratch VS Code (matched by its temporary user-data directory).
stop_scratch_vscode() {
  pkill -TERM -f "$work/vscode-data" 2>/dev/null || true
  for i in {1..40}; do pgrep -qf "$work/vscode-data" || return 0; sleep 0.25; done
  pkill -KILL -f "$work/vscode-data" 2>/dev/null || true
  sleep 1
}

# Puts ~/.vscode/argv.json back byte for byte if the scratch VS Code changed it.
restore_vscode_argv() {
  [[ -f "$work/argv.json.sum" ]] || return 0
  shasum -s -c "$work/argv.json.sum" 2>/dev/null && return 0
  cp -p "$work/argv.json.backup" "$HOME/.vscode/argv.json"
  if shasum -s -c "$work/argv.json.sum"; then
    print -u2 "Restored ~/.vscode/argv.json, which the scratch VS Code had changed."
    print -r -- "| VSCode | - | ~/.vscode/argv.json was changed by the scratch instance and restored |" >> "$work/rows"
  else
    print -u2 "Could not restore ~/.vscode/argv.json; the backup is $work/argv.json.backup"; return 1
  fi
}

cleanup() {
  "$probe" release 2>/dev/null || true
  stop_scratch_vscode
  restore_vscode_argv || { print -u2 "Keeping $work for the argv.json backup."; device_session_end; return; }
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
  local name="$1" bundle="$2" actions="$3" routes="${4:-}" pid ids
  pid="${PROBE_APP_PID:-$(pid_of "$bundle")}"
  ids=(${=$("$probe" windows "$pid")})
  if (( ${#ids} < 2 )); then print -r -- "| $name | - | only ${#ids} window(s) reachable; NOT RUN |" >> "$work/rows"; return; fi
  "$probe" app "$pid" "${ids[1]}" "${ids[2]}" "$logs/$name.jsonl" "$actions" ${routes:+"$routes"} | tee "$logs/$name.txt"
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
    vscode)
      code_app="/Applications/Visual Studio Code.app"
      [[ -d "$code_app" ]] || { print -r -- "| VSCode | - | not installed; NOT RUN |" >> "$work/rows"; continue; }
      # A live process, not LaunchServices' record, which can outlive the process.
      if pgrep -qf "Visual Studio Code.app/Contents/MacOS/Code"; then
        print -u2 "Quit Visual Studio Code first; the probe uses only its own scratch instance."; exit 1
      fi
      code_version="$(defaults read "$code_app/Contents/Info" CFBundleShortVersionString)"
      mkdir -p "$work/vscode-data/User" "$work/vscode-extensions" "$work/vscode-files"
      # Nothing from a person's setup is read, and nothing is written outside $work.
      # No telemetry setting here: changing it makes VS Code rewrite the shared
      # ~/.vscode/argv.json ("enable-crash-reporter"), which it did on 2026-09-30.
      # The CLI flags below disable telemetry and crash reporting without that.
      print -r -- '{"update.mode":"none","workbench.startupEditor":"none","security.workspace.trust.enabled":false,"window.restoreWindows":"none","editor.accessibilitySupport":"on","window.confirmBeforeClose":"never","extensions.autoCheckUpdates":false,"extensions.autoUpdate":false,"workbench.enableExperiments":false,"git.enabled":false}' \
        > "$work/vscode-data/User/settings.json"
      for n in A B; do for i in {1..200}; do print "Dropy scratch $n line $i"; done > "$work/vscode-files/scratch-$n.txt"; done
      code_cli=("$code_app/Contents/Resources/app/bin/code" --user-data-dir "$work/vscode-data"
        --extensions-dir "$work/vscode-extensions" --disable-extensions --skip-welcome --skip-release-notes
        --disable-telemetry --disable-crash-reporter --disable-workspace-trust)
      # ~/.vscode/argv.json is shared with a person's own VS Code: keep an exact copy and
      # put it back afterwards (cleanup does too), and fail the run if it cannot be.
      # VS Code's built-in updater (Squirrel/ShipIt) shares state with a person's install
      # whatever the user-data directory; on 2026-09-30 a scratch instance downloaded
      # an update and installed it into /Applications on quit, although the scratch
      # settings say "update.mode": "none". Record the installed version and refuse
      # to continue if an update is pending, and report any change afterwards.
      code_version_before="$code_version"
      if pgrep -qf "ShipIt com.microsoft.VSCode" || ls -d "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt"/update.*(N) | grep -q .; then
        print -u2 "A VS Code update is staged or installing; the scratch instance would install it on quit. Run later."; exit 1
      fi
      argv_json="$HOME/.vscode/argv.json"
      [[ -f "$argv_json" ]] && { cp -p "$argv_json" "$work/argv.json.backup"; shasum "$argv_json" > "$work/argv.json.sum"; }
      "${code_cli[@]}" -n "$work/vscode-files/scratch-A.txt"; sleep 6
      "${code_cli[@]}" -n "$work/vscode-files/scratch-B.txt"; sleep 5
      scratch_pid="$(pgrep -f "Visual Studio Code.app/Contents/MacOS/Code --user-data-dir $work/vscode-data" | head -1 || true)"
      [[ -n "$scratch_pid" ]] || { print -r -- "| VSCode | - | scratch instance did not start; NOT RUN |" >> "$work/rows"; continue; }
      PROBE_APP_PID="$scratch_pid" PROBE_ELECTRON=1 PROBE_APP_CONDITIONS=visible,covered,parked,minimized \
        probe_app "VSCode-$code_version" com.microsoft.VSCode type,click,scroll ax,axValue,pidWindow,pid
      # Workbench: a pressable control (Explorer activity item) and editor scrolling.
      ids=(${=$("$probe" windows "$scratch_pid")})
      if (( ${#ids} >= 2 )); then
        for id in "${ids[1]}" "${ids[2]}"; do "$probe" workbench-discover "$scratch_pid" "$id" | tee -a "$logs/VSCode-workbench-discover.txt"; done
        "$probe" workbench "$scratch_pid" "${ids[1]}" "${ids[2]}" "$logs/VSCode-workbench.jsonl" | tee "$logs/VSCode-workbench.txt"
        "$probe" report "$logs/VSCode-workbench.jsonl" | sed "s/^| \\([a-zA-Z]*\\) |/| VSCode-workbench \\1 |/" >> "$work/tables"
      fi
      stop_scratch_vscode
      restore_vscode_argv || exit 1
      sleep 3
      code_version_after="$(defaults read "$code_app/Contents/Info" CFBundleShortVersionString 2>/dev/null || print unknown)"
      if [[ "$code_version_after" != "$code_version_before" ]] || pgrep -qf "ShipIt com.microsoft.VSCode"; then
        print -r -- "| VSCode | - | WARNING: VS Code's updater changed the installed app ($code_version_before → $code_version_after) |" >> "$work/rows"
        print -u2 "VS Code's updater changed the installed app during the probe."
      fi ;;
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
