#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h:h}"
build_dir="$repo_dir/.build/bench-suite"
mkdir -p "$build_dir"
for role in fixture backdrop; do
  app="$build_dir/Benchmark-$role.app"
  mkdir -p "$app/Contents/MacOS"
  swiftc -O -swift-version 6 "$repo_dir/Scripts/bench/BenchmarkFixture/main.swift" \
    "$repo_dir/Sources/Dropy/BenchmarkControl.swift" -o "$app/Contents/MacOS/BenchmarkFixture"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BenchmarkFixture</string>
<key>CFBundleIdentifier</key><string>org.dropy.benchmark$role</string>
<key>CFBundleName</key><string>Dropy Benchmark $role</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
  codesign --force --sign - "$app" >/dev/null
 done
swiftc -O -swift-version 6 "$repo_dir/Scripts/bench/BenchmarkFixture/Tool.swift" -o "$build_dir/BenchTool"
swiftc -O -swift-version 6 "$repo_dir/Scripts/bench/Sampler.swift" -o "$build_dir/Sampler"
"$build_dir/Sampler" self-check
