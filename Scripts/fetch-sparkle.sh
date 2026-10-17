#!/bin/zsh
# Pinned, verified Sparkle distribution for the direct swiftc build and release tools.
set -euo pipefail
repo_dir="${0:A:h:h}"
version=2.10.0
checksum=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
deps="$repo_dir/.build/dependencies"
cache="$deps/sparkle-$version"
marker="$cache/.verified-sha256"
ready() { [[ -f "$marker" && "$(cat "$marker")" == "$checksum" && -d "$cache/Sparkle.framework" && -x "$cache/bin/generate_appcast" ]]; }
if ready; then print -r -- "$cache"; exit 0; fi
mkdir -p "$deps"
lock="$deps/.sparkle-$version.lock"
for attempt in {1..300}; do
  if mkdir "$lock" 2>/dev/null; then break; fi
  if ready; then print -r -- "$cache"; exit 0; fi
  if [[ -f "$lock/pid" ]] && ! kill -0 "$(cat "$lock/pid")" 2>/dev/null; then
    rm -rf "$lock"
  fi
  (( attempt < 300 )) || { print -u2 'Timed out waiting for Sparkle download; retry the build.'; exit 1; }
  sleep 0.2
done
print -r -- "$$" > "$lock/pid"
temporary="$(mktemp -d "$deps/.sparkle-download.XXXXXX")"
trap 'rm -rf "$temporary" "$lock"' EXIT
if ready; then print -r -- "$cache"; exit 0; fi
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
  -o "$temporary/Sparkle.tar.xz"
actual="$(shasum -a 256 "$temporary/Sparkle.tar.xz" | awk '{print $1}')"
[[ "$actual" == "$checksum" ]] || { print -u2 'Sparkle checksum mismatch; refusing this dependency.'; exit 1; }
mkdir "$temporary/payload"
tar -xf "$temporary/Sparkle.tar.xz" -C "$temporary/payload"
[[ -d "$temporary/payload/Sparkle.framework" && -x "$temporary/payload/bin/generate_appcast" ]]
print -r -- "$checksum" > "$temporary/payload/.verified-sha256"
rm -rf "$cache"
mv "$temporary/payload" "$cache"
print -r -- "$cache"
