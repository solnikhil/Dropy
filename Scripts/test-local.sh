#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
if [[ ! -f "$build_dir/libDropyCore.dylib" ]]; then
  "$repo_dir/Scripts/build-local.sh" >/dev/null
fi
swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker "$build_dir" \
  -o "$build_dir/DropyCoreTests" \
  "$repo_dir/Tests/LocalGeometryCheck.swift"
"$build_dir/DropyCoreTests"
