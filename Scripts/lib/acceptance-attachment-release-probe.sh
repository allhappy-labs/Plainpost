#!/bin/sh

acceptance_attachment_release_probe() {
  acceptance_attachment_release_control_root=$1
  acceptance_attachment_release_request=$2
  acceptance_attachment_release_applied=$3
  acceptance_attachment_release_failed=$4
  acceptance_attachment_release_runtime_log=$5
  acceptance_attachment_release_poll_attempts=${6:-20}
  acceptance_attachment_release_poll_delay_seconds=${7:-0.25}
  acceptance_attachment_release_status=1

  rm -f "$acceptance_attachment_release_request"
  for acceptance_attachment_release_attempt in $(seq 1 "$acceptance_attachment_release_poll_attempts"); do
    acceptance_attachment_release_active=$(find "$acceptance_attachment_release_control_root" -maxdepth 1 -type f -name '*.stream-active' -print -quit 2>>"$acceptance_attachment_release_runtime_log" || true)
    if [ -z "$acceptance_attachment_release_active" ]; then
      acceptance_attachment_release_status=0
      break
    fi
    sleep "$acceptance_attachment_release_poll_delay_seconds"
  done
  if [ "$acceptance_attachment_release_status" -eq 0 ]; then
    : >"$acceptance_attachment_release_applied"
    chmod 0600 "$acceptance_attachment_release_applied"
    printf 'ERROR acceptance-attachment-release outcome=released\n' >>"$acceptance_attachment_release_runtime_log"
  else
    : >"$acceptance_attachment_release_failed"
    chmod 0600 "$acceptance_attachment_release_failed"
    printf 'ERROR acceptance-attachment-release outcome=active\n' >>"$acceptance_attachment_release_runtime_log"
  fi
}

if [ "${0##*/}" = "acceptance-attachment-release-probe.sh" ]; then
  [ "${1:-}" = process ] && [ "$#" -ge 6 ] || exit 2
  shift
  acceptance_attachment_release_probe "$@"
fi
