#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
source "$repo_dir/Scripts/lib/local-build-inputs.zsh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/DropyCore" "$work/Resources" "$work/Scripts/lib"
cp "$repo_dir/Scripts/build-local.sh" "$work/Scripts/"
cp "$repo_dir/Scripts/lib/local-build-inputs.zsh" "$work/Scripts/lib/"
print 'struct First {}' > "$work/Sources/DropyCore/First.swift"
print 'struct Removed {}' > "$work/Sources/DropyCore/Removed.swift"
print 'original' > "$work/Resources/evidence.json"
first="$(local_build_fingerprint "$work")"
touch -t 202001010000 "$work/Sources/DropyCore/First.swift"
[[ "$(local_build_fingerprint "$work")" == "$first" ]]
print 'struct Changed {}' > "$work/Sources/DropyCore/First.swift"
touch -t 202001010000 "$work/Sources/DropyCore/First.swift"
changed="$(local_build_fingerprint "$work")"
[[ "$changed" != "$first" ]]
rm "$work/Sources/DropyCore/Removed.swift"
removed="$(local_build_fingerprint "$work")"
[[ "$removed" != "$changed" ]]
print 'replacement' > "$work/Resources/evidence.json"
[[ "$(local_build_fingerprint "$work")" != "$removed" ]]
print 'Local build input checks passed'
