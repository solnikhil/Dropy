# Hand-off typing implementation review

The explicit overlay button now hands the exact source window back for native typing. Preview input stays refused throughout starting, active use and asynchronous re-parking. Unsupported preview typing remains refused.

Follow-up fixes preserve the placement entry after failed/unobserved restoration, clear only its hand-off marker and request recovery. Accessibility trust and readable minimized state are required to begin. Ends during a suspended start are deferred; another start cannot overlap an asynchronous end. The source terminating ends the session. Focus is rechecked after re-parking so a later app switch wins.

Validation: native build and full local suite pass (121 core test cases plus native and shell checks). Added settlement, permission, unreadable-state and deferred-end regressions. Persistent hand-off labels are measured with the actual AppKit font against the shared compact/medium/wide status layout.

No real app hand-off, capture or HID device run was performed. Device checks remain paused for this work. M3 is not complete and this change does not enable unverified preview input.
