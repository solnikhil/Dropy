#!/bin/zsh
# Checks Scripts/lib/app-isolation.zsh in a throwaway tree (no real app is launched or
# read): a disposable copy must not share an installed app's location or identifier,
# and a fingerprint must catch what happened on 2026-09-30 (an updater replacing the
# installed app, a shared dotfile rewritten, updater state appearing).
set -euo pipefail
repo_dir="${0:A:h:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export ISOLATION_HOME="$work/home" ISOLATION_APPLICATIONS="$work/Applications"
source "$repo_dir/Scripts/lib/app-isolation.zsh"
fail() { print -u2 "app-isolation check failed: $1"; exit 1; }

make_app() {  # path, bundle id, version
  mkdir -p "$1/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $2" -c "Add :CFBundleShortVersionString string $3" \
    "$1/Contents/Info.plist" >/dev/null
}
mkdir -p "$ISOLATION_HOME/.editor" "$ISOLATION_HOME/Library/Preferences" "$ISOLATION_APPLICATIONS"
installed="$ISOLATION_APPLICATIONS/Editor.app"
make_app "$installed" com.example.editor 1.136.1
print '{"enable-crash-reporter": true}' > "$ISOLATION_HOME/.editor/argv.json"
print 'person' > "$ISOLATION_HOME/Library/Preferences/com.example.editor.plist"

# Only a copy outside the Applications folders with its own identifier is disposable.
isolation_check_disposable "$installed" 2>/dev/null && fail "the installed app was accepted"
make_app "$work/copy/Editor.app" com.example.editor 1.136.1
isolation_check_disposable "$work/copy/Editor.app" 2>/dev/null && fail "a copy sharing the identifier was accepted"
make_app "$work/copy2/Editor.app" org.dropy.disposable.editor 1.136.1
isolation_check_disposable "$work/copy2/Editor.app" || fail "a renamed copy outside Applications was refused"

# A clean run verifies.
manifest="$work/manifest"
isolation_fingerprint "$manifest" com.example.editor Editor "$installed" "$ISOLATION_HOME/.editor"
isolation_verify "$manifest" || fail "an unchanged tree did not verify"

# The 2026-09-30 VS Code incident, one change at a time: each must be caught.
catches() {  # description, command that changes shared state, command that undoes it
  local what="$1" change="$2" undo="$3"
  eval "$change"
  isolation_verify "$manifest" 2>/dev/null && fail "not caught: $what"
  eval "$undo"
  isolation_verify "$manifest" || fail "undoing '$what' did not verify"
}
catches "updater replaced the installed app" \
  "/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.139.1' '$installed/Contents/Info.plist'" \
  "/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.136.1' '$installed/Contents/Info.plist'"
catches "shared dotfile rewritten" \
  "print '{\"enable-crash-reporter\": false}' > '$ISOLATION_HOME/.editor/argv.json'" \
  "print '{\"enable-crash-reporter\": true}' > '$ISOLATION_HOME/.editor/argv.json'"
catches "updater state appeared" \
  "mkdir -p '$ISOLATION_HOME/Library/Caches/com.example.editor.ShipIt'; print x > '$ISOLATION_HOME/Library/Caches/com.example.editor.ShipIt/ShipItState.plist'" \
  "rm -rf '$ISOLATION_HOME/Library/Caches/com.example.editor.ShipIt'"
catches "preferences written" \
  "print 'changed' > '$ISOLATION_HOME/Library/Preferences/com.example.editor.plist'" \
  "print 'person' > '$ISOLATION_HOME/Library/Preferences/com.example.editor.plist'"
catches "file mode changed" \
  "chmod 600 '$ISOLATION_HOME/.editor/argv.json'" "chmod 644 '$ISOLATION_HOME/.editor/argv.json'"
# make-disposable-app.sh: a renamed, re-signed copy of the installed app (and of its
# nested helper) passes the disposable check; the source is unchanged; a destination
# in Applications or without enough free space is refused.
mkdir -p "$installed/Contents/MacOS" "$installed/Contents/Frameworks/Editor Helper.app/Contents/MacOS"
cp /usr/bin/true "$installed/Contents/MacOS/Editor"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Editor" "$installed/Contents/Info.plist" >/dev/null
make_app "$installed/Contents/Frameworks/Editor Helper.app" com.example.editor.helper 1.136.1
before="$(isolation_digest "$installed")"
maker="$repo_dir/Scripts/bench/make-disposable-app.sh"
copy="$(DROPY_MIN_FREE_GB=0 "$maker" "$installed" "$work/disposable" 2>/dev/null)" || fail "the copy was not made"
[[ "$(isolation_bundle_id "$copy")" == org.dropy.disposable.com.example.editor ]] || fail "main identifier not renamed"
[[ "$(isolation_bundle_id "$copy/Contents/Frameworks/Editor Helper.app")" == org.dropy.disposable.com.example.editor.helper ]] \
  || fail "helper identifier not renamed"
codesign --verify --deep "$copy" 2>/dev/null || fail "the copy is not validly signed"
[[ "$(isolation_digest "$installed")" == "$before" ]] || fail "making a copy changed the source app"
DROPY_MIN_FREE_GB=0 "$maker" "$installed" "$ISOLATION_APPLICATIONS/Copies" >/dev/null 2>&1 && fail "a copy into Applications was made"
DROPY_MIN_FREE_GB=100000 "$maker" "$installed" "$work/full" >/dev/null 2>&1 && fail "a copy was made without enough free space"
[[ ! -e "$work/full/Editor.app" ]] || fail "a refused copy left files"

# The VS Code probe drives only a disposable copy: it never names the installed CLI.
grep -q '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' "$repo_dir/Scripts/input-probe-apps.sh" \
  && fail "input-probe-apps.sh still launches the installed VS Code"
print "App isolation checks passed"
