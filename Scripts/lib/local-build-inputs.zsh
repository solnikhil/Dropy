# Content identity for the local app and core library. Paths are included so a
# source removal or rename invalidates the build even when no file is newer.
local_macos_target() {
  local repo="$1" minimum architecture
  minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo/Resources/Info.plist")" || return 1
  [[ "$minimum" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 'Invalid minimum macOS version'; return 1; }
  architecture="$(uname -m)"
  [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { print -u2 'Unsupported Mac architecture'; return 1; }
  print -r -- "$architecture-apple-macosx$minimum"
}

local_build_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
inputs = list((root / "Sources").rglob("*.swift"))
inputs += [item for item in (root / "Resources").rglob("*") if item.is_file()]
inputs += [root / "Scripts/build-local.sh", root / "Scripts/lib/local-build-inputs.zsh"]
digest = hashlib.sha256()
for item in sorted(inputs):
    relative = item.relative_to(root).as_posix().encode()
    digest.update(relative + b"\0")
    digest.update(hashlib.sha256(item.read_bytes()).digest())
print(digest.hexdigest())
PY
}
