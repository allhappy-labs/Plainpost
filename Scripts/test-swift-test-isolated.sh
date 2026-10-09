#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d /private/tmp/ppst-contract.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/bin"
cat >"$fixture/bin/swift" <<'SWIFT'
#!/bin/sh
[ "$1" = test ] || exit 90
printf x >"${TMPDIR}/fixture.sqlite-wal"
printf x >"${TMPDIR}/fixture.sqlite-shm"
exit "${FAKE_SWIFT_EXIT:-0}"
SWIFT
chmod +x "$fixture/bin/swift"

for expected in 0 17; do
    actual=0
    PATH="$fixture/bin:$PATH" \
        PLAINPOST_TEST_TMP_PARENT="$fixture" \
        FAKE_SWIFT_EXIT="$expected" \
        "$script_directory/swift-test-isolated.sh" --filter Fixture || actual=$?
    [ "$actual" -eq "$expected" ] || {
        printf 'expected exit %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    }
    if find "$fixture" -maxdepth 1 -type d -name 'ppst.*' | grep -q .; then
        printf 'isolated test temp directory survived exit %s\n' "$expected" >&2
        exit 1
    fi
done
printf 'isolated Swift test cleanup passed (success and failure)\n'
