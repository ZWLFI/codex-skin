#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h}
"$project_dir/build.sh"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")
cd "$project_dir/dist"
archive="Codex-Skin-$version-universal.zip"
/usr/bin/codesign --verify --deep --strict 'Codex Skin.app'
/usr/bin/ditto -c -k --norsrc --keepParent 'Codex Skin.app' "$archive"
/usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
printf 'Release package: %s/dist/%s\n' "$project_dir" "$archive"
