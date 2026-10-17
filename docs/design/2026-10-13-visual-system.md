# Dropy visual system

## Direction

Dropy should feel calm, precise and at home on a Mac. The overlay's shape and movement
are its identity. Settings should make those choices understandable through small
illustrations, with supporting explanations kept subordinate to the controls.

## Foundations

- `DropyAppearance` owns semantic AppKit colors; `SettingsTheme` adapts them for SwiftUI.
  Near-black and warm off-white establish the surfaces. Coral identifies selected choices
  and important actions. Blue is informational, and system green/red retain status meaning.
- `SettingsMetrics` owns spacing, controls, card corners and the reading type scale.
  Body text is 13 points, supporting text 12. Page titles are 24 points; navigation
  group labels are compact and letter-spaced.
- Cards have an opaque, appearance-aware surface and a thin boundary. Hover changes
  the surface; selection adds an accent boundary plus a checkmark or selected trait.
  Color is never the sole selection signal.
- The content column is bounded and centered. Settings can resize, with a minimum
  size that preserves the controls. Sidebar width remains adjustable and saved.

## Shared presentation

Every Settings page begins with its title and a short purpose statement. Sidebar
navigation is a flat list, without branding, category labels or a decorative footer. Native buttons,
menus, switches, text fields and disclosure groups retain keyboard and accessibility
behavior. Transparency and navigation motion continue to honor system preferences.

`WorkspaceIllustration` draws schematic content and uses production `NotchShape` and
`OverlayPosition` geometry. It never captures another app. Size and position tiles use
one selection treatment and one illustration language. Animation previews use the
production motion renderer with the same slate-and-warm wallpaper palette.

Technical display and video consequences remain available in an expandable explanation.
The summary must still explain the effect of the setting before the person changes it.
Warnings and permission requirements remain immediately visible.

## Animation and overlay

Animation Settings presents the motion preview, built-in styles, personal collection,
examples, then optional AI/terminal tools. Studio separates playback from committing an
animation: Play All is the main playback action, each motion can be played independently,
and Use Animation is the primary commit. Real-notch playback is available in the menu.

Window picker rows use app icons, app names and secondary document titles. The existing
exact-window identity and keyboard navigation remain the source of selection. Hover and
keyboard selection are distinct presentation states. Empty/loading messages have a
centered illustration; populated lists have a count and keyboard guidance. Preview
messages use a readable foreground on the overlay's permanently dark surface.

## Verification

Build and run the existing local checks, including AppKit workspace layout, capture and
window lifecycle, and animation validation. Review General, Overlay, Animation,
Interaction, permission states, search, and Studio in the running app. Check the minimum
window size, sidebar resizing, light/dark appearance, keyboard focus, Reduce Motion and
Increase Contrast when available. Visual review is separate from compile/test success.

Implementation checks on 2026-10-13: the direct signed build and full local check suite
passed. The workspace checks passed again after the final empty-state layout changes.
After the Mac was unlocked, the installed app was updated and General, Overlay,
Animation, Interaction, permission status and search were reviewed in the running dark
appearance. Studio review caught toolbar overflow; playback speed now uses a compact
menu and the complete layout was visually rechecked. The schematic drawing canvas is
explicitly bounded so decorative wallpaper cannot expand or crop its geometry. The
final build was installed and General was left open. Light appearance, accessibility
preference combinations, and live picker visuals have not been manually reviewed.

Revision on 2026-10-14: General now contains neutral Application controls without the
welcome illustration. Setup headings and menu labels are neutral. Updates has a dedicated
page and startup checks; release-source and publishing requirements are in `docs/UPDATES.md`.

Revision on 2026-10-14: the dark window surface is #0E0E10, sidebar #0A0A0C,
cards #171719, selection #222225, primary text #F0F0F2, supporting text #A1A1AA,
and muted coral #E87868. Sidebar and window are opaque so wallpaper cannot change
the palette. Cards use 12-point corners, rows a 44-point minimum, and standard
system lettering with 24-point semibold page titles. Selection uses a neutral fill,
with accent confined to icons and actions. The default Settings window is 920 × 620
points, resizable down to 800 × 560. The new frame key applies that compact default
once and then preserves subsequent resizing. Overlay tile structure is unchanged;
schematic wallpaper and animation sample content use darker, subdued surfaces.
The signed build and workspace checks passed. General, Permissions, Overlay and
Animation were visually reviewed in the installed app's dark appearance.


## Settings design review — 14 October

The near-black palette and existing Overlay composition remain the foundation.
A visual pass across Settings found inconsistent secondary text: read-only values,
update status descriptions, disclosure labels, animation metadata, and unselected
choices still used system opacity-based secondary styling. They now use the same
adaptive semantic secondary-text color as row descriptions, keeping the hierarchy
consistent on the opaque dark surfaces. Disabled controls retain their separate
disabled treatment.

Page descriptions and section titles now use neutral, functional language: Pinned
App, Size, Position, Motion Presets, and Saved Animations. Shared components own
these treatments so future Settings pages inherit the same presentation.
