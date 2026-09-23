#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/swift-env.sh
mkdir -p .build
swiftc "${swift_compiler_flags[@]}" -D CLIP_HISTORY_CHECKS -module-cache-path "$PWD/.build/module-cache" \
    Sources/ClipHistory/*.swift Tests/ClipHistoryTests/HistoryTests.swift -o .build/HistoryChecks
.build/HistoryChecks
