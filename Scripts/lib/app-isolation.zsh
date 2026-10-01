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
# ISOLATION_HOME (default $HOME) and ISOLATION_APPLICATIONS (default the user and system Applications
# folders) exist so the local test can use a throwaway tree; real probes leave them unset.

isolation_home() { print -r -- "${ISOLATION_HOME:-$HOME}"; }
isolation_app_dirs() {
  if [[ -n "${ISOLATION_APPLICATIONS:-}" ]]; then print -r -l -- ${(f)ISOLATION_APPLICATIONS}
  else print -r -l -- /Applications "$(isolation_home)/Applications" /System/Applications; fi
}
isolation_files="${${(%):-%x}:A:h}/isolation-files.py"
isolation_bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }

isolation_check_disposable() {
  local bundle="${1:A}" id dir app
  [[ -f "$bundle/Contents/Info.plist" ]] || { print -u2 "isolation: $1 is not an app bundle"; return 1; }
  id="$(isolation_bundle_id "$bundle")" || return 1
  [[ -n "$id" ]] || { print -u2 "isolation: $1 has no bundle identifier"; return 1; }
  local candidates installed candidate_id candidate_source installed_id installed_source
  candidates="$(python3 "$isolation_files" identifiers "$bundle")" || return 1
  for dir in ${(f)"$(isolation_app_dirs)"}; do
    [[ "$bundle" == "${dir:A}" || "$bundle" == "${dir:A}"/* ]] && {
      print -u2 "isolation: $1 is installed in $dir; use a disposable copy"; return 1
    }
    installed="$(python3 "$isolation_files" identifiers "$dir")" || return 1
    while IFS=$'\t' read -r candidate_id candidate_source; do
      [[ -n "$candidate_id" ]] || continue
      while IFS=$'\t' read -r installed_id installed_source; do
        if [[ "$candidate_id" == "$installed_id" ]]; then
          print -u2 "isolation: $candidate_id is shared with $installed_source"
          return 1
        fi
      done <<< "$installed"
    done <<< "$candidates"
  done
}

# Paths an app with this identity shares with any other copy of it.
isolation_shared_paths() {
  local id="$1" name="$2" task_home="$(isolation_home)"
  print -r -l -- \
    "$task_home/Library/Caches/$id" "$task_home/Library/Caches/$id.ShipIt" "$task_home/Library/Caches/$name" \
    "$task_home/Library/Preferences/$id.plist" "$task_home/Library/Saved Application State/$id.savedState" \
    "$task_home/Library/Application Support/$name" "$task_home/Library/Application Support/$id" \
    "$task_home/Library/Containers/$id" "$task_home/Library/HTTPStorages/$id" "$task_home/Library/WebKit/$id" \
    "$task_home/Library/LaunchAgents/$id.ShipIt.plist" \
    "$task_home/Library/Application Scripts/$id" "$task_home/Library/Group Containers/$id" \
    "$task_home/Library/Group Containers/group.$id" \
    "${ISOLATION_SYSTEM_LIBRARY:-/Library}/LaunchDaemons/$id.plist" \
    "${ISOLATION_SYSTEM_LIBRARY:-/Library}/PrivilegedHelperTools/$id"
  local matching
  for matching in "$task_home/Library/Preferences/ByHost/$id".*(N) \
                  "$task_home/Library/Group Containers/"*"$id"*(N); do
    print -r -- "$matching"
  done
  # Observe metadata under shared namespaces, including unknown helper/group names.
  # Unrelated container contents are never read; unreadable metadata refuses a run.
  print -r -l -- "metadata:$task_home/Library/Group Containers" \
    "metadata:$task_home/Library/Application Scripts" "metadata:$task_home/Library/Preferences/ByHost" \
    "metadata:${ISOLATION_SYSTEM_LIBRARY:-/Library}/LaunchDaemons" \
    "metadata:${ISOLATION_SYSTEM_LIBRARY:-/Library}/PrivilegedHelperTools"
}

# One line per path: "<path>\t<digest>", where the digest covers every file's relative
# path, size, mode and content (symlinks by target). "absent" for a missing path.
isolation_digest() {
  if [[ "$1" == metadata:* ]]; then
    python3 "$isolation_files" metadata "${1#metadata:}"
  else
    python3 "$isolation_files" digest "$1"
  fi
}

isolation_fingerprint() {
  local manifest="$1" id="$2" name="$3"; shift 3
  # Not "path": in zsh that name is tied to PATH.
  local entry digest
  : > "$manifest" || return 1
  for entry in ${(f)"$(isolation_shared_paths "$id" "$name")"} "$@"; do
    digest="$(isolation_digest "$entry")" || { rm -f "$manifest"; return 1; }
    print -r -- "$entry"$'\t'"$digest" >> "$manifest"
  done
}

isolation_verify() {
  local manifest="$1" entry digest now changed=0
  [[ -s "$manifest" ]] || { print -u2 "isolation: no fingerprint at $manifest"; return 1; }
  while IFS=$'\t' read -r entry digest; do
    now="$(isolation_digest "$entry")" || return 1
    if [[ "$now" != "$digest" ]]; then
      print -u2 "isolation: CHANGED $entry ($digest → $now)"
      changed=1
    fi
  done < "$manifest"
  return $changed
}
