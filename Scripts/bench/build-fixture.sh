#!/bin/zsh
# Builds the disposable device-check source app into .build/local/DropyFixture.app.
set -euo pipefail
repo_dir="${0:A:h:h:h}"
app="$repo_dir/.build/local/DropyFixture.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 6 -o "$app/Contents/MacOS/DropyFixture" "$repo_dir/Scripts/bench/Fixture/main.swift"
cp "$repo_dir/Scripts/bench/Fixture/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null
print "$app"
