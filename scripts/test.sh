#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-cache"
args=(--disable-sandbox --cache-path "$repo_root/.build/cache")
# CLT ships Swift Testing but does not automatically locate its macro plugin.
plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$plugin" ]]; then
    args+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin")
fi
swift test "${args[@]}" "$@"
