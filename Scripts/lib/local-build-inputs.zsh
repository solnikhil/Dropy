# Content identity for the local app and core library. Paths are included so a
# source removal or rename invalidates the build even when no file is newer.
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
