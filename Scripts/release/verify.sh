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
# A matching plist alone cannot make a binary built for the host's newer macOS run
# on the advertised minimum. Check both shipped Mach-O files before export.
python3 - "$app" <<'PY'
import pathlib, plistlib, re, subprocess, sys
app = pathlib.Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('rb') as stream:
    minimum = plistlib.load(stream)['LSMinimumSystemVersion']
def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))
architectures = None
for file in [app / 'Contents/MacOS/Dropy', app / 'Contents/Frameworks/libDropyCore.dylib']:
    current = set(subprocess.check_output(['lipo', '-archs', str(file)], text=True).split())
    if not current or not current <= {'arm64', 'x86_64'}:
        raise SystemExit(f'Unsupported architecture in {file.name}: {current}')
    if architectures is not None and current != architectures:
        raise SystemExit('App and embedded library architectures differ')
    architectures = current
    output = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(file)], text=True)
    targets = re.findall(r'^\s*minos\s+([0-9.]+)\s*$', output, re.M)
    if len(targets) != len(current) or any(version(target) != version(minimum) for target in targets):
        raise SystemExit(f'{file.name} minimum {targets} differs from Info.plist {minimum}')
print(f'Binary deployment verified: {", ".join(sorted(architectures))}, macOS {minimum}')
PY
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2> "$work/signature.log"
"$tool" check-entitlements "$work/entitlements.plist"
if [[ "$mode" == release ]]; then
  codesign -dv --verbose=4 "$app" 2> "$work/identity.log"
  grep -Eq '^Authority=Developer ID Application:' "$work/identity.log"
  grep -Eq 'flags=.*runtime' "$work/identity.log"
  spctl --assess --type execute --verbose=2 "$app"
  xcrun stapler validate "$app"
else
  codesign -dv "$app" 2> "$work/identity.log"
  grep -Eq '^Signature=adhoc$' "$work/identity.log"
fi
print 'Release bundle verification passed'
