#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="${DROPY_BUILD_DIR:-$repo_dir/.build/local}"
configuration="${DROPY_BUILD_CONFIGURATION:-debug}"
case "$configuration" in
  debug) optimization=() ;;
  release) optimization=(-O) ;;
  *) print -u2 "DROPY_BUILD_CONFIGURATION must be debug or release"; exit 2 ;;
esac
sparkle_dir="$("$repo_dir/Scripts/fetch-sparkle.sh")"
app_dir="$build_dir/Dropy.app"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks"

swiftc -swift-version 6 $optimization -parse-as-library -emit-library -emit-module \
  -module-name DropyCore \
  -Xlinker -install_name -Xlinker '@rpath/libDropyCore.dylib' \
  -o "$build_dir/libDropyCore.dylib" \
  "$repo_dir"/Sources/DropyCore/*.swift

# The Stage's Objective-C shim (CoreGraphics' private virtual-display classes).
clang -fobjc-arc -fmodules -O2 -c "$repo_dir/Sources/DropyStageShim/DropyStageShim.m" \
  -I "$repo_dir/Sources/DropyStageShim/include" -o "$build_dir/DropyStageShim.o"

swiftc -swift-version 6 $optimization -I "$build_dir" -L "$build_dir" -lDropyCore \
  -F "$sparkle_dir" -framework Sparkle \
  -I "$repo_dir/Sources/DropyStageShim/include" "$build_dir/DropyStageShim.o" -framework CoreGraphics \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$app_dir/Contents/MacOS/Dropy" \
  "$repo_dir"/Sources/Dropy/*.swift

cp "$build_dir/libDropyCore.dylib" "$app_dir/Contents/Frameworks/"
ditto "$sparkle_dir/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
# A release build stamps its explicit version before the bundle is signed.
if [[ -n "${DROPY_RELEASE_VERSION:-}" || -n "${DROPY_RELEASE_BUILD:-}" ]]; then
  python3 - "$app_dir/Contents/Info.plist" <<'PYINFO'
import os, plistlib, re, sys
version = os.environ.get("DROPY_RELEASE_VERSION", "")
build = os.environ.get("DROPY_RELEASE_BUILD", "")
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    raise SystemExit("DROPY_RELEASE_VERSION must be a stable semantic version, e.g. 0.1.1")
if not re.fullmatch(r"[1-9][0-9]*", build) or int(build) > 2**63-1:
    raise SystemExit("DROPY_RELEASE_BUILD must be a positive build number")
with open(sys.argv[1], "rb") as handle: info = plistlib.load(handle)
info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
with open(sys.argv[1], "wb") as handle: plistlib.dump(info, handle, sort_keys=False)
PYINFO
fi
mkdir -p "$app_dir/Contents/Resources"
# Generate from the current brand artwork on every build; never ship a stale icon.
swift "$repo_dir/Scripts/make-icon.swift" --output "$app_dir/Contents/Resources/AppIcon.icns" >/dev/null
# Sign with a real identity when one exists: macOS ties Screen Recording and
# Accessibility to the designated requirement. An ad-hoc signature's requirement is
# the build's hash, so every rebuild was a new app and lost both permissions while
# System Settings still showed Dropy switched on. A certificate-based requirement
# (bundle ID plus certificate) stays the same across builds.
# DROPY_SIGN_IDENTITY overrides the choice; "-" forces ad hoc.
identity="${DROPY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application|Dropy Local Signing/ { print $2; exit }')}"
signing_options=()
if [[ "$identity" == 'Developer ID Application:'* ]]; then
  signing_options=(--options runtime --timestamp)
fi
codesign --force --deep $signing_options --sign "${identity:--}" "$app_dir" >/dev/null
print "$app_dir"
