#!/bin/zsh
# Builds the disposable device-check source apps into .build/local:
#   DropyFixture.app       (org.dropy.fixture)       placement and Space recovery
#   DropyInputFixture.app  (org.dropy.inputfixture)  exact-window input harness
set -euo pipefail
repo_dir="${0:A:h:h:h}"
for name in Fixture InputFixture; do
  app="$repo_dir/.build/local/Dropy$name.app"
  mkdir -p "$app/Contents/MacOS"
  swiftc -O -swift-version 6 -o "$app/Contents/MacOS/Dropy$name" "$repo_dir/Scripts/bench/$name/main.swift"
  cp "$repo_dir/Scripts/bench/$name/Info.plist" "$app/Contents/Info.plist"
  codesign --force --sign - "$app" >/dev/null 2>&1
  print "$app"
done
