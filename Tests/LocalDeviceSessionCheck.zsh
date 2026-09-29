#!/bin/zsh
# Checks Scripts/lib/device-session.zsh without touching real state: a throwaway lock
# path and preferences domain, and child sessions killed with SIGKILL so no trap runs.
set -euo pipefail
repo_dir="${0:A:h:h}"
work="$(mktemp -d)"
export DROPY_DEVICE_LOCK="$work/lock" DROPY_PREFS_DOMAIN="org.dropy.devicesessioncheck.$$" DROPY_REQUIRED_IDLE=0 DROPY_MIN_BATTERY=0 DROPY_SKIP_PROMPT_CHECK=1
unset DROPY_DEVICE_SESSION
key=org.dropy.preferences.v1
trap 'defaults delete "$DROPY_PREFS_DOMAIN" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$DROPY_PREFS_DOMAIN.plist"; rm -rf "$work"' EXIT
source "$repo_dir/Scripts/lib/device-session.zsh"
fail() { print -u2 "device-session check failed: $1"; exit 1; }
crash() {
  zsh -c "source '$repo_dir/Scripts/lib/device-session.zsh'; device_session_begin crashy; defaults write '$DROPY_PREFS_DOMAIN' $key damaged; kill -9 \$\$" || true
}

# Low battery is refused before anything is touched; external power is accepted.
DROPY_POWER_REPORT="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	19%; discharging; 0:43 remaining present: true" DROPY_MIN_BATTERY=30 \
  zsh -c "source '$repo_dir/Scripts/lib/device-session.zsh'; device_session_begin lowpower" 2>/dev/null \
  && fail "a session started on low battery"
[[ ! -e "$DROPY_DEVICE_LOCK" ]] || fail "a refused low-battery session created the lock"
[[ "$(DROPY_POWER_REPORT="Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	19%; charging" device_power_state)" == ac ]] || fail "AC power not recognised"

# A second session is refused while the first is alive.
device_session_begin first
DROPY_DEVICE_SESSION="" zsh -c "source '$repo_dir/Scripts/lib/device-session.zsh'; device_session_begin second" 2>/dev/null \
  && fail "a second session started while the first held the lock"
device_session_end
[[ ! -e "$DROPY_DEVICE_LOCK" ]] || fail "lock not released"

# An initializer holding the kernel guard is protected even before owner publication.
zmodload zsh/system
( : >> "$device_lock.guard" )
zsystem flock -t 0 -f guard "$device_lock.guard"
mkdir "$device_lock"
DROPY_DEVICE_SESSION="" zsh -c "source '$repo_dir/Scripts/lib/device-session.zsh'; device_session_begin racing" 2>/dev/null \
  && fail "a racing initializer reclaimed a live empty lock"
[[ -d "$device_lock" ]] || fail "initializer lock removed"
rmdir "$device_lock"
zsystem flock -u "$guard"

# A killed session's preference change is undone by the next session.
defaults write "$DROPY_PREFS_DOMAIN" "$key" original
crash
[[ "$(defaults read "$DROPY_PREFS_DOMAIN" "$key")" == damaged ]] || fail "crash simulation did not change preferences"
device_session_begin next 2>/dev/null
[[ "$(defaults read "$DROPY_PREFS_DOMAIN" "$key")" == original ]] || fail "preferences not restored after a killed session"
device_session_end

# Preferences a killed session created are removed when there were none before it.
defaults delete "$DROPY_PREFS_DOMAIN" "$key"
crash
device_session_begin next 2>/dev/null
defaults read "$DROPY_PREFS_DOMAIN" "$key" >/dev/null 2>&1 && fail "preferences created by a killed session were kept"
device_session_end
print "Device session checks passed"
