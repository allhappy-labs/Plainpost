#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
owner="$root/Scripts/test-sync-node-private-transport.sh"
probe="$root/Scripts/lib/sync-node-tls-probe.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-private-transport-tls.XXXXXX")
cleanup() {
  find "$fixture" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

test -r "$probe"
. "$probe"

printf '%s\n' 'CONNECTED(00000003)' 'Protocol : TLSv1.3' 'Cipher : TLS_AES_256_GCM_SHA384' 'Verify return code: 0 (ok)' >"$fixture/tls13-accepted"
printf '%s\n' 'CONNECTED(00000003)' 'Protocol : TLSv1.3' 'Verify return code: 21 (unable to verify the first certificate)' >"$fixture/tls13-unverified"
printf '%s\n' 'CONNECTED(00000003)' 'Protocol : TLSv1.2' 'Cipher : ECDHE-RSA-AES256-GCM-SHA384' 'Verify return code: 0 (ok)' >"$fixture/tls12-accepted"
printf '%s\n' 'CONNECTED(00000003)' 'Protocol : TLSv1.2' 'Cipher : 0000 (NONE)' 'Verify return code: 0 (ok)' >"$fixture/tls12-rejected"

sync_node_tls13_probe_succeeded "$fixture/tls13-accepted"
if sync_node_tls13_probe_succeeded "$fixture/tls13-unverified"; then
  printf 'TLS 1.3 probe accepted an unverified certificate\n' >&2
  exit 1
fi
sync_node_tls12_probe_succeeded "$fixture/tls12-accepted"
if sync_node_tls12_probe_succeeded "$fixture/tls13-accepted"; then
  printf 'TLS 1.3 output was classified as TLS 1.2\n' >&2
  exit 1
fi
if sync_node_tls12_probe_succeeded "$fixture/tls12-rejected"; then
  printf 'failed TLS 1.2 output was classified as an accepted handshake\n' >&2
  exit 1
fi

# A successful transcript remains authoritative when LibreSSL reports a
# nonzero command status after closing the connection.
tls13_probe_status=1
sync_node_tls13_probe_succeeded "$fixture/tls13-accepted"
tls12_probe_status=1
sync_node_tls12_probe_succeeded "$fixture/tls12-accepted"

if grep -F -- '-brief' "$owner" >/dev/null; then
  printf 'portable TLS probe still uses unsupported s_client -brief\n' >&2
  exit 1
fi
grep -F -- '-tls1_3' "$owner" | grep -F -- '-verify_return_error' | grep -F -- '-CAfile' >/dev/null
grep -F -- '-tls1_2' "$owner" | grep -F -- '-verify_return_error' | grep -F -- '-CAfile' >/dev/null
grep -F -- '-verify 5' "$owner" >/dev/null
grep -F 'sync_node_tls13_probe_succeeded' "$owner" >/dev/null
grep -F 'sync_node_tls12_probe_succeeded' "$owner" >/dev/null

# LibreSSL can return a nonzero s_client status after producing a successful
# handshake transcript. The transcript classifier, not that status alone, is
# the authoritative TLS 1.3 acceptance seam.
tls13_probe_block=$(awk '
  /tls13_probe_status=0/ { inside=1 }
  inside { print }
  inside && /if openssl s_client -tls1_2/ { exit }
' "$owner")
if printf '%s\n' "$tls13_probe_block" | grep -E '^[[:space:]]*(if|[[]).*tls13_probe_status' >/dev/null; then
  printf 'TLS 1.3 owner rejects a valid transcript solely on s_client status\n' >&2
  exit 1
fi
printf '%s\n' "$tls13_probe_block" | grep -F 'sync_node_tls13_probe_succeeded' >/dev/null
grep -F 'tls13_probe_status=0' "$owner" >/dev/null
grep -F 'openssl s_client -tls1_3' "$owner" | grep -F '|| tls13_probe_status=$?' >/dev/null
awk '
  /tls13_probe_status=0/ { status=NR }
  /sync_node_tls13_probe_succeeded/ { proof=NR }
  END { exit !(status > 0 && proof > status) }
' "$owner"

tls12_command_line=$(awk '/^  if openssl s_client -tls1_2/ { print NR; exit }' "$owner")
tls12_command_end=$(awk -v start="$tls12_command_line" 'NR > start && /^  fi$/ { print NR; exit }' "$owner")
tls12_region_end=$(awk -v start="$tls12_command_line" 'NR > start && /curl --silent --fail.*healthz/ { print NR; exit }' "$owner")
tls12_success_helper=$(awk -v start="$tls12_command_line" -v end="$tls12_command_end" 'NR > start && NR < end && /^    if sync_node_tls12_probe_succeeded/ { print NR; exit }' "$owner")
tls12_after_status_helper=$(awk -v start="$tls12_command_end" -v end="$tls12_region_end" 'NR > start && NR < end && /sync_node_tls12_probe_succeeded/ { print NR; exit }' "$owner")
[ -n "$tls12_command_line" ] && [ -n "$tls12_command_end" ] && [ -n "$tls12_region_end" ] && [ -n "$tls12_success_helper" ] && [ -n "$tls12_after_status_helper" ]
tls12_status_gate_detected() {
  awk -v start="$1" -v end="$2" '
    NR >= start && NR <= end && /^[[:space:]]*(if|[[]).*tls12_probe_status/ { found=1; exit }
    END { exit !found }
  ' "$3"
}
if tls12_status_gate_detected "$tls12_command_line" "$tls12_region_end" "$owner"; then
  printf 'TLS 1.2 owner gates rejection on s_client status before transcript proof\n' >&2
  exit 1
fi
forbidden_tls12_owner="$fixture/forbidden-tls12-owner"
printf '%s\n' \
  '  if openssl s_client -tls1_2 -verify_return_error; then' \
  '    if [ "$tls12_probe_status" -ne 0 ]; then' \
  '      exit 1' \
  '    fi' \
  '  fi' \
  '  curl --silent --fail https://node/healthz' >"$forbidden_tls12_owner"
tls12_status_gate_detected 1 5 "$forbidden_tls12_owner"

printf 'sync_node_private_transport_tls_contract=passed\n'
