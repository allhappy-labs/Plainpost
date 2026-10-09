#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  Scripts/benchmark-mail-search.sh --synthetic-all --output-directory DIRECTORY
  Scripts/benchmark-mail-search.sh --production-copy --output-directory DIRECTORY

PLAINPOST_BENCH_SCRATCH_PATH optionally selects an isolated Release cache.
Production-copy mode requires PLAINPOST_BENCH_SOURCE_DB. The source is opened
read-only and copied through SQLite online backup; all migrations and searches
run only against a task-specific temporary copy removed by this script's trap.
EOF
}

mode=""
output_directory=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --synthetic-all|--production-copy)
            if [[ -n "$mode" ]]; then
                echo "error: select exactly one benchmark mode" >&2
                exit 64
            fi
            mode="$1"
            shift
            ;;
        --output-directory)
            if [[ $# -lt 2 ]]; then
                echo "error: --output-directory requires a value" >&2
                exit 64
            fi
            output_directory="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ -z "$mode" || -z "$output_directory" ]]; then
    usage >&2
    exit 64
fi

mkdir -p "$output_directory"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/plainpost-search-benchmark.XXXXXX")"
cleanup() {
    cleanup_status=$?
    trap - EXIT
    rm -rf -- "$temporary_root"
    exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Compile Release once; dataset runs below use this exact binary.
build_arguments=(swift build -c release)
if [[ -n "${PLAINPOST_BENCH_SCRATCH_PATH:-}" ]]; then
    build_arguments+=(--scratch-path "$PLAINPOST_BENCH_SCRATCH_PATH")
fi
rtk "${build_arguments[@]}" --product PlainpostSearchBenchmark
benchmark_bin_directory="$(rtk proxy "${build_arguments[@]}" --show-bin-path)"
benchmark_executable="$benchmark_bin_directory/PlainpostSearchBenchmark"
provenance_path="$temporary_root/provenance.json"
rtk proxy python3 - "$provenance_path" "$benchmark_bin_directory" <<'PYPROVENANCE'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

def output(command):
    return subprocess.check_output(command, text=True)

entries = output(["git", "status", "--porcelain=v1", "-z"]).split("\0")
paths = []
index = 0
while index < len(entries):
    entry = entries[index]
    if len(entry) >= 4:
        paths.append(entry[3:])
        if "R" in entry[:2] or "C" in entry[:2]:
            index += 1
            if index < len(entries) and entries[index]:
                paths.append(entries[index])
    index += 1
toolchain = output(["swift", "--version"]) + output(["xcodebuild", "-version"])
cache = {"bin_directory": str(Path(sys.argv[2]).resolve()), "configuration": "Release", "toolchain": toolchain}
provenance = {"source_sha": output(["git", "rev-parse", "HEAD"]).strip(), "dirty_paths": paths,
              "toolchain": toolchain, "cache_identity": hashlib.sha256(json.dumps(cache, sort_keys=True).encode()).hexdigest(),
              "cache": cache}
Path(sys.argv[1]).write_text(json.dumps(provenance, indent=2) + "\n")
PYPROVENANCE

run_benchmark() {
    rtk proxy python3 - "$provenance_path" "$benchmark_executable" "$@" <<'PYRUN'
import json
import os
from pathlib import Path
import subprocess
import sys
provenance = json.loads(Path(sys.argv[1]).read_text())
command = sys.argv[2:]
environment = dict(os.environ)
environment.update({
    "PLAINPOST_BENCH_SOURCE_SHA": provenance["source_sha"],
    "PLAINPOST_BENCH_DIRTY_PATHS": json.dumps(provenance["dirty_paths"]),
    "PLAINPOST_BENCH_TOOLCHAIN": provenance["toolchain"],
    "PLAINPOST_BENCH_CACHE_IDENTITY": provenance["cache_identity"],
    "PLAINPOST_BENCH_COMMAND_ARGUMENTS": json.dumps(command),
})
status = subprocess.run(command, env=environment, shell=False).returncode
sys.exit(128 - status if status < 0 else status)
PYRUN
}

if [[ "$mode" == "--synthetic-all" ]]; then
    for messages in 10000 50000 100000; do
        arguments=(
            --messages "$messages"
            --iterations 30
            --warmups 3
            --output-json "$output_directory/${messages}.json"
            --working-directory "$temporary_root/$messages"
        )
        if [[ "$messages" == "10000" ]]; then
            arguments+=(--enforce-budgets)
        fi
        run_benchmark "${arguments[@]}"
    done
else
    if [[ -z "${PLAINPOST_BENCH_SOURCE_DB:-}" ]]; then
        echo "error: PLAINPOST_BENCH_SOURCE_DB is required for --production-copy" >&2
        exit 64
    fi
    run_benchmark \
        --messages 10000 \
        --iterations 30 \
        --warmups 3 \
        --source-db "$PLAINPOST_BENCH_SOURCE_DB" \
        --output-json "$output_directory/production-copy.json" \
        --working-directory "$temporary_root/production-copy"
fi
