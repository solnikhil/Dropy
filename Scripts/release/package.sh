#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h:h}"
mode=release
output="$repo_dir/.build/release"
while (( $# )); do
  case "$1" in
    --dry-run) mode=dry-run; shift ;;
    --output) output="$2"; shift 2 ;;
    *) print -u2 "Unknown package argument: $1"; exit 2 ;;
  esac
done
mkdir -p "$output"
stage="$(mktemp -d "$output/.package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/build"
source "$repo_dir/Scripts/lib/local-build-inputs.zsh"
build_target="$(local_macos_target "$repo_dir")"
inputs="$(local_build_fingerprint "$repo_dir")"
swiftc -target "$build_target" -swift-version 6 -O -parse-as-library -emit-library -emit-module -module-name DropyCore \
  -Xlinker -install_name -Xlinker '@rpath/libDropyCore.dylib' \
  -o "$stage/build/libDropyCore.dylib" "$repo_dir"/Sources/DropyCore/*.swift
swiftc -swift-version 6 -I "$stage/build" -L "$stage/build" -lDropyCore \
  -Xlinker -rpath -Xlinker "$stage/build" -o "$stage/build/ReleaseTool" \
  "$repo_dir/Scripts/release/ReleaseTool/main.swift"
tag="$(git -C "$repo_dir" describe --exact-match --match 'v*' HEAD 2>/dev/null || true)"
dirty=0
[[ -z "$(git -C "$repo_dir" status --porcelain)" ]] || dirty=1
typeset -A plan
while IFS='=' read -r key value; do plan[$key]="$value"; done < <(
  "$stage/build/ReleaseTool" plan --mode "$mode" --version-file "$repo_dir/VERSION" \
    --tag "${tag:--}" --build "${DROPY_BUILD_NUMBER:--}" --dirty "$dirty" \
    --identity "${DROPY_SIGN_IDENTITY:--}" --notary-profile "${DROPY_NOTARY_PROFILE:--}"
)
# A failed process substitution does not propagate its exit code to this loop.
[[ -n "${plan[sign]:-}" && -n "${plan[zip]:-}" ]] || { print -u2 'Release policy refused packaging'; exit 1; }
for name in "${plan[app]}" "${plan[zip]}" "${plan[dmg]}" "${plan[checksums]}"; do
  [[ ! -e "$output/$name" ]] || { print -u2 "Refusing to overwrite existing artifact: $name"; exit 1; }
done
app="$stage/${plan[app]}"
mkdir -p "$app/Contents/"{MacOS,Frameworks,Resources}
swiftc -target "$build_target" -swift-version 6 -O -I "$stage/build" -L "$stage/build" -lDropyCore \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$app/Contents/MacOS/Dropy" "$repo_dir"/Sources/Dropy/*.swift
cp "$stage/build/libDropyCore.dylib" "$app/Contents/Frameworks/"
cp "$repo_dir/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$repo_dir/Resources/InputEvidence.json" "$app/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${plan[short]}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${plan[bundle]}" "$app/Contents/Info.plist"
[[ "$inputs" == "$(local_build_fingerprint "$repo_dir")" ]] || { print -u2 'Sources changed while packaging'; exit 1; }
"$stage/build/ReleaseTool" check-info-plist "$app/Contents/Info.plist" --short "${plan[short]}" --build "${plan[bundle]}"
identity="${plan[sign_identity]}"
signing_args=(--force --sign "$identity" --options runtime)
if [[ "$mode" == release ]]; then signing_args+=(--timestamp); fi
codesign "${signing_args[@]}" "$app/Contents/Frameworks/libDropyCore.dylib"
codesign "${signing_args[@]}" --entitlements "$repo_dir/Scripts/release/entitlements.plist" "$app"
if [[ "$mode" == release ]]; then
  notary_args=(--keychain-profile "${plan[notarize_profile]}" --wait)
  if [[ -n "${DROPY_NOTARY_KEYCHAIN:-}" ]]; then notary_args+=(--keychain "$DROPY_NOTARY_KEYCHAIN"); fi
  ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/notary.zip"
  xcrun notarytool submit "$stage/notary.zip" "${notary_args[@]}"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi
"$repo_dir/Scripts/release/verify.sh" "$app" --short "${plan[short]}" --build "${plan[bundle]}" \
  --mode "$mode" --tool "$stage/build/ReleaseTool"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/${plan[zip]}"
mkdir -p "$stage/volume"
ditto "$app" "$stage/volume/${plan[app]}"
ln -s /Applications "$stage/volume/Applications"
hdiutil create -quiet -volname "${plan[volume]}" -srcfolder "$stage/volume" -format UDZO "$stage/${plan[dmg]}"
if [[ "$mode" == release ]]; then
  codesign --sign "$identity" --timestamp "$stage/${plan[dmg]}"
  xcrun notarytool submit "$stage/${plan[dmg]}" "${notary_args[@]}"
  xcrun stapler staple "$stage/${plan[dmg]}"
  xcrun stapler validate "$stage/${plan[dmg]}"
fi
(cd "$stage"; shasum -a 256 "${plan[zip]}" "${plan[dmg]}" > "${plan[checksums]}")
# Nothing is exported until verification, notarization and checksums have succeeded.
for name in "${plan[app]}" "${plan[zip]}" "${plan[dmg]}" "${plan[checksums]}"; do mv "$stage/$name" "$output/$name"; done
print "Package ready in $output ($mode; no app launched)"
