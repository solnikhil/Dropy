# Contributing to Dropy

Thanks for helping. Dropy is early-stage macOS software that moves other apps' windows around, so the most valuable contributions are careful ones: a fix with a test, or a report of **what works under stated conditions**.

## Ways to help

- **Try it and report.** Build it, use it with your apps, and file a [bug report](https://github.com/solnikhil/Dropy/issues/new?template=bug_report.yml). Results from Macs, displays and apps we haven't tried (Stage Manager, external displays, Electron apps, input methods) are especially useful.
- **Pick up an issue.** Issues labelled [`good first issue`](https://github.com/solnikhil/Dropy/labels/good%20first%20issue) are small and well-scoped. [`help wanted`](https://github.com/solnikhil/Dropy/labels/help%20wanted) issues are bigger.
- **Run an experiment.** Use the [feasibility template](https://github.com/solnikhil/Dropy/issues/new?template=feasibility.yml) for questions like "does this app's window survive docking?"
- **Make an animation.** See [docs/ANIMATIONS.md](docs/ANIMATIONS.md).
- **Improve the docs.** If something confused you, it will confuse the next person.

For anything large, open an issue or a [discussion](https://github.com/solnikhil/Dropy/discussions) first so we can agree on the approach before you write the code.

## Getting set up

You need macOS 15+ on Apple silicon, and Xcode or the Command Line Tools with a Swift 6 toolchain. [Bun](https://bun.sh) is needed only for the benchmark tooling.

```sh
git clone https://github.com/solnikhil/Dropy.git
cd Dropy
swift build && swift test         # SwiftPM build and the XCTest suite
./Scripts/build-local.sh          # assembles .build/local/Dropy.app
./Scripts/test-local.sh           # local checks, plus XCTest without Xcode
open .build/local/Dropy.app
```

If `swift build` fails before compiling (some Command Line Tools installs lack a SwiftPM framework), `./Scripts/build-local.sh` and `./Scripts/test-local.sh` still work. They call `swiftc` directly and run the XCTest suite through a small stand-in.

**Permissions.** Dropy needs Accessibility and Screen Recording. `build-local.sh` signs with your Apple Development identity if you have one, so permissions survive rebuilds. With an ad-hoc signature, macOS treats every rebuild as a new app and you'll have to grant them again. Running the binary from a terminal (`.build/local/Dropy.app/Contents/MacOS/Dropy --show`) uses the terminal's permissions instead. Never ask anyone to disable system protections.

## Making a change

1. Fork the repo and create a branch from `main`.
2. Keep the change focused. One behavior per pull request is easier to review and to revert.
3. Add or update tests. Decisions such as geometry, policies and state transitions belong in `Sources/DropyCore` as plain values with unit tests in `Tests/DropyCoreTests`. The AppKit side in `Sources/Dropy` carries them out.
4. Run `swift test` (or `./Scripts/test-local.sh`) before pushing.
5. Open a pull request and fill in the template, including what you tested by hand: app, macOS version and display setup.

`main` is protected. Every change goes through a pull request, the **macOS CI** check must pass, and review conversations must be resolved. Pull requests are squash-merged, so write the PR title as the commit message you want: imperative mood, describing the behavior (for example, "Keep the selected chooser row visible after catalog changes").

## Ground rules

These keep Dropy safe to run on someone's real Mac:

- **Never lose a window.** Anything that moves another app's window must be journaled first (`PlacementJournal`) and restorable after a crash. If a test moves a window, restore it even when the test fails.
- **Never act on the wrong window.** Keep the selected window's identity separate from the app process and the focused window. Prefer refusing over a broad fallback.
- **Keep content private.** Don't log captured pixels, text or window titles by default. Logs should explain state and timing without revealing someone's work.
- **Don't bypass protections.** No working around macOS capture limits or protected content. A denied permission is a normal state to handle.
- **Claim only what you tested.** Describe support by the app, version and workflow you actually checked. Update [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) or [docs/FEASIBILITY.md](docs/FEASIBILITY.md) when behavior changes.
- **Keep dependencies minimal.** Discuss a new dependency in an issue first and record its license.

## Developer notes

<details>
<summary>Debug switches, device checks, benchmarks and animations</summary>

**Rapid switching.** `DROPY_DEBUG_ALTERNATE=<bundle-id>[,<switches>[,<max-interval-ms>[,close]]]` alternates between that app's first two windows with random gaps and logs which should end up showing. `Dropy capture started/stopped ... running=N` lines show whether a stream leaked.

**Placement experiments.** `DROPY_DEBUG_PLACEMENT=<offscreen|minimize|hideApp|parked>[,<hold-seconds>]`, with direct-open pointed at a test app, places the window, holds, restores it, and logs the result. Every placement is journaled in `~/Library/Application Support/Dropy/placement-journal.json` and undone on quit or at the next launch. Use test windows, not your own documents.

**Recovery.** Unreadable journals are kept, and new moves are blocked when the journal can't be written. If a crash interrupts a move before it's confirmed, the record stays pending: **Recover pending source windows…** in the status menu lets you choose whether to restore it. Recovery never overrides a move you might have made yourself.

**Logs.** Dropy logs through `os.Logger` under the subsystem `org.dropy.app`: `/usr/bin/log show --predicate 'subsystem == "org.dropy.app"' --last 10m`. Each capture stream logs a `Dropy capture metrics:` summary when it stops.

**Device checks.** `Scripts/dismissal-checks.sh` and `Scripts/device-checks.sh` post synthetic input and move the pointer. Run them only on an idle Mac, one at a time. They take a desktop lock, and they refuse to start if someone used the keyboard or pointer in the last few seconds, if the battery is below 30%, or if a modifier key is held. `ONLY=fixture` runs only the disposable fixture checks, which need a second desktop in Mission Control.

**Docking.** Docking decisions live in `DropyCore/DockGeometry.swift` and `DockPolicy.swift` with unit tests. The placement journal must always be able to restore a docked window after a crash.

**Benchmarks.** `bun run bench:plan` explains the suite, `bun run bench:test` verifies the harness, and `bun run bench -- --profile standard --no-build` runs it on an idle, unlocked Mac with Dropy closed. Attach the result directory and the `bun run bench:check` output to changes that affect opening, closing, capture or the Stage, and include the report header (date, revision, hardware, macOS, displays) with any performance claim. See [docs/BENCHMARK.md](docs/BENCHMARK.md).

**Animations.** The format, its limits and the guide live in `Sources/DropyCore` (`AnimationFile`, `DropyAnimation`, `AnimationGuide`). After changing the guide, run `bun run animation:docs` to regenerate [docs/ANIMATIONS.md](docs/ANIMATIONS.md). `./Scripts/test-local.sh` fails while it's out of date.

</details>

## Community

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately, as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

Dropy is [MIT-licensed](LICENSE). By submitting a contribution, you agree that it can be distributed under that license.
