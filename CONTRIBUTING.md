# Contributing to Dropy

Dropy is early-stage macOS software. The most valuable contributions establish **what works under stated conditions**. Please check [ROADMAP.md](ROADMAP.md) and existing issues before starting a large change.

## Build and verify

Use a macOS machine with Xcode and a Swift 6 toolchain:

```sh
swift build
swift test
./Scripts/build-local.sh
./Scripts/test-local.sh
```

The local build script assembles an ad-hoc-signed development `.app` in `.build/local`. It is not a release package. Screen capture and Accessibility are separate macOS permissions; do not ask contributors to disable system protections. If a test changes another app's window, restore it even after failure.

Each rebuild changes the ad-hoc signature, so macOS may treat it as a new app for Screen Recording. Launching the binary from a terminal (`.build/local/Dropy.app/Contents/MacOS/Dropy --show`) uses the terminal's grant instead.

To stress rapid switching without input automation, set `DROPY_DEBUG_ALTERNATE=<bundle-id>[,<switches>[,<max-interval-ms>[,close]]]`. Dropy alternates between that app's first two picker windows with random gaps, logs the window that should end up showing, and with `close` closes the overlay afterwards. `Dropy capture started/stopped ... running=N` log lines show whether any stream leaked.

For M2 placement experiments, set `DROPY_DEBUG_PLACEMENT=<offscreen|minimize|hideApp|parked>[,<hold-seconds>]` with direct-open pointing at a test app. Dropy places the previewed window, holds, restores it, and logs capture continuity, the visible fraction and whether the restore matched. Moving and minimizing need Accessibility permission. Every placement is journaled in `~/Library/Application Support/Dropy/placement-journal.json` first and undone on quit or at the next launch. Use test windows, not your own documents.

Each stream logs a `Dropy capture metrics:` summary when it stops. `Scripts/benchmark.sh` runs the repeatable workloads; see [docs/BENCHMARK.md](docs/BENCHMARK.md) for the method, the clock-domain rules and how to report results. Include the report's header (date, revision, hardware, macOS, displays) with any performance claim.

## Issues and pull requests

- Use an issue for an implementation slice or a reproducible feasibility experiment. State macOS version, target app/version, display configuration, permissions and exact interaction being tested.
- Keep the captured window's identity distinct from the app process and the focused window. Avoid broad fallbacks that can send input to the wrong target.
- Do not log captured pixels, text, window titles or other sensitive content by default. Logs should explain state and performance without disclosing a user's work.
- Report a capability only for the workflow and app classes actually verified. Update [docs/FEASIBILITY.md](docs/FEASIBILITY.md) and, when applicable, the compatibility matrix in the relevant issue.
- Add tests for geometry, state transitions and regressions that would change behavior. Explain manual UI or performance checks in the PR body.
- Keep dependencies minimal and record their license before adding one.

The project uses the [MIT license](LICENSE). By submitting a contribution, you agree that it can be distributed under that license.

Placement recovery retains unreadable journals and blocks new moves when a journal cannot be written. If a crash interrupts the move before its actual position is confirmed, the record stays pending: use **Recover pending source windows…** in the status menu to explicitly choose whether to restore the original position. Automatic recovery never guesses over a possible later user move.

`Scripts/device-checks.sh` refuses an existing Dropy instance or pending recovery journal. It tracks only the Dropy process it launches, checks the exact window ID selected by its independent helper, compares application-hidden state as well as geometry and minimization, and queries actual window-server coverage while placed. Unconfirmed placement is reported as NOT RUN, and crash recovery requires an observed move plus a journal and a logged restore. Raw logs are retained beside the dated report. Click-outside and pointer-leave remain explicit manual checks in the report. Each step records the active Space and frontmost app, so switching desktops during a run is reported as interference, and a failed step saves a `WindowTool snapshot` of the Accessibility and window-server state. `ONLY=fixture` runs only the disposable fixture checks, including Space recovery; they need a second desktop in Mission Control. The fixture is launched through LaunchServices because Dropy requires a process launch date for exact identity.

`Scripts/test-local.sh` also runs the `Tests/DropyCoreTests` XCTest suite through a minimal local XCTest stand-in (`Tests/LocalXCTest`) for toolchains without XCTest; CI runs the same tests with the real framework.

Dropy does not forward input: Full App interaction moves the app's real window into the overlay (see ARCHITECTURE). Changes to docking keep their decisions in `DropyCore/DockGeometry.swift` and `DockPolicy.swift` with unit tests, and must leave the placement journal able to restore the window after a crash. `Scripts/dismissal-checks.sh` and `Scripts/device-checks.sh` post synthetic input and move the pointer: run them on an idle Mac, one at a time. Each takes the desktop lock in `Scripts/lib/device-session.zsh` and refuses to start while another check holds it or while someone used the keyboard or pointer in the last few seconds. Device sessions refuse to start on battery below 30%. Every event carries explicit modifier flags, and the scripts refuse to start or stop when a modifier is left held.

Animations: the format, its limits and the guide live in `Sources/DropyCore` (`AnimationFile`, `DropyAnimation`, `AnimationGuide`). After changing the guide, run `bun run animation:docs` to regenerate [docs/ANIMATIONS.md](docs/ANIMATIONS.md); `./Scripts/test-local.sh` fails while it is out of date, and also exercises `Dropy animation` in a throwaway folder (`DROPY_ANIMATIONS_FOLDER`).

Tooling runs on Bun: `bun run bench:plan` explains the current disposable-fixture suite, `bun run bench:test` verifies the harness, and `bun run bench:build` produces an optimized build. Run `bun run bench -- --profile standard --no-build` on an idle, unlocked Mac with Dropy closed; attach the entire result directory and `bun run bench:check` output to opening, closing, capture or Stage changes. See [BENCHMARK](docs/BENCHMARK.md) for validity rules, product gates and the limits of synthetic evidence. The opt-in benchmark control channel is tested without showing windows by the local suite.

