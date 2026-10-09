#!/bin/sh

sync_node_tls13_probe_succeeded() {
  [ "$#" -eq 1 ] || return 1
  grep -E '^[[:space:]]*Protocol[[:space:]]*:[[:space:]]*TLSv1\.3[[:space:]]*$' "$1" >/dev/null &&
    grep -F 'Verify return code: 0 (ok)' "$1" >/dev/null
}

sync_node_tls12_probe_succeeded() {
  [ "$#" -eq 1 ] || return 1
  grep -E '^[[:space:]]*Protocol[[:space:]]*:[[:space:]]*TLSv1\.2[[:space:]]*$' "$1" >/dev/null &&
    grep -F 'Verify return code: 0 (ok)' "$1" >/dev/null &&
    tls12_cipher=$(awk -F: '/^[[:space:]]*Cipher[[:space:]]*:/ {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }' "$1") &&
    [ -n "$tls12_cipher" ] &&
    case "$tls12_cipher" in
      0000*|*'(NONE)'*) return 1 ;;
      *) return 0 ;;
    esac
}
