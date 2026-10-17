#!/bin/zsh
# Prepare a signed Sparkle archive/feed. Upload only when explicitly passed --publish.
set -euo pipefail
repo_dir="${0:A:h:h}"
(( $# == 3 || $# == 4 )) || { print -u2 'Usage: Scripts/release-update.sh VERSION BUILD OWNER/RELEASES-REPO [--publish]'; exit 2; }
version="$1"
build="$2"
release_repo="$3"
publish="${4:-}"
[[ -z "$publish" || "$publish" == --publish ]] || { print -u2 'Unknown release option'; exit 2; }
python3 - "$version" "$build" "$release_repo" <<'PYCHECK'
import re, sys
version, build, repo = sys.argv[1:]
assert re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',version), 'Expected a stable semantic version'
assert re.fullmatch(r'[1-9][0-9]*',build) and int(build)<2**63, 'Expected a positive build number'
assert re.fullmatch(r'[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+',repo), 'Expected OWNER/REPOSITORY'
PYCHECK
[[ -z "$(git -C "$repo_dir" status --porcelain)" ]] || { print -u2 'Release from a clean checkout so the artifact identifies an exact source commit.'; exit 1; }
expected_feed="https://github.com/$release_repo/releases/latest/download/appcast.xml"
configured_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$repo_dir/Resources/Info.plist")"
[[ "$configured_feed" == "$expected_feed" ]] || { print -u2 'Release repository does not match the configured update channel.'; exit 1; }
sparkle_dir="$("$repo_dir/Scripts/fetch-sparkle.sh")"
public_key="$("$sparkle_dir/bin/generate_keys" --account org.dropy.app -p)"
configured_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$repo_dir/Resources/Info.plist")"
[[ "$public_key" == "$configured_key" ]] || { print -u2 'The local signing key does not match this application; refusing to publish.'; exit 1; }
if [[ "$publish" == --publish ]]; then
  [[ "$(gh repo view "$release_repo" --json isPrivate --jq .isPrivate)" == false ]] || { print -u2 'This publisher requires a public releases-only repository.'; exit 1; }
  [[ "${DROPY_SIGN_IDENTITY:-}" == 'Developer ID Application:'* && -n "${DROPY_NOTARY_PROFILE:-}" ]] || {
    print -u2 'Public releases require DROPY_SIGN_IDENTITY (Developer ID Application) and DROPY_NOTARY_PROFILE.'; exit 1;
  }
fi
out="$repo_dir/.build/releases/$version-$build"
[[ ! -e "$out" ]] || { print -u2 "Release output already exists: $out"; exit 1; }
mkdir -p "$out"
app="$(DROPY_BUILD_CONFIGURATION=release DROPY_RELEASE_VERSION="$version" DROPY_RELEASE_BUILD="$build" "$repo_dir/Scripts/build-local.sh")"
codesign --verify --deep --strict "$app"
if [[ -n "${DROPY_NOTARY_PROFILE:-}" ]]; then
  notarization_archive="$out/notarization.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$notarization_archive"
  xcrun notarytool submit "$notarization_archive" --keychain-profile "$DROPY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose "$app"
  rm "$notarization_archive"
fi
archive="$out/Dropy-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
commit="$(git -C "$repo_dir" rev-parse HEAD)"
print -r -- "Dropy $version (build $build)" > "$out/Dropy-$version.md"
print -r -- "Source commit: $commit" >> "$out/Dropy-$version.md"
"$sparkle_dir/bin/generate_appcast" --account org.dropy.app --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$release_repo/releases/download/v$version/" \
  --link "https://github.com/$release_repo" "$out"
"$sparkle_dir/bin/sign_update" --account org.dropy.app --verify "$out/appcast.xml"
print -r -- "Prepared signed update: $out"
if [[ "$publish" == --publish ]]; then
  [[ "$(gh repo view "$release_repo" --json isPrivate --jq .isPrivate)" == false ]] || { print -u2 'This publisher requires a public releases-only repository.'; exit 1; }
  gh release create "v$version" "$archive" "$out/appcast.xml" --repo "$release_repo" \
    --title "Dropy $version" --notes-file "$out/Dropy-$version.md" --latest
fi
