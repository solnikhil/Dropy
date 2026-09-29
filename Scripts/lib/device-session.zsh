# Desktop ownership for Dropy device checks. Source it from a device-check script and
# call `device_session_begin <name>` before touching windows, input or preferences.
#
# Device checks post synthetic input, move the pointer, switch desktops and change
# preferences, so only one may own the desktop at a time, and never while a person
# is using the Mac. The session:
#   - takes an exclusive kernel file lock before creating the backup directory and
#     recording the owner, PID and start time; stale backups are recovered under it;
#   - refuses to start while a person has used the keyboard, pointer or trackpad in the
#     last DROPY_REQUIRED_IDLE seconds (default 5), so a run never fights a person;
#   - sets `device_session_summary` (owner and input idle time) for the report;
#   - keeps a copy of Dropy's preferences in the lock. A run that dies without its
#     cleanup (zsh skips traps on some fatal errors, and kill -9 skips them all) leaves
#     that copy behind, and the next session restores it before doing anything else.
#     Without this, the next run would save and faithfully restore the damaged value.
# Each script still restores the pointer, preferences and windows it changed.
# The lock is released by `device_session_end`, which the caller's cleanup must call.

device_lock="${DROPY_DEVICE_LOCK:-$HOME/Library/Caches/org.dropy.device-session.lock}"
device_prefs_domain="${DROPY_PREFS_DOMAIN:-org.dropy.app}"
device_prefs_key="${DROPY_PREFS_KEY:-org.dropy.preferences.v1}"
device_session_owned=no
device_guard_fd=""

device_hid_idle() {
  # awk reads everything: exiting early would end ioreg with SIGPIPE, a failure under pipefail.
  ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !done { printf "%.1f", $NF / 1000000000; done = 1 }'
}

device_session_begin() {
  local name="$1" required="${DROPY_REQUIRED_IDLE:-5}" owner idle
  mkdir -p "${device_lock:h}" || return 1
  owner="$(cat "$device_lock/owner" 2>/dev/null || true)"
  local pid="${${owner#*pid=}%% *}"
  if [[ -n "${DROPY_DEVICE_SESSION:-}" && "$pid" == "$DROPY_DEVICE_SESSION" ]] && kill -0 "$pid" 2>/dev/null; then
    device_session_summary="nested in $owner"
    return 0
  fi
  # The guard inode is permanent. Kernel locking covers directory creation, owner
  # publication and crash recovery; an empty owner file is never treated as proof
  # that a concurrent initializer died. The kernel releases the guard on exit.
  zmodload zsh/system || return 1
  ( : >> "$device_lock.guard" ) || return 1
  if ! zsystem flock -t 0 -f device_guard_fd "$device_lock.guard"; then
    print -u2 "The desktop is owned by another device check (${owner:-initializing})."
    return 1
  fi
  if [[ -d "$device_lock" ]]; then
    owner="$(cat "$device_lock/owner" 2>/dev/null || true)"
    pid="${${owner#*pid=}%% *}"
    # A script from before kernel locking may still hold the legacy lock.
    if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
      zsystem flock -u "$device_guard_fd"; device_guard_fd=""
      print -u2 "The desktop is owned by another device check ($owner)."
      return 1
    fi
    print -u2 "Reclaiming a stale device-session lock ($owner)."
    if ! device_restore_preferences "$device_lock"; then
      zsystem flock -u "$device_guard_fd"; device_guard_fd=""
      return 1
    fi
    rm -rf "$device_lock" || return 1
  fi
  mkdir "$device_lock" || return 1
  device_session_owned=yes
  export DROPY_DEVICE_SESSION=$$
  print -r -- "script=$name pid=$$ started=$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$device_lock/owner"
  # `defaults export` also succeeds for a missing or empty domain; check the key.
  if defaults read "$device_prefs_domain" "$device_prefs_key" >/dev/null 2>&1; then
    if ! defaults export "$device_prefs_domain" "$device_lock/prefs.plist"; then
      print -u2 "Could not back up Dropy preferences; device checks refused."
      rm -rf "$device_lock"
      device_session_owned=no
      zsystem flock -u "$device_guard_fd"; device_guard_fd=""
      return 1
    fi
  else
    : > "$device_lock/prefs.absent"
  fi
  idle="$(device_hid_idle)"
  if [[ -n "$idle" ]] && (( idle < required )); then
    print -u2 "Keyboard or pointer activity occurred ${idle}s ago; device checks need an idle desktop."
    device_session_end
    return 1
  fi
  device_session_summary="owner=$name; input idle ${idle:-unknown}s at start"
  return 0
}

# Puts back the preferences saved by a session that did not finish.
device_restore_preferences() {
  local lock="$1"
  if [[ -f "$lock/prefs.plist" ]]; then
    defaults import "$device_prefs_domain" "$lock/prefs.plist" || return 1
    print -u2 "Restored saved Dropy preferences."
  elif [[ -f "$lock/prefs.absent" ]]; then
    defaults delete "$device_prefs_domain" "$device_prefs_key" 2>/dev/null || true
    print -u2 "Removed Dropy preferences written by the unfinished session (there were none before it)."
  fi
}

device_session_end() {
  [[ "$device_session_owned" == yes ]] || return 0
  device_restore_preferences "$device_lock" || return 1
  rm -rf "$device_lock" || return 1
  device_session_owned=no
  zsystem flock -u "$device_guard_fd"
  device_guard_fd=""
}
