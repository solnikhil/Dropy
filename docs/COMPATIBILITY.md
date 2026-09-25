# Compatibility observations

This is a **development observation log**, not a supported-app list. A green capture image does not mean the app is interactive inside Dropy. Results need a Dropy revision, macOS version, target app version, display configuration and tested workflow before they can become release support claims.

| Dropy revision | Environment | Target | Observed workflow | Result | Original window |
|---|---|---|---|---|---|
| Initial native build | M2 MacBook, macOS 27.0, built-in display | Spotify (version not recorded) | Select running window; show live pixels in Metal preview | Visual preview passed; input not enabled | Visible elsewhere |
| Initial native build | Same device | tldraw offline (version not recorded) | Select running window; show live pixels in Metal preview | Visual preview passed; input not enabled | Visible elsewhere |
| Controlled test harness | Same device | Small AppKit test app | Move a specially unconstrained window entirely off-screen; capture it; click an AX-exposed button through a mirror | Narrow controlled check passed | Out of sight by test-only subclass |
| Capture lifecycle branch (#2, #3) | Same device, display asleep for part of the run | TextEdit 1.21 (AppKit), two documents | Exact identity across resize, move, minimize, app hide, close and quit/relaunch with the same files; direct-open preview; minimize/restore; close; quit | Identities stayed distinct; relaunched documents never matched old selections; preview reported paused/viewing, window closed and target quit | Visible elsewhere |
| Same | Same | Safari 27.0 (WebKit), two `about:blank` windows | Same-title windows; resize, close one, quit | Resolution stayed exact; picker now labels them "(1 of 2)" and "(2 of 2)" | Visible elsewhere |
| Same | Same | ChatGPT 26.917.71314 (`com.openai.codex`) | Picker listing | A floating layer-3 panel with the main window's title was listed as a second identical entry; now excluded | Visible elsewhere |

TextEdit's window can stay in the WindowServer after its document closes while the display is asleep; Dropy correctly keeps it as the source until it disappears. All other apps and workflows are **untested**. A protected or unavailable capture region will be reported as a platform limitation rather than bypassed. The [roadmap](../ROADMAP.md) defines the matrix needed before any *interactive* compatibility level is offered.
