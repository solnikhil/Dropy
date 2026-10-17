# Signed automatic updates

Dropy uses Sparkle 2.10.0 for update discovery, signed downloads, installation and
relaunch. Settings › Updates exposes manual checks and Sparkle's persisted automatic
check/download preferences. Default checks run on startup and every six hours; a
person's existing choice is never overwritten. Sparkle presents install progress
and can install downloaded updates when Dropy quits. Normal termination still saves
Studio and restores owned windows.

## Channel configuration

A build requires both `SUFeedURL` (an HTTPS appcast) and `SUPublicEDKey` (a 32-byte
Ed25519 public key) in `Resources/Info.plist`. Both archives and the appcast must be
signed: `SURequireSignedFeed` is enabled. Missing configuration is shown explicitly
and never falls back to an unsigned download or reports that the app is current.

**Hosting is not configured yet.** The source repository is private. A public
releases-only repository can host installable binaries and `appcast.xml` while
source stays private, but publishing those binaries is a separate owner decision.
A private channel instead needs authenticated feed and archive access; merely using
a private GitHub download URL does not implement authentication. Never embed GitHub
tokens in an app bundle or feed URL.

For a public releases-only repository, the feed URL is:
`https://github.com/OWNER/RELEASES-REPOSITORY/releases/latest/download/appcast.xml`.
No repository visibility or publication changes are performed by the app.

## Signing and publishing

The update private key lives in the macOS login Keychain under account `org.dropy.app`.
Only the public key is checked in. Keep a secure owner-managed backup of the private
key; replacing the public key without a signed migration strands existing installs.
Never commit or print the private key in release logs.

`Scripts/fetch-sparkle.sh` downloads the pinned official distribution, verifies its
SHA-256, and caches its framework and signing tools. SwiftPM separately pins the same
exact version. See `ThirdParty/Sparkle-LICENSE` for licensing.

After choosing the public channel and setting its feed URL, prepare an update from
a clean checkout:

```sh
./Scripts/release-update.sh 0.1.2 3 OWNER/RELEASES-REPOSITORY
```

The script builds with explicit version/build metadata, checks the bundle signature,
creates a ZIP, generates a signed appcast and verifies its signature. Artifacts go to
`.build/releases/VERSION-BUILD`. Build numbers must increase with every release.
Review the artifacts before uploading. Add `--publish` to upload the prepared build
to a public releases-only repository and mark that GitHub release latest. The source
repository remains private. The publisher refuses a missing/mismatched feed, signing
key, dirty checkout, duplicate output directory or non-public destination.

External macOS distribution also requires Developer ID Application signing and Apple
notarization. The development machine currently has an Apple Development identity;
that supports this Mac's development installation but is not a notarized public
release. Public publishing requires `DROPY_SIGN_IDENTITY` naming a Developer ID
Application identity and `DROPY_NOTARY_PROFILE` naming stored notarytool credentials.
The publisher submits, waits, staples, and assesses the app before archiving it.
Sparkle's Ed25519 signature authenticates updates independently of Apple signing.

## Verification

`Scripts/test-local.sh` exercises configuration validation, startup scheduling,
manual checks, persisted choices, busy/error cases and installation routing using a
fake engine. `Scripts/build-local.sh` compiles the real Sparkle adapter and embeds
its framework and helpers. CI builds through both SwiftPM and the direct script,
runs the checks and verifies the assembled bundle signature. A successful build
alone does not prove that a hosted channel or end-to-end installation is working;
verify the reachable signed appcast and an upgrade before distributing a channel.

Official references: [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/),
[publishing](https://sparkle-project.org/documentation/publishing/).
