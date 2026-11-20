#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived="$project/build/device"
output="$project/build/LiquidTune-unsigned.ipa"

xcodebuild -project "$project/Twelve.xcodeproj" -scheme Twelve -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build

app="$derived/Build/Products/Release-iphoneos/Twelve.app"
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")"
test -f "$app/$executable"
xcrun lipo "$app/$executable" -verify_arch arm64
xcrun vtool -show-build "$app/$executable" | grep -Eq 'platform[[:space:]]+IOS$'

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
/usr/bin/ditto "$app" "$stage/Payload/Twelve.app"
/usr/bin/ditto -c -k --norsrc --keepParent "$stage/Payload" "$stage/LiquidTune-unsigned.ipa"
mv -f "$stage/LiquidTune-unsigned.ipa" "$output"
unzip -t "$output" >/dev/null
printf '%s\n' "$output"
