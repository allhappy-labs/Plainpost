#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exercise="$root/Deploy/sync-node/scripts/exercise-unraid-native-tls.sh"
verifier="$root/Deploy/sync-node/scripts/verify-release.sh"
loader="$root/Deploy/sync-node/scripts/load-oci-archive-to-local-registry.sh"
secret_ownership_helper="$root/Scripts/lib/prepare-container-secret-ownership.sh"
notification_fixture_helper="$root/Scripts/lib/prepare-native-tls-notification-fixture.sh"
postgres_ownership_image='postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'
release_dir=${1:-${PLAINPOST_RELEASE_DIR:-}}
die() { printf 'native TLS release acceptance: %s\n' "$*" >&2; exit 1; }
blocked() { printf 'native TLS release acceptance blocked prerequisite: %s\n' "$*" >&2; exit 75; }

[[ $# -le 1 ]] || die 'usage: test-sync-node-native-tls-release.sh <absolute-verified-release-directory>'
[[ -n $release_dir && $release_dir == /* && $release_dir != *'/../'* && $release_dir != */.. && $release_dir != *'/./'* ]] || die 'release directory must be normalized absolute path'
[[ -d $release_dir && ! -L $release_dir ]] || die 'release directory is unavailable'
[[ -x $exercise && -x $verifier && -x $loader && -x $secret_ownership_helper && -x $notification_fixture_helper ]] || die 'native TLS release assets are unavailable'
command -v jq >/dev/null || blocked 'jq is unavailable'

secret_ownership_validation_mode=exact
if [[ $(uname -s) == Darwin ]]; then
  secret_ownership_validation_mode=local-virtualized
fi

# Verify before allocating or importing any release image.
bash "$verifier" "$release_dir" >/dev/null || die 'release artifacts failed verification'
central_digest=$(jq -er '.images.api.runnable_manifest_sha256' "$release_dir/release-manifest.json") || die 'Central release digest is unavailable'
node_digest=$(jq -er '.images.sync_node.runnable_manifest_sha256' "$release_dir/release-manifest.json") || die 'Node release digest is unavailable'
[[ $central_digest =~ ^[0-9a-f]{64}$ && $node_digest =~ ^[0-9a-f]{64}$ ]] || die 'release image digests are malformed'

tailscale_ip=${PLAINPOST_NATIVE_TLS_TAILSCALE_IPV4:-}
tailscale_hostname=${PLAINPOST_NATIVE_TLS_TAILSCALE_HOSTNAME:-}
[[ $tailscale_ip =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+$ ]] || blocked 'set the already-assigned Tailscale IPv4'
[[ $tailscale_hostname =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\.ts\.net$ ]] || blocked 'set the lowercase Tailscale MagicDNS hostname'
command -v docker >/dev/null || blocked 'Docker is unavailable'

fixture_root=$(mktemp -d /private/tmp/plainpost-native-tls-fixture.XXXXXX) || die 'cannot create release fixture root'
fixture_root=$(CDPATH= cd -P -- "$fixture_root" && pwd -P)
chmod 0700 "$fixture_root"
loader_workspace=''
cleanup_status=0
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [[ -n ${loader_workspace:-} && -f $loader_workspace/oci-registry.env ]]; then
    loader_container=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_REGISTRY_CONTAINER" {print substr($0,index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    loader_network=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_REGISTRY_NETWORK" {print substr($0,index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    loader_central=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_CENTRAL_LOCAL_IMAGE" {print substr($0,index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    loader_node=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_NODE_LOCAL_IMAGE" {print substr($0,index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    [[ -z $loader_central ]] || docker image rm --force "$loader_central" >/dev/null 2>&1 || cleanup_status=1
    [[ -z $loader_node ]] || docker image rm --force "$loader_node" >/dev/null 2>&1 || cleanup_status=1
    [[ -z $loader_container ]] || docker rm --force --volumes "$loader_container" >/dev/null 2>&1 || cleanup_status=1
    [[ -z $loader_network ]] || docker network rm "$loader_network" >/dev/null 2>&1 || cleanup_status=1
  fi
  [[ -z ${loader_workspace:-} || ! -e $loader_workspace ]] || find "$loader_workspace" -depth -delete >/dev/null 2>&1 || cleanup_status=1
  [[ -z ${loader_workspace:-} || ! -e $loader_workspace ]] || cleanup_status=1
  [[ ! -e "$fixture_root" ]] || find "$fixture_root" -depth -delete >/dev/null 2>&1 || cleanup_status=1
  [[ ! -e "$fixture_root" ]] || cleanup_status=1
  if [[ $status -eq 0 && $cleanup_status -eq 0 ]]; then
    printf 'stage=cleanup\n'
  elif [[ $status -eq 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

# Build the complete disposable fixture from repository-owned inputs. The
# caller supplies only one verified release directory and the already-assigned
# local Tailscale identity; no template or pre-imported image references are
# accepted.
mkdir -m 0700 "$fixture_root/bundle" "$fixture_root/bundle/postgres" "$fixture_root/bundle/postgres/init" \
  "$fixture_root/secrets" "$fixture_root/public" "$fixture_root/postgres-data" \
  "$fixture_root/node-data" "$fixture_root/node-attachments" "$fixture_root/backups" "$fixture_root/receipts" \
  "$fixture_root/artifacts"
chmod 0700 "$fixture_root/postgres-data" "$fixture_root/node-data" "$fixture_root/node-attachments" "$fixture_root/backups" "$fixture_root/receipts"
cp -R -- "$root/Deploy/sync-node/postgres/init/." "$fixture_root/bundle/postgres/init/"

# Acceptance artifacts are generated from the checked-in fixtures, then split
# into public trust material and individual private mode-0600 leaves.
clock=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
(cd "$root/Services/PlainpostGo" && go run ./cmd/plainpost-acceptance-artifacts \
  -output "$fixture_root/artifacts" -fixtures "$root/Protocol/account-v1/fixtures" -clock "$clock")
cp -- "$fixture_root/artifacts/account-root-public.txt" "$fixture_root/public/account-offline-root.pub"
cp -- "$fixture_root/artifacts/account-manifest.json" "$fixture_root/public/account-manifest.json"
cp -- "$fixture_root/artifacts/session-root-public.txt" "$fixture_root/public/session-offline-root.pub"
cp -- "$fixture_root/artifacts/session-manifest.json" "$fixture_root/public/session-manifest.json"
cp -- "$fixture_root/artifacts/account-bootstrap-ring.json" "$fixture_root/secrets/account-online-keys.json"
cp -- "$fixture_root/artifacts/account-pagination-ring.json" "$fixture_root/secrets/account-pagination-keys.json"
cp -- "$fixture_root/artifacts/account-recovery-ring.json" "$fixture_root/secrets/account-recovery-keys.json"
cp -- "$fixture_root/artifacts/session-access-ring.json" "$fixture_root/secrets/session-access-keys.json"
cp -- "$fixture_root/artifacts/session-offline-ring.json" "$fixture_root/secrets/session-offline-keys.json"
cp -- "$fixture_root/artifacts/node-enrollment-replay-ring.json" "$fixture_root/secrets/node-enrollment-replay-keys.json"
cp -- "$fixture_root/artifacts/identity-pepper" "$fixture_root/secrets/account-identity-pepper"
"$notification_fixture_helper" prepare "$fixture_root"

# This local release fixture never contacts APNs or Apple. These identifiers
# and authorities are disposable, production-shaped inputs used only to prove
# that the immutable Central image can start with notification validation on.
export PLAINPOST_NOTIFICATION_APNS_TEAM_ID=PLAINPOSTTEST
export PLAINPOST_NOTIFICATION_APNS_KEY_ID=TESTKEY001
export PLAINPOST_NOTIFICATION_APP_ATTEST_APP_ID=PLAINPOSTTEST.com.marynavdovenko.Plainpost.iOS
export PLAINPOST_NOTIFICATION_APP_ATTEST_BUNDLE_VERSION=1
export PLAINPOST_NOTIFICATION_APP_ATTEST_VALIDATION_CATEGORY=1

openssl rand -hex 24 >"$fixture_root/secrets/postgres-superuser-password"
openssl rand -hex 24 >"$fixture_root/secrets/central-db-password"
openssl rand -hex 24 >"$fixture_root/secrets/node-db-password"
openssl rand -hex 24 >"$fixture_root/secrets/backup-db-password"
openssl rand -hex 24 >"$fixture_root/secrets/restore-admin-db-password"
openssl rand -hex 24 >"$fixture_root/secrets/restore-stage-db-password"
openssl rand 32 >"$fixture_root/secrets/node-master-key"
openssl rand 32 >"$fixture_root/secrets/node-backup-key"
openssl rand 32 >"$fixture_root/secrets/central-rate-limit-pepper"
# Disposable Google Calendar Desktop-app client secret (single line, no newline).
printf '%s' "native-tls-fixture-calendar-secret-$(openssl rand -hex 16)" >"$fixture_root/secrets/node-google-calendar-oauth-client-secret"
for secret_file in "$fixture_root/secrets"/*; do chmod 0600 "$secret_file"; done

make_certificate() {
  local name=$1 hostname=$2
  local cert_path="$fixture_root/public/$name.crt" key_path="$fixture_root/secrets/$name.key"
  local csr="$fixture_root/$name.csr" extensions="$fixture_root/$name.extensions"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$hostname" \
    -keyout "$key_path" -out "$csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$hostname" >"$extensions"
  openssl x509 -req -days 1 -in "$csr" -CA "$fixture_root/public/postgres-ca.pem" \
    -CAkey "$fixture_root/secrets/postgres-ca.key" -CAcreateserial -extfile "$extensions" \
    -out "$cert_path" >/dev/null 2>&1
  chmod 0600 "$key_path"
  chmod 0444 "$cert_path"
}
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj '/CN=Plainpost native TLS release fixture CA' \
  -keyout "$fixture_root/secrets/postgres-ca.key" -out "$fixture_root/public/postgres-ca.pem" >/dev/null 2>&1
chmod 0600 "$fixture_root/secrets/postgres-ca.key"
chmod 0444 "$fixture_root/public/postgres-ca.pem"
make_certificate postgres postgres
make_certificate central-tls "$tailscale_hostname"
make_certificate node-tls "$tailscale_hostname"
mv -- "$fixture_root/public/postgres.crt" "$fixture_root/public/postgres-server.crt"
mv -- "$fixture_root/secrets/postgres.key" "$fixture_root/secrets/postgres-server.key"

printf 'postgres://postgres:%s@postgres:5432/postgres?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem\n' \
  "$(<"$fixture_root/secrets/postgres-superuser-password")" >"$fixture_root/secrets/postgres-superuser-database-url"
printf 'postgres://plainpost_central:%s@postgres:5432/plainpost_central?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem&search_path=account\n' \
  "$(<"$fixture_root/secrets/central-db-password")" >"$fixture_root/secrets/central-database-url"
printf 'postgres://plainpost_central:%s@postgres:5432/plainpost_central?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem&search_path=deletion_journal\n' \
  "$(<"$fixture_root/secrets/central-db-password")" >"$fixture_root/secrets/central-deletion-journal-database-url"
printf 'postgres://plainpost_sync_node:%s@postgres:5432/plainpost_sync_node?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem\n' \
  "$(<"$fixture_root/secrets/node-db-password")" >"$fixture_root/secrets/node-database-url"
printf 'postgres://plainpost_restore_admin:%s@postgres:5432/postgres?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem\n' \
  "$(<"$fixture_root/secrets/restore-admin-db-password")" >"$fixture_root/secrets/node-restore-admin-database-url"
printf 'postgres://plainpost_restore_stage:%s@postgres:5432/plainpost_sync_node?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem\n' \
  "$(<"$fixture_root/secrets/restore-stage-db-password")" >"$fixture_root/secrets/node-restore-stage-database-url"
for secret_file in central-database-url central-deletion-journal-database-url node-database-url \
  node-restore-admin-database-url node-restore-stage-database-url; do chmod 0600 "$fixture_root/secrets/$secret_file"; done

bash "$secret_ownership_helper" "$fixture_root" "$postgres_ownership_image" native-release "$secret_ownership_validation_mode"

# The repository loader is the only image import authority. Bind both local
# references to the verified manifest before invoking the native TLS owner.
loader_workspace=$(mktemp -d /private/tmp/plainpost-native-tls-loader.XXXXXX)
loader_workspace=$(CDPATH= cd -P -- "$loader_workspace" && pwd -P)
bash "$loader" "$release_dir/plainpost-api.oci.tar" "$central_digest" \
  "$release_dir/plainpost-sync-node.oci.tar" "$node_digest" "$loader_workspace" "native-tls-loader-$$"
central_image=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_CENTRAL_LOCAL_IMAGE" {print substr($0,index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
node_image=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_NODE_LOCAL_IMAGE" {print substr($0,index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
[[ $central_image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ && $node_image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || die 'OCI loader returned mutable image reference'
[[ ${central_image##*@} == sha256:$central_digest && ${node_image##*@} == sha256:$node_digest ]] || die 'loaded images do not match release manifest'

export PLAINPOST_NATIVE_TLS_FIXTURE_ROOT="$fixture_root"
export PLAINPOST_NATIVE_TLS_CENTRAL_IMAGE="$central_image"
export PLAINPOST_NATIVE_TLS_NODE_IMAGE="$node_image"
# This wrapper never requests a certificate or contacts Unraid. The existing
# exercise owns local Compose lifecycle and the TLS 1.3 health probe.
bash "$exercise" "$release_dir"
