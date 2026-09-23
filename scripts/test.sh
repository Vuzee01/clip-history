#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/swift-env.sh
mkdir -p .build
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "${swift_build_flags[@]}"
else
    print "Xcode test frameworks unavailable; running the same checks directly with swiftc."
    swiftc "${swift_compiler_flags[@]}" -swift-version 6 -D CLIP_HISTORY_CHECKS -module-cache-path "$PWD/.build/module-cache" \
        Sources/ClipHistory/*.swift Tests/ClipHistoryTests/HistoryTests.swift -o .build/HistoryChecks
    .build/HistoryChecks
fi
