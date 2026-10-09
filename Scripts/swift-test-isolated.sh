#!/usr/bin/env bash
set -euo pipefail

# Keep Foundation's temporary SQLite databases (including WAL and SHM files)
# inside a directory owned by this test invocation. Remove it only after the
# SwiftPM test process and its children have exited.
temporary_parent="${PLAINPOST_TEST_TMP_PARENT:-/private/tmp}"
test_temporary_directory="$(mktemp -d "${temporary_parent%/}/ppst.XXXXXX")"

cleanup() {
    rm -rf -- "$test_temporary_directory"
}
trap cleanup EXIT

TMPDIR="$test_temporary_directory/" swift test "$@"
