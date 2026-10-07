#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
app_dir="$build_dir/Dropy.app"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks"

swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
  -module-name DropyCore \
  -Xlinker -install_name -Xlinker '@rpath/libDropyCore.dylib' \
  -o "$build_dir/libDropyCore.dylib" \
  "$repo_dir"/Sources/DropyCore/*.swift

# The Stage's Objective-C shim (CoreGraphics' private virtual-display classes).
clang -fobjc-arc -fmodules -O2 -c "$repo_dir/Sources/DropyStageShim/DropyStageShim.m" \
  -I "$repo_dir/Sources/DropyStageShim/include" -o "$build_dir/DropyStageShim.o"

swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -I "$repo_dir/Sources/DropyStageShim/include" "$build_dir/DropyStageShim.o" -framework CoreGraphics \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$app_dir/Contents/MacOS/Dropy" \
  "$repo_dir"/Sources/Dropy/*.swift

cp "$build_dir/libDropyCore.dylib" "$app_dir/Contents/Frameworks/"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources"
# Regenerate with `swift Scripts/make-icon.swift`.
cp "$repo_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
# Sign with a real identity when one exists: macOS ties Screen Recording and
# Accessibility to the designated requirement. An ad-hoc signature's requirement is
# the build's hash, so every rebuild was a new app and lost both permissions while
# System Settings still showed Dropy switched on. A certificate-based requirement
# (bundle ID plus certificate) stays the same across builds.
# DROPY_SIGN_IDENTITY overrides the choice; "-" forces ad hoc.
identity="${DROPY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application|Dropy Local Signing/ { print $2; exit }')}"
codesign --force --deep --sign "${identity:--}" "$app_dir" >/dev/null
print "$app_dir"
