#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/.build/local"
app_dir="$build_dir/Dropy.app"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks"

swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
  -module-name DropyCore \
  -Xlinker -install_name -Xlinker '@rpath/libDropyCore.dylib' \
  -o "$build_dir/libDropyCore.dylib" \
  "$repo_dir"/Sources/DropyCore/*.swift

swiftc -swift-version 6 -I "$build_dir" -L "$build_dir" -lDropyCore \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$app_dir/Contents/MacOS/Dropy" \
  "$repo_dir"/Sources/Dropy/*.swift

cp "$build_dir/libDropyCore.dylib" "$app_dir/Contents/Frameworks/"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir" >/dev/null
print "$app_dir"
