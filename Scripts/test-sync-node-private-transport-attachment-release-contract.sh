#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helper="$root/Scripts/lib/acceptance-attachment-release-probe.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-attachment-release.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

control="$temporary/control"
runtime_log="$temporary/runtime.log"
mkdir -m 0700 "$control"

request="$control/attachment-release-probe.request"
applied="$control/attachment-release-probe.applied"
failed="$control/attachment-release-probe.failed"
active="$control/mailbox.stream-active"
: >"$active"
: >"$request"

"$helper" process "$control" "$request" "$applied" "$failed" "$runtime_log" &
controller_pid=$!
failed_seen=0
for _ in $(seq 1 600); do
  if [ -e "$failed" ]; then
    failed_seen=1
    break
  fi
  sleep 0.01
done
[ "$failed_seen" -eq 1 ]
wait "$controller_pid"
[ ! -e "$request" ]
[ -e "$active" ]
[ ! -e "$applied" ]
[ "$(find "$control" -maxdepth 1 -type f -name '*.failed' | wc -l | tr -d '[:space:]')" -eq 1 ]
[ "$(stat -f '%Lp' "$failed")" = 600 ]
[ "$(grep -c '^ERROR acceptance-attachment-release outcome=active$' "$runtime_log")" -eq 1 ]

success_control="$temporary/success-control"
success_log="$temporary/success.log"
mkdir -m 0700 "$success_control"
success_request="$success_control/attachment-release-probe.request"
success_applied="$success_control/attachment-release-probe.applied"
success_failed="$success_control/attachment-release-probe.failed"
: >"$success_request"
"$helper" process "$success_control" "$success_request" "$success_applied" "$success_failed" "$success_log"
[ -e "$success_applied" ]
[ ! -e "$success_failed" ]
[ "$(stat -f '%Lp' "$success_applied")" = 600 ]
[ "$(grep -c '^ERROR acceptance-attachment-release outcome=released$' "$success_log")" -eq 1 ]

printf 'sync_node_private_transport_attachment_release_contract=passed\n'
