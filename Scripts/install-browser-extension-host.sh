#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge_binary="$root_dir/.build/debug/PlainpostBrowserBridge"

if [[ ! -x "$bridge_binary" ]]; then
    echo "Missing built browser bridge: $bridge_binary" >&2
    exit 1
fi

"$bridge_binary" \
    --install-hosts \
    --executable "$bridge_binary"
