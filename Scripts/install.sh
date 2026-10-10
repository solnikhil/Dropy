#!/bin/zsh
# Builds Dropy and installs it like an ordinary app, so it opens from Spotlight,
# Launchpad and Finder and can be added as a login item.
#   ./Scripts/install.sh            installs to /Applications (or ~/Applications if
#                                   /Applications is not writable)
#   ./Scripts/install.sh <folder>   installs to <folder>
# A running Dropy is quit first and the new copy is opened afterwards.
set -euo pipefail

repo_dir="${0:A:h:h}"
built="$("$repo_dir/Scripts/build-local.sh")"

if (( $# )); then
  destination="$1"
elif [[ -w /Applications ]]; then
  destination=/Applications
else
  destination="$HOME/Applications"
fi
mkdir -p "$destination"
target="$destination/Dropy.app"

if pgrep -qx Dropy; then
  osascript -e 'tell application id "org.dropy.app" to quit' >/dev/null 2>&1 || true
  for _ in {1..50}; do pgrep -qx Dropy || break; sleep 0.1; done
  pgrep -qx Dropy && { print -u2 "Dropy is still running; quit it and try again."; exit 1; }
fi

# Replace in one step so a half-copied app is never left in place.
staging="$destination/.Dropy.app.installing"
rm -rf "$staging"
ditto "$built" "$staging"
rm -rf "$target"
mv "$staging" "$target"
# Spotlight, Launchpad and the Dock pick up the new icon and name.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" >/dev/null 2>&1 || true

print "Installed $target"
print "macOS may ask for Screen Recording again: each build is signed ad hoc, so it counts as a new app."
open "$target"
