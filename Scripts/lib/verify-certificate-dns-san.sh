#!/bin/sh
set -eu

# `openssl x509 -ext` is not available in the LibreSSL shipped with some
# macOS/Xcode toolchains.  The human-readable `-text` representation is
# supported by both LibreSSL and OpenSSL; compare complete DNS tokens so a
# similarly-prefixed hostname cannot satisfy the check.
verify_certificate_dns_san() {
  certificate=$1
  hostname=$2
  openssl x509 -in "$certificate" -noout -text |
    awk -v expected="DNS:$hostname" '
      /^[[:space:]]*X509v3 Subject Alternative Name:/ {
        in_san=1
        next
      }
      in_san && /^[[:space:]]*X509v3 / {
        in_san=0
      }
      in_san {
        value=$0
        gsub(/,/, " ", value)
        count=split(value, fields, /[[:space:]]+/)
        for (field_index=1; field_index<=count; field_index++) {
          if (fields[field_index] == expected) {
            found=1
          }
        }
      }
      END { exit(found ? 0 : 1) }
    '
}

if [ "${0##*/}" = "verify-certificate-dns-san.sh" ]; then
  [ "$#" -eq 2 ] || {
    printf 'certificate SAN verifier: usage error\n' >&2
    exit 1
  }
  verify_certificate_dns_san "$1" "$2"
fi
