# Dropy private alpha — tester guide

This is an early testing build, not a public release. Share it with people who understand that some interaction workflows are unfinished. It is ad-hoc signed and has not been notarized by Apple.

## Requirements

- Apple Silicon Mac (M1 or newer). This package does not include an Intel executable.
- macOS 15 or newer is the compiled minimum. Runtime verification so far is on macOS 27.0; older versions still need testing.
- A running app with a window to preview. Start with a disposable TextEdit document.

## Install and start

1. Unzip the tester kit and copy `Dropy.app` to Applications.
2. Open Dropy. It is a menu-bar app: look for its diamond icon rather than a Dock window.
3. This private alpha is not notarized. If macOS says the developer cannot be verified, first check that the file came directly from the person sharing this kit. Apple's documented per-app approval is System Settings → Privacy & Security → Open Anyway after attempting to open it. Details: https://support.apple.com/en-us/102445. A managed Mac may not allow this approval. A damaged-app or malware warning should be reported instead of treated as an ordinary developer warning.
4. Use the diamond menu's **Open Dropy**, or Option-Command-D. Select your scratch app window.
5. If capture is blocked, use Dropy's **Open Privacy Settings** button and allow Dropy in Screen & System Audio Recording. Relaunch if macOS asks. This permission is needed to preview the selected window.
6. Begin with the default view-only preview. Close with Esc or the Close button.

## Optional interaction

Enable **Interactive preview (beta)** from the diamond menu only when you want to test it. Allow Accessibility for Dropy when prompted; it is used to target window controls and interact with the source. Check the preview's support label before trying input. Support is specific to application version, macOS major version, element type and window condition, so another Mac may remain view-only.

TextEdit click/scroll/typing are verified only for the recorded visible and parked workflows. Safari supports recorded page-button clicks and some scrolling, not text entry. Arbitrary Electron apps are not verified. Unsupported shortcuts, editing keys, drag, right-click and input methods are refused. A selected region is view-only. The real-window hand-off button is experimental and has not passed the new integrated device checks.

## First test: five minutes

Use a scratch document with no important content.

- Open its live preview; resize the source and check that the preview updates.
- Switch between two scratch windows. Confirm the selected source is the one displayed.
- Close with Esc, then open/close with Option-Command-D.
- Test the menu's click-outside or pointer-leave dismissal setting and focus return.
- If interaction is offered, click/type a short marker and confirm only the chosen scratch window changes. Refusal is expected when the support label says view-only.
- Quit Dropy and confirm your app windows are still available.

## Known issues in this build

- A click can be refused with “Preview updating · input not sent”, including during animation and the first click of a double-click. These intermittent misses remain unresolved.
- TextEdit input is refused when foreign overlays make the source classify as covered; overlapping Wispr Flow/Dock windows reproduced this on the test Mac.
- Ordinary off-screen containment exposes a small portion of the source. Parking remains experimental; minimize/hide can pause capture.
- New hand-off, region selection, pins, full-screen/multiple displays and current performance budgets need further device verification.
- No automatic updater. Obtain a new tester kit from the project owner when requested.

## Report a problem

Send the completed `FEEDBACK.txt` to the person who gave you this build, or use https://github.com/solnikhil/Dropy/issues. Include the build from `BUILD-INFO.json`, macOS/app versions, steps, expected/actual result and the preview's exact refusal text. Screenshots should use only scratch content. Do not include personal documents, captured content, typed secrets or unrelated window titles.

## Remove

Quit Dropy from its menu, move Dropy.app to Trash, and remove its Screen Recording and Accessibility grants in System Settings if desired.
