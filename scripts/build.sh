#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/swift-env.sh
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "${swift_build_flags[@]}"
app="$PWD/dist/Clip History.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/ClipHistory "$app/Contents/MacOS/ClipHistory.new"
mv -f "$app/Contents/MacOS/ClipHistory.new" "$app/Contents/MacOS/ClipHistory"
cp Resources/Info.plist "$app/Contents/Info.plist"
swift "${swift_compiler_flags[@]}" scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.cliphistory.app "$app"
print "Built: $app"
