#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app="$project_dir/dist/Codex Skin.app"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  /usr/bin/swiftc -parse-as-library -swift-version 5 -O \
    -target "$arch-apple-macos13.0" \
    -framework AppKit -framework UniformTypeIdentifiers \
    "$project_dir/CodexBackground.swift" \
    -o "$project_dir/dist/CodexBackground-$arch"
done
/usr/bin/lipo -create "$project_dir/dist/CodexBackground-arm64" \
  "$project_dir/dist/CodexBackground-x86_64" -output "$app/Contents/MacOS/CodexBackground"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$app"
"$app/Contents/MacOS/CodexBackground" --self-test
printf '已生成：%s\n' "$app"
