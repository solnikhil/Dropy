# Isolation for third-party app device checks. Source it from a probe script.
#
# Lesson from 2026-09-30: a "scratch profile" (--user-data-dir) did not isolate VS Code.
# Its updater, keyed by bundle identifier, installed an update into /Applications when the
# scratch instance quit, and it rewrote a dotfile shared with the person's own copy. So a
# third-party app may be driven only as a disposable copy that shares nothing with an
# installed app, and every run proves afterwards that nothing shared changed.
#
#   isolation_check_disposable <app-bundle>
#       fails unless the bundle lives outside the Applications folders and its bundle
#       identifier differs from every app installed there.
#   isolation_fingerprint <manifest> <bundle-id> <app-name> [extra-path ...]
#       records the state of everything an app with that identity shares with a person's
#       install: caches, updater (ShipIt) state, preferences, saved state, application
#       support, containers, plus extra paths (e.g. a dotfile directory, an installed app).
#   isolation_verify <manifest>
#       recomputes the fingerprint; fails and prints the differences if anything changed.
#
# ISOLATION_HOME (default $HOME) and ISOLATION_APPLICATIONS (default the two Applications
# folders) exist so the local test can use a throwaway tree; real probes leave them unset.

isolation_home() { print -r -- "${ISOLATION_HOME:-$HOME}"; }
isolation_app_dirs() { print -r -- "${ISOLATION_APPLICATIONS:-/Applications $(isolation_home)/Applications}"; }
isolation_bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }

isolation_check_disposable() {
  local bundle="${1:A}" id dir app
  [[ -f "$bundle/Contents/Info.plist" ]] || { print -u2 "isolation: $1 is not an app bundle"; return 1; }
  id="$(isolation_bundle_id "$bundle")"
  [[ -n "$id" ]] || { print -u2 "isolation: $1 has no bundle identifier"; return 1; }
  for dir in ${=$(isolation_app_dirs)}; do
    [[ "$bundle" == "${dir:A}"/* ]] && { print -u2 "isolation: $1 is installed in $dir; use a disposable copy"; return 1; }
    for app in "$dir"/*.app(N) "$dir"/*/*.app(N); do
      if [[ "$(isolation_bundle_id "$app")" == "$id" ]]; then
        print -u2 "isolation: $id is also the identifier of $app; its updater, preferences and caches would be shared"
        return 1
      fi
    done
  done
}

# Paths an app with this identity shares with any other copy of it.
isolation_shared_paths() {
  local id="$1" name="$2" home="$(isolation_home)"
  print -r -l -- \
    "$home/Library/Caches/$id" "$home/Library/Caches/$id.ShipIt" "$home/Library/Caches/$name" \
    "$home/Library/Preferences/$id.plist" "$home/Library/Saved Application State/$id.savedState" \
    "$home/Library/Application Support/$name" "$home/Library/Application Support/$id" \
    "$home/Library/Containers/$id" "$home/Library/HTTPStorages/$id" "$home/Library/WebKit/$id" \
    "$home/Library/LaunchAgents/$id.ShipIt.plist"
}

# One line per path: "<path>\t<digest>", where the digest covers every file's relative
# path, size, mode and content (symlinks by target). "absent" for a missing path.
isolation_digest() {
  local target="$1"
  if [[ ! -e "$target" && ! -L "$target" ]]; then print -r -- "absent"; return; fi
  if [[ -f "$target" || -L "$target" ]]; then
    { stat -f '%z %p' "$target"; [[ -L "$target" ]] && readlink "$target" || shasum -a 256 < "$target"; } | shasum -a 256 | cut -d' ' -f1
    return
  fi
  ( cd "$target" && find . \( -type f -o -type l \) -print0 2>/dev/null | LC_ALL=C sort -z | while IFS= read -r -d '' file; do
      print -r -- "$file $(stat -f '%z %p' "$file") $([[ -L "$file" ]] && readlink "$file" || shasum -a 256 < "$file" | cut -d' ' -f1)"
    done ) | shasum -a 256 | cut -d' ' -f1
}

isolation_fingerprint() {
  local manifest="$1" id="$2" name="$3"; shift 3
  # Not "path": in zsh that name is tied to PATH.
  local entry
  : > "$manifest" || return 1
  for entry in ${(f)"$(isolation_shared_paths "$id" "$name")"} "$@"; do
    print -r -- "$entry"$'\t'"$(isolation_digest "$entry")" >> "$manifest"
  done
}

isolation_verify() {
  local manifest="$1" entry digest now changed=0
  [[ -s "$manifest" ]] || { print -u2 "isolation: no fingerprint at $manifest"; return 1; }
  while IFS=$'\t' read -r entry digest; do
    now="$(isolation_digest "$entry")"
    if [[ "$now" != "$digest" ]]; then
      print -u2 "isolation: CHANGED $entry ($digest → $now)"
      changed=1
    fi
  done < "$manifest"
  return $changed
}
