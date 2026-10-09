#!/bin/sh

acceptance_is_canonical_ipv4_octet() {
  case "$1" in
    0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) return 0 ;;
    *) return 1 ;;
  esac
}

acceptance_is_private_ipv4() {
  candidate=${1:-}
  case "$candidate" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  previous_ifs=$IFS
  IFS=.
  set -- $candidate
  IFS=$previous_ifs
  [ "$#" -eq 4 ] || return 1
  acceptance_is_canonical_ipv4_octet "$1" || return 1
  acceptance_is_canonical_ipv4_octet "$2" || return 1
  acceptance_is_canonical_ipv4_octet "$3" || return 1
  acceptance_is_canonical_ipv4_octet "$4" || return 1
  case "$1" in
    10) return 0 ;;
    172) [ "$2" -ge 16 ] && [ "$2" -le 31 ] ;;
    192) [ "$2" -eq 168 ] ;;
    *) return 1 ;;
  esac
}

acceptance_tcp_ready() {
  nc -z -w 2 "$1" "$2" >/dev/null 2>&1
}

acceptance_http_ready() {
  curl --fail --silent --max-time 3 "$1" >/dev/null 2>&1
}

case "${0##*/}" in
  acceptance-network.sh)
    [ "${1:-}" = "--validate-private-ip" ] && [ "$#" -eq 2 ] || exit 2
    acceptance_is_private_ipv4 "$2"
    ;;
esac
