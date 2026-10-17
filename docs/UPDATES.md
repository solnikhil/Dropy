# Release update checks

Dropy checks the repository configured by `DropyUpdateRepository` in Info.plist on every
normal app startup. Settings → Updates and Check for Updates in the app/menu-bar menus
provide the same checker. Animation command-line operations and benchmark/debug launches
do not make update requests. Requests are asynchronous with bounded timeouts; duplicate
startup/manual requests coalesce.

## Release source

The selected source is `solnikhil/Dropy`. Checks use the public
[GitHub Releases API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
without authentication, cookies, or user identifiers. No credentials are embedded in
the app. The repository must be public for end-user checks. At implementation time it
is private, so the public API returns 404 and the app reports source unavailability.
Making the repository public or supplying a separate public release repository is a
publisher decision; the updater does not change repository visibility.

Latest-release 404 is not treated as "up to date": Dropy checks whether the repository
is accessible. A confirmed public repository without a stable release gets a separate
"No Stable Release Published" state. Network errors, malformed metadata, unsupported
version tags, rate limits and server failures remain explicit failures.

## Publishing

1. Set `CFBundleShortVersionString` to the release's semantic version and increment
   `CFBundleVersion` for each distributed build.
2. Build, sign and verify the distributable app. Attach its macOS archive or disk image
   to a stable GitHub release tagged `vMAJOR.MINOR.PATCH` in the public source repository.
3. Publish release notes. Draft and prerelease metadata cannot become stable updates.
4. Verify startup checks from an older installed version and View Release from Settings.

Version comparison is numeric and observes prerelease ordering, preventing string-order
mistakes such as 1.9 being newer than 1.10. Build metadata does not change precedence.
A newer release offers View Release, opening only a validated HTTPS release page under
the configured GitHub repository. This is update discovery and manual download, not an
automatic installation or app replacement system.

## Cache and verification

Successful release metadata and its ETag are cached in versioned app defaults. Every
startup still sends a request; a 304 revalidates that known release. Cached metadata is
validated against the configured repository and URL before reuse. A failure never claims
the installed app is current and never advances Last Successful Check.

Tests cover semantic ordering, malformed versions, release URL validation, current/newer
releases, offline and private-source behavior, public repositories without releases,
rate/server failures, ETag reuse across launches, and coalescing concurrent requests.

The installed app was reviewed: flat navigation and neutral General labels are present,
startup checks reported the private-source error without user interaction, and the app
menu check opened Updates and repeated the same check. The isolated staged revision also
passed the complete local suite, independently of concurrent onboarding edits.
