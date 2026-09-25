# Compatibility observations

This is a **development observation log**, not a supported-app list. A green capture image does not mean the app is interactive inside Dropy. Results need a Dropy revision, macOS version, target app version, display configuration and tested workflow before they can become release support claims.

| Dropy revision | Environment | Target | Observed workflow | Result | Original window |
|---|---|---|---|---|---|
| Initial native build | M2 MacBook, macOS 27.0, built-in display | Spotify (version not recorded) | Select running window; show live pixels in Metal preview | Visual preview passed; input not enabled | Visible elsewhere |
| Initial native build | Same device | tldraw offline (version not recorded) | Select running window; show live pixels in Metal preview | Visual preview passed; input not enabled | Visible elsewhere |
| Controlled test harness | Same device | Small AppKit test app | Move a specially unconstrained window entirely off-screen; capture it; click an AX-exposed button through a mirror | Narrow controlled check passed | Out of sight by test-only subclass |

All other apps and workflows are **untested**. A protected or unavailable capture region will be reported as a platform limitation rather than bypassed. The [roadmap](../ROADMAP.md) defines the matrix needed before any *interactive* compatibility level is offered.
