# Dropy app icon

The current app icon is `dropy-option-merged-v3.png`. Other PNGs in this folder are alternative design explorations; version numbers do not determine the selected design.

`Scripts/make-icon.swift` packages the current artwork into a macOS ICNS with all ten standard representations, from 16 px to 1024 px. It crops the artwork's tile to fill the whole square, with no transparent margin: macOS 26 and later show an icon with a margin shrunk inside a grey frame, and apply their own rounded mask to a full-square one. Run `swift Scripts/make-icon.swift` after changing the artwork to refresh the checked-in `Resources/AppIcon.icns`.

`Scripts/build-local.sh` also generates the bundle's icon directly from the current artwork on every build, so an old checked-in ICNS cannot silently ship in an otherwise current app. For a standalone output, use `swift Scripts/make-icon.swift --output /path/to/AppIcon.icns`.
