# Release packaging and distribution policy

`Scripts/release/package.sh --dry-run --output /path/to/empty-output` rehearses an optimized build, ad-hoc signing, bundle verification, ZIP/DMG generation and checksums. It never launches the app or submits notarization. Apple Development identities are refused even during rehearsal. Existing artifacts are never overwritten.

Real packaging needs a clean exact `v*` tag agreeing with VERSION, a Developer ID Application identity in DROPY_SIGN_IDENTITY, a notarytool keychain profile in DROPY_NOTARY_PROFILE and a monotonically increasing DROPY_BUILD_NUMBER. The main app and embedded core library use hardened runtime. Notarized app and DMG tickets are stapled before export; Gatekeeper and strict signature checks run. Prerelease labels remain in artifact names; the bundle's short version is the numeric triple required by Apple.

The tag workflow rehearses when secrets are absent, refuses partially configured secrets, and uses an ephemeral runner keychain when complete. It uploads build artifacts only; creating a public release remains a separate owner decision. No updater dependency or network code was added.

## Updates and rollback

Automatic updates remain pending a product decision. Options are manual signed downloads with published checksums, or a separately reviewed updater such as Sparkle. No option is selected by this implementation.

Withdraw a faulty release and republish previously validated source with a higher build number. Preserve both releases' source tags, notarization records and checksums. The rollback policy refuses unnotarized or unverifiable targets. Never replace a published binary under an existing version.

## Privacy review gate

Before distribution verify: Screen Recording and Accessibility purpose text; explicit permission flow and revocation; capture limited to the selected source; no audio/camera/network entitlements; no captured pixels, typed content or window titles in exported reports; crash/recovery behavior; private per-window API compatibility and disclosure; dependency and update policy; signing/notarization on the actual release artifact; third-party app/display compatibility. These are remaining release gates, not claims of completed validation.

References: [Apple bundle short-version format](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring), [Apple build-version format](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion).

## Private alpha packages

A tester kit may wrap an ad-hoc rehearsal app with the [private alpha guide](PRIVATE_ALPHA_TESTING.md), license, feedback template, exact source/build metadata and checksums. Such a kit is explicitly not a notarized release. The current package is native Apple Silicon only. Normal Developer ID distribution remains unavailable without the appropriate certificate and notarization credentials.

Both local and packaged builds now pass an explicit target derived from `LSMinimumSystemVersion`; the package verifier checks the app and embedded library's actual Mach-O deployment versions and architecture agreement. This prevents a host macOS 27 compiler default from silently overriding the advertised macOS 15 minimum. Deployment compatibility is not a claim of runtime verification on every supported OS.
