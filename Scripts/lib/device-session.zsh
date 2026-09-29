# Desktop ownership for Dropy device checks. Source it from a device-check script and
# call `device_session_begin <name>` before touching windows, input or preferences.
#
# Device checks post synthetic input, move the pointer, switch desktops and change
# preferences, so only one may own the desktop at a time, and never while a person
# is using the Mac. The session:
#   - takes an exclusive lock (a directory, created atomically), recording the owner
#     script, PID and start time; a lock whose owner has exited is reclaimed;
#   - refuses to start while a person has used the keyboard, pointer or trackpad in the
#     last DROPY_REQUIRED_IDLE seconds (default 5), so a run never fights a person;
#   - sets `device_session_summary` (owner and input idle time) for the report.
# Each script still restores the pointer, preferences and windows it changed.
# The lock is released by `device_session_end`, which the caller's cleanup must call.

device_lock="${DROPY_DEVICE_LOCK:-$HOME/Library/Caches/org.dropy.device-session.lock}"
device_session_owned=no

device_hid_idle() {
  ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { printf "%.1f", $NF / 1000000000; exit }'
}

device_session_begin() {
  local name="$1" required="${DROPY_REQUIRED_IDLE:-5}" owner idle
  mkdir -p "${device_lock:h}"
  if ! mkdir "$device_lock" 2>/dev/null; then
    owner="$(cat "$device_lock/owner" 2>/dev/null || true)"
    local pid="${${owner#*pid=}%% *}"
    # A check started by the session owner (device-checks.sh runs benchmark.sh) shares it.
    if [[ -n "${DROPY_DEVICE_SESSION:-}" && "$pid" == "$DROPY_DEVICE_SESSION" ]]; then
      device_session_summary="nested in $owner"
      return 0
    fi
    if [[ -n "$pid" && "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
      print -u2 "The desktop is owned by another device check ($owner). Wait for it to finish."
      return 1
    fi
    print -u2 "Reclaiming a stale device-session lock ($owner)."
    rm -rf "$device_lock"
    mkdir "$device_lock" || { print -u2 "Could not take the device-session lock."; return 1; }
  fi
  device_session_owned=yes
  export DROPY_DEVICE_SESSION=$$
  print -r -- "script=$name pid=$$ started=$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$device_lock/owner"
  idle="$(device_hid_idle)"
  if [[ -n "$idle" ]] && (( idle < required )); then
    print -u2 "Someone used the keyboard or pointer ${idle}s ago; device checks need the Mac to themselves."
    device_session_end
    return 1
  fi
  device_session_summary="owner=$name; input idle ${idle:-unknown}s at start"
  return 0
}

device_session_end() {
  [[ "$device_session_owned" == yes ]] || return 0
  rm -rf "$device_lock"
  device_session_owned=no
}
