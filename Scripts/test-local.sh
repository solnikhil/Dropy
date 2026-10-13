#!/bin/zsh
# Local checks for machines where `swift build`/`swift test` cannot run.
#   1. Tests/DropyCoreTests (the XCTest suite CI runs) against a minimal XCTest shim.
#   2. The precondition checks in Tests/Local*.swift, including the app-side journal.
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
# Rebuild whenever any source is newer than the built library: testing a stale
# library passed three deliberate regressions on 2026-09-30.
# (A loop, not a glob qualifier: a false test inside a qualifier trips set -e.)
rebuild=0
[[ -f "$build_dir/libDropyCore.dylib" ]] || rebuild=1
for source in "$repo_dir"/Sources/**/*.swift "$repo_dir"/Resources/**/*(N.); do
  if [[ "$source" -nt "$build_dir/libDropyCore.dylib" ]]; then rebuild=1; break; fi
done
if (( rebuild )); then "$repo_dir/Scripts/build-local.sh" >/dev/null; fi

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

# AppKit-level regression checks for the overlay panel (no window is shown).
swiftc -swift-version 6 -o "$build_dir/OnboardingChecks" \
  "$repo_dir/Tests/LocalOnboardingCheck.swift" "$repo_dir/Sources/Dropy/OnboardingProgress.swift"
"$build_dir/OnboardingChecks"

swiftc -swift-version 6 -o "$build_dir/OverlayPanelChecks" \
  "$repo_dir/Tests/LocalOverlayPanelCheck.swift" "$repo_dir/Sources/Dropy/OverlayPanel.swift"
"$build_dir/OverlayPanelChecks"

swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker "$build_dir" -o "$build_dir/WorkspaceChecks" \
  "$repo_dir/Tests/LocalWorkspaceCheck.swift" "$repo_dir/Sources/Dropy/OverlayWorkspaceView.swift" \
  "$repo_dir/Sources/Dropy/DropyAppearance.swift"
"$build_dir/WorkspaceChecks"

# Deterministic close/reopen, interrupted adoption and Live-to-preview ownership.
swiftc -swift-version 6 -o "$build_dir/WindowSessionChecks" \
  "$repo_dir/Tests/LocalWindowSessionCheck.swift" "$repo_dir/Sources/Dropy/WindowSessionQueue.swift"
"$build_dir/WindowSessionChecks"

# The production Live caster with controlled IO (no recording request).
swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker "$build_dir" -o "$build_dir/LiveCasterChecks" \
  "$repo_dir/Tests/LocalLiveCasterCheck.swift" "$repo_dir/Sources/Dropy/LiveCaster.swift"
"$build_dir/LiveCasterChecks"


# The animation command line, in a throwaway animations folder: every built-in style and
# example checks clean, a new file round-trips, a broken one fails, and the repository's
# format guide matches the one Dropy writes (regenerate with `bun run animation:docs`).
app_binary="$build_dir/Dropy.app/Contents/MacOS/Dropy"
animations_dir="$(mktemp -d)"
export DROPY_ANIMATIONS_FOLDER="$animations_dir"
for name in rapid balanced smooth springy elastic-drop snap float pop jelly curtain; do
  "$app_binary" animation check "$name" >/dev/null || { print -u2 "animation check $name failed"; exit 1; }
done
"$app_binary" animation new "Check Drop" --from springy >/dev/null
"$app_binary" animation check check-drop >/dev/null
"$app_binary" animation render check-drop --out "$animations_dir/check.png" >/dev/null
[[ -s "$animations_dir/check.png" ]] || { print -u2 "animation render wrote nothing"; exit 1; }
print '{ "open": 1 }' > "$animations_dir/broken.json"
if "$app_binary" animation check broken >/dev/null 2>&1; then print -u2 "a broken animation passed its check"; exit 1; fi
print '{ "dropyAnimation": 1e100 }' > "$animations_dir/oversized-version.json"
if "$app_binary" animation check oversized-version >"$animations_dir/version-check.txt" 2>&1; then
  print -u2 "an oversized format version passed its check"; exit 1
fi
grep -q 'newer Dropy' "$animations_dir/version-check.txt" || { print -u2 "an oversized version was not diagnosed"; exit 1; }
for verb in play watch; do
  for slow in nan inf -inf nope; do
    if "$app_binary" animation "$verb" check-drop --slow "$slow" >"$animations_dir/slow-check.txt" 2>&1; then
      print -u2 "animation $verb accepted --slow $slow"; exit 1
    fi
    grep -q 'finite number' "$animations_dir/slow-check.txt" || { print -u2 "--slow $slow was not diagnosed"; exit 1; }
  done
done
[[ -f "$animations_dir/README.md" && -f "$animations_dir/AGENTS.md" && -f "$animations_dir/Examples/pop.json" ]] \
  || { print -u2 "the animations folder was not prepared"; exit 1; }
"$app_binary" animation docs --generic | diff -q - "$repo_dir/docs/ANIMATIONS.md" >/dev/null \
  || { print -u2 "docs/ANIMATIONS.md is out of date: run bun run animation:docs"; exit 1; }
unset DROPY_ANIMATIONS_FOLDER
rm -rf "$animations_dir"
print "Animation command checks passed"

# Desktop-session lock and preference recovery (throwaway lock and preferences domain).
"$repo_dir/Tests/LocalDeviceSessionCheck.zsh"

# Drawable retries and racing callbacks must produce one final frame outcome.
swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker "$build_dir" -o "$build_dir/FrameStampChecks" \
  "$repo_dir/Tests/LocalFrameStampCheck.swift" "$repo_dir/Sources/Dropy/CaptureMetricsRecorder.swift"
"$build_dir/FrameStampChecks"

# Isolation of third-party apps under test (throwaway tree; no app is launched).
"$repo_dir/Tests/LocalAppIsolationCheck.zsh"
