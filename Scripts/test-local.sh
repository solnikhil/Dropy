#!/bin/zsh
# Local checks for machines where `swift build`/`swift test` cannot run.
#   1. Tests/DropyCoreTests (the XCTest suite CI runs) against a minimal XCTest shim.
#   2. The precondition checks in Tests/Local*.swift, including the app-side journal.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
if [[ ! -f "$build_dir/libDropyCore.dylib" ]]; then
  "$repo_dir/Scripts/build-local.sh" >/dev/null
fi

# XCTest suite through the shim. The runner calls every `func test…()` it finds.
shim_dir="$build_dir/xctest-shim"
mkdir -p "$shim_dir"
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name XCTest \
  -Xlinker -install_name -Xlinker '@rpath/libXCTest.dylib' \
  -o "$shim_dir/libXCTest.dylib" -emit-module-path "$shim_dir/XCTest.swiftmodule" \
  "$repo_dir/Tests/LocalXCTest/XCTest.swift"
runner="$shim_dir/main.swift"
{
  print -r -- "import Foundation"
  print -r -- "import XCTest"
  for file in "$repo_dir"/Tests/DropyCoreTests/*.swift; do
    class_name="$(grep -oE 'class [A-Za-z0-9_]+: XCTestCase' "$file" | head -1 | awk '{print $2}' | tr -d ':')"
    [[ -n "$class_name" ]] || continue
    print -r -- "do { let suite = $class_name()"
    grep -oE 'func test[A-Za-z0-9_]+\(\)( throws)?' "$file" | while read -r signature; do
      method="${${signature#func }%%\(*}"
      if [[ "$signature" == *throws ]]; then
        print -r -- "  xctestRun(\"$class_name.$method\") { try suite.$method() }"
      else
        print -r -- "  xctestRun(\"$class_name.$method\") { suite.$method() }"
      fi
    done
    print -r -- "}"
  done
  print -r -- 'if !xctestFailures.isEmpty { print("\(xctestFailures.count) XCTest assertion(s) failed"); exit(1) }'
  print -r -- 'print("DropyCoreTests passed (local XCTest shim)")'
} > "$runner"
swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore -I "$shim_dir" -L "$shim_dir" -lXCTest \
  -Xlinker -rpath -Xlinker "$build_dir" -Xlinker -rpath -Xlinker "$shim_dir" \
  -o "$shim_dir/DropyCoreTests" "$runner" "$repo_dir"/Tests/DropyCoreTests/*.swift
"$shim_dir/DropyCoreTests"

swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker "$build_dir" \
  -o "$build_dir/DropyCoreTests" \
  "$repo_dir/Tests/LocalGeometryCheck.swift"
"$build_dir/DropyCoreTests"

swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker "$build_dir" \
  -o "$build_dir/PlacementJournalTests" \
  "$repo_dir/Tests/LocalPlacementJournalCheck.swift" \
  "$repo_dir/Sources/Dropy/PlacementJournal.swift" \
  "$repo_dir/Sources/Dropy/PlacementRecovery.swift" \
  "$repo_dir/Sources/Dropy/WindowPlacer.swift" \
  "$repo_dir/Sources/Dropy/WindowCatalog.swift"
"$build_dir/PlacementJournalTests"
