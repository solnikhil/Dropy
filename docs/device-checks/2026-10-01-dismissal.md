# Dropy dismissal checks

- Date: 2026-10-01 14:35 IST; revision: 7732db8 (uncommitted changes)
- macOS: 27.0 (26A428); real HID events; fixture app frontmost before each open

| Check | Result | Observed |
|---|---|---|
| shortcut opens | PASS | panel on screen |
| Esc closes, focus returns | PASS | open=no frontmost=org.dropy.fixture |
| shortcut closes, focus returns | PASS | open=no frontmost=org.dropy.fixture |
| manual: click outside keeps it open | PASS | open=yes frontmost=org.dropy.fixture |
| click outside (other app) closes, focus returns | PASS | open=no frontmost=org.dropy.fixture |
| click outside (Dropy menu) closes | PASS | menu opened, overlay closed |
| pointer-leave: opened with pointer elsewhere stays open | PASS | open=yes frontmost=org.dropy.app |
| pointer-leave: leaving closes, focus returns | PASS | open=no frontmost=org.dropy.fixture |
