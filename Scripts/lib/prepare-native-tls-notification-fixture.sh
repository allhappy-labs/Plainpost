#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

die() { printf 'native TLS notification fixture: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || die 'usage: prepare-native-tls-notification-fixture.sh <prepare|verify> <absolute-fixture-root>'
mode=$1
root=$2
[[ $root == /* && $root != *'/../'* && $root != */.. && $root != *'/./'* && -d $root && ! -L $root ]] || die 'fixture root is unavailable'
[[ $(cd -P "$root" && pwd) == "$root" ]] || die 'fixture root traverses a symlink'

token_keyring="$root/secrets/central-notification-token-keyring"
apns_signing_key="$root/secrets/central-apns-signing-key.p8"
app_attest_roots="$root/public/apple-app-attest-roots.pem"

file_mode() {
  if [[ $(uname -s) == Darwin ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

file_links() {
  if [[ $(uname -s) == Darwin ]]; then
    stat -f '%l' "$1"
  else
    stat -c '%h' "$1"
  fi
}

verify_file() {
  local path=$1 expected_mode=$2
  [[ -f $path && ! -L $path ]] || die 'required notification authority file is unavailable'
  [[ $(file_links "$path") == 1 ]] || die 'notification authority file has unexpected link count'
  [[ $(file_mode "$path") == "$expected_mode" ]] || die 'notification authority file mode is invalid'
}

verify_fixture() {
  verify_file "$token_keyring" 600
  verify_file "$apns_signing_key" 600
  verify_file "$app_attest_roots" 444

  local material encoded decoded_bytes
  material=$(<"$token_keyring")
  [[ $material =~ ^1:([A-Za-z0-9+/]{43})$ ]] || die 'notification token keyring shape is invalid'
  encoded=${BASH_REMATCH[1]}
  decoded_bytes=$(printf '%s=' "$encoded" | openssl base64 -d -A | wc -c | tr -d '[:space:]')
  [[ $decoded_bytes == 32 ]] || die 'notification token keyring length is invalid'

  openssl pkey -in "$apns_signing_key" -check -noout >/dev/null 2>&1 || die 'APNs signing key is invalid'
  openssl ec -in "$apns_signing_key" -text -noout 2>/dev/null | grep -Fq 'ASN1 OID: prime256v1' || die 'APNs signing key is not P-256'
  openssl x509 -in "$app_attest_roots" -noout >/dev/null 2>&1 || die 'App Attest test root is invalid'
  openssl x509 -in "$app_attest_roots" -text -noout 2>/dev/null | grep -Fq 'CA:TRUE' || die 'App Attest test root is not a CA'
  openssl verify -CAfile "$app_attest_roots" "$app_attest_roots" >/dev/null 2>&1 || die 'App Attest test root is not self-verifying'
}

case $mode in
verify)
  verify_fixture
  ;;
prepare)
  [[ -d $root/secrets && ! -L $root/secrets && -d $root/public && ! -L $root/public ]] || die 'fixture authority directories are unavailable'
  for path in "$token_keyring" "$apns_signing_key" "$app_attest_roots"; do
    [[ ! -e $path && ! -L $path ]] || die 'notification authority output already exists'
  done
  workspace=$(mktemp -d "$root/.notification-authority.XXXXXX") || die 'cannot create notification authority workspace'
  cleanup_workspace() {
    find "$workspace" -depth -delete >/dev/null 2>&1 || :
  }
  trap cleanup_workspace EXIT HUP INT TERM
  mkdir -m 0700 "$workspace/secrets" "$workspace/public"

  encoded=$(openssl rand -base64 32 | tr -d '=\n')
  [[ $encoded =~ ^[A-Za-z0-9+/]{43}$ ]] || die 'cannot generate notification token keyring'
  printf '1:%s\n' "$encoded" >"$workspace/secrets/central-notification-token-keyring"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out "$workspace/secrets/central-apns-signing-key.p8" >/dev/null 2>&1
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 1 \
    -subj '/CN=Plainpost App Attest native TLS test root' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign,digitalSignature' \
    -keyout "$workspace/app-attest-root.key" \
    -out "$workspace/public/apple-app-attest-roots.pem" >/dev/null 2>&1
  chmod 0600 "$workspace/secrets/central-notification-token-keyring" "$workspace/secrets/central-apns-signing-key.p8"
  chmod 0444 "$workspace/public/apple-app-attest-roots.pem"
  mv "$workspace/secrets/central-notification-token-keyring" "$token_keyring"
  mv "$workspace/secrets/central-apns-signing-key.p8" "$apns_signing_key"
  mv "$workspace/public/apple-app-attest-roots.pem" "$app_attest_roots"
  verify_fixture
  ;;
*)
  die 'mode must be prepare or verify'
  ;;
esac
