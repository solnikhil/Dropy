#!/bin/zsh
# Makes a disposable copy of an app for third-party device checks
# (Scripts/lib/app-isolation.zsh): copies it outside the Applications folders, gives the
# main bundle and every nested bundle a new identifier prefix, and re-signs it ad hoc,
# so its updater state, caches, preferences and launchd jobs cannot be the installed
# app's. The source app is only read.
#
#   Scripts/bench/make-disposable-app.sh <source.app> <destination-dir> [identifier-prefix]
#
# Refuses when the destination is inside an Applications folder or when free space
# after the copy would be under DROPY_MIN_FREE_GB (default 5). Prints the copy's path.
set -euo pipefail
repo_dir="${0:A:h:h:h}"
source "$repo_dir/Scripts/lib/app-isolation.zsh"
[[ $# -ge 2 ]] || { print -u2 "usage: make-disposable-app.sh <source.app> <destination-dir> [identifier-prefix]"; exit 2; }
source_app="${1:A}" destination="${2:A}" prefix="${3:-org.dropy.disposable}"
[[ -f "$source_app/Contents/Info.plist" ]] || { print -u2 "$1 is not an app bundle"; exit 1; }
for dir in ${(f)"$(isolation_app_dirs)"}; do
  [[ "$destination" == "${dir:A}" || "$destination" == "${dir:A}"/* ]] && { print -u2 "Destination is inside $dir"; exit 1; }
done
mkdir -p "$destination"
need_kb="$(du -sk "$source_app" | cut -f1)"
free_kb="$(df -k "$destination" | awk 'NR == 2 { print $4 }')"
min_kb=$(( ${DROPY_MIN_FREE_GB:-5} * 1024 * 1024 ))
if (( free_kb - need_kb < min_kb )); then
  print -u2 "Not enough disk: the copy needs $(( need_kb / 1024 )) MB and would leave $(( (free_kb - need_kb) / 1024 )) MB (minimum $(( min_kb / 1024 )) MB)."
  exit 1
fi
copy="$destination/${source_app:t}"
[[ ! -e "$copy" ]] || { print -u2 "$copy already exists"; exit 1; }
ditto "$source_app" "$copy"
original="$(isolation_bundle_id "$copy")"
# Every bundle inside keeps its own suffix under the new prefix (helpers, frameworks).
for plist in "$copy/Contents/Info.plist" "$copy"/Contents/**/*.app/Contents/Info.plist(N) \
             "$copy"/Contents/**/*.framework/Resources/Info.plist(N); do
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  [[ -n "$id" ]] || continue
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $prefix.${id//[^A-Za-z0-9.-]/-}" "$plist"
done
codesign --force --deep --sign - "$copy" >/dev/null 2>&1 || { print -u2 "Could not re-sign $copy"; rm -rf "$copy"; exit 1; }
isolation_check_disposable "$copy" || { rm -rf "$copy"; exit 1; }
print -u2 "Disposable copy of $original: $(isolation_bundle_id "$copy")"
print -r -- "$copy"
