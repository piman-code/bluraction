#!/bin/bash
# Package an already verified private candidate. Never install or launch it.
set -euo pipefail
if [[ $# -ne 2 ]]; then
    printf 'Usage: %s /absolute/BlurAction.app /absolute/new-output-directory\n' "$0" >&2
    exit 64
fi
bundle="$1"
destination="$2"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$bundle" = /* && "$destination" = /* ]] || { printf 'Use absolute paths.\n' >&2; exit 64; }
[[ -d "$bundle" && ! -L "$bundle" ]] || { printf 'Candidate bundle is missing or a symlink.\n' >&2; exit 1; }
[[ ! -e "$destination" && ! -L "$destination" ]] || { printf 'Output exists; choose a new directory.\n' >&2; exit 1; }
codesign --verify --strict "$bundle"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || exit 64
[[ "$(lipo -archs "$bundle/Contents/MacOS/BlurAction")" = arm64 ]] || { printf 'This packaging recipe requires a verified arm64 candidate.\n' >&2; exit 1; }
mkdir "$destination"
stage="$destination/contents"
mkdir "$stage"
ditto "$bundle" "$stage/BlurAction.app"
codesign --verify --strict "$stage/BlurAction.app"
cmp "$bundle/Contents/MacOS/BlurAction" "$stage/BlurAction.app/Contents/MacOS/BlurAction"
cp "$repo_root/LICENSE" "$stage/LICENSE.txt"
cp "$repo_root/docs/Mac-설치와-복구.md" "$stage/설치와-복구.md"
(cd "$stage" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort) > "$destination/content-manifest.txt"
archive="$destination/BlurAction-$version-build$build-macos-arm64.zip"
ditto -c -k --sequesterRsrc "$stage" "$archive"
hdiutil create -format UDZO -volname "BlurAction $version" -srcfolder "$stage" "$destination/BlurAction-$version-build$build-macos-arm64.dmg"
codesign --verify --strict "$stage/BlurAction.app"
(cd "$stage" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort) > "$destination/content-manifest-after.txt"
cmp "$destination/content-manifest.txt" "$destination/content-manifest-after.txt"
hdiutil verify -quiet "$destination/BlurAction-$version-build$build-macos-arm64.dmg"
codesign -dvv "$stage/BlurAction.app" > "$destination/signature.txt" 2>&1
otool -L "$stage/BlurAction.app/Contents/MacOS/BlurAction" > "$destination/linked-libraries.txt"
(cd "$destination" && shasum -a 256 ./*.zip ./*.dmg > SHA256SUMS.txt)
printf 'Private candidate packages: %s\nNo installation, execution, notarization or publication performed.\n' "$destination"
