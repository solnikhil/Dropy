# Dropy app icon

The current app icon is `dropy-sketch-icon-v5.png`. Other PNGs in this folder are earlier design explorations.

`Scripts/make-icon.swift` packages the current artwork into a transparent macOS ICNS with all ten standard representations, from 16 px to 1024 px. Run `swift Scripts/make-icon.swift` after changing the artwork to refresh the checked-in `Resources/AppIcon.icns`.

`Scripts/build-local.sh` also generates the bundle's icon directly from the current artwork on every build, so an old checked-in ICNS cannot silently ship in an otherwise current app. For a standalone output, use `swift Scripts/make-icon.swift --output /path/to/AppIcon.icns`.
