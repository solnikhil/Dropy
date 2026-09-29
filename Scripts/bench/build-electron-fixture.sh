#!/bin/zsh
# Builds the disposable Electron device-check target into
# .build/local/DropyElectronFixture.app (bundle ID org.dropy.electronfixture).
#
# Uses the official Electron release zip at a pinned version and SHA-256. The zip is
# taken from Electron's download cache (~/Library/Caches/electron) or, only when
# DROPY_ELECTRON_DOWNLOAD=1, downloaded from the Electron GitHub release. The bundle is
# re-signed ad hoc; it is a local test target and is never distributed.
set -euo pipefail
repo_dir="${0:A:h:h:h}"
build_dir="$repo_dir/.build/local"
version="43.2.0"
sha256="ad4a0ae3c37ee05aa06c7e2ed0627608389790f0505a2b0d20319efbe33ffe28"
[[ "$(uname -m)" == arm64 ]] || { print -u2 "The pinned Electron build is darwin-arm64 only."; exit 1; }
zip_name="electron-v$version-darwin-arm64.zip"
zip=""
for candidate in "$HOME"/Library/Caches/electron/*/"$zip_name"(N) "$build_dir/cache/$zip_name"(N); do
  zip="$candidate"; break
done
if [[ -z "$zip" ]]; then
  if [[ "${DROPY_ELECTRON_DOWNLOAD:-0}" != 1 ]]; then
    print -u2 "Electron $version not in the local cache. Re-run with DROPY_ELECTRON_DOWNLOAD=1 to download it from GitHub."
    exit 1
  fi
  mkdir -p "$build_dir/cache"
  zip="$build_dir/cache/$zip_name"
  curl -fsSL -o "$zip.partial" "https://github.com/electron/electron/releases/download/v$version/$zip_name"
  mv "$zip.partial" "$zip"
fi
actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
[[ "$actual" == "$sha256" ]] || { print -u2 "Electron zip checksum mismatch: $actual"; exit 1; }

runtime="$build_dir/electron-$version"
if [[ ! -d "$runtime/Electron.app" ]]; then
  rm -rf "$runtime"; mkdir -p "$runtime"
  ditto -x -k "$zip" "$runtime"
fi

app="$build_dir/DropyElectronFixture.app"
rm -rf "$app"
ditto "$runtime/Electron.app" "$app"
resources="$app/Contents/Resources"
rm -f "$resources/default_app.asar"
ditto "$repo_dir/Scripts/bench/ElectronFixture/app" "$resources/app"
# Bench pages travel inside the bundle: a LaunchServices-launched app reading from
# ~/Documents triggers a privacy prompt and hangs the load until someone answers it.
mkdir -p "$resources/app/pages"
cp "$repo_dir"/Scripts/bench/*.html "$resources/app/pages/"
clang -O2 -bundle -undefined dynamic_lookup -framework CoreFoundation \
  -o "$resources/spaces.node" "$repo_dir/Scripts/bench/ElectronFixture/spaces.c"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier org.dropy.electronfixture" \
  -c "Set :CFBundleName DropyElectronFixture" -c "Set :CFBundleDisplayName DropyElectronFixture" "$plist"
codesign --force --deep --sign - "$app" >/dev/null 2>&1
print "$app"
