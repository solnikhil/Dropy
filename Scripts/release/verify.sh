#!/bin/zsh
set -euo pipefail
app="$1"; shift
mode=release
short=''; build=''; tool=''
while (( $# )); do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --short) short="$2"; shift 2 ;;
    --build) build="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    *) print -u2 "Unknown verification argument: $1"; exit 2 ;;
  esac
done
[[ "$mode" == release || "$mode" == dry-run ]] || exit 2
[[ -x "$tool" && -n "$short" && -n "$build" ]] || { print -u2 'Provide the ReleaseTool and expected versions'; exit 2; }
codesign --verify --deep --strict "$app"
"$tool" check-info-plist "$app/Contents/Info.plist" --short "$short" --build "$build"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2> "$work/signature.log"
"$tool" check-entitlements "$work/entitlements.plist"
if [[ "$mode" == release ]]; then
  codesign -dv --verbose=4 "$app" 2> "$work/identity.log"
  rg -q '^Authority=Developer ID Application:' "$work/identity.log"
  rg -q 'flags=.*runtime' "$work/identity.log"
  spctl --assess --type execute --verbose=2 "$app"
  xcrun stapler validate "$app"
else
  codesign -dv "$app" 2> "$work/identity.log"
  rg -q '^Signature=adhoc$' "$work/identity.log"
fi
print 'Release bundle verification passed'
