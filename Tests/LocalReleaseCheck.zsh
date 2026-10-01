#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
DROPY_SIGN_IDENTITY=- DROPY_NOTARY_PROFILE= DROPY_BUILD_NUMBER=1 \
  "$repo_dir/Scripts/release/package.sh" --dry-run --output "$work/output"
(cd "$work/output"; shasum -a 256 -c SHA256SUMS)
mkdir "$work/unpacked"
archives=("$work/output"/*.zip)
(( ${#archives} == 1 ))
ditto -x -k "$archives[1]" "$work/unpacked"
codesign --verify --deep --strict "$work/unpacked/Dropy.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$work/unpacked/Dropy.app/Contents/Info.plist")" == 1 ]]
# Misconfigured development signing must be caught even in a rehearsal. Check the
# policy with the small CLI, without another expensive package build.
mkdir "$work/core"
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name DropyCore \
  -Xlinker -install_name -Xlinker '@rpath/libDropyCore.dylib' \
  -o "$work/core/libDropyCore.dylib" "$repo_dir"/Sources/DropyCore/*.swift
swiftc -swift-version 6 -I "$work/core" -L "$work/core" -lDropyCore \
  -Xlinker -rpath -Xlinker "$work/core" -o "$work/ReleaseTool" \
  "$repo_dir/Scripts/release/ReleaseTool/main.swift"
"$work/ReleaseTool" self-test
if "$work/ReleaseTool" plan --mode dry-run --version-file "$repo_dir/VERSION" --build 1 \
    --identity 'Apple Development: Test' > "$work/refusal.log" 2>&1; then
  print -u2 'Development signing was accepted'; exit 1
fi
if "$work/ReleaseTool" check-entitlements "$work/missing.plist" > "$work/missing.log" 2>&1; then
  print -u2 'Missing entitlement evidence was accepted'; exit 1
fi
print 'Release rehearsal checks passed (no app launched or notarization submitted)'
