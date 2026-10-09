#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
compose="$root/Deploy/acceptance/compose.release-images.yaml"
verifier="$root/Deploy/sync-node/scripts/verify-release.sh"
loader="$root/Deploy/sync-node/scripts/load-oci-archive-to-local-registry.sh"
failure_summary_helper="$root/Scripts/lib/release-image-failure-summary.sh"
release_override_writer="$root/Scripts/lib/write-release-private-transport-override.sh"
release_dir=${1:-${PLAINPOST_RELEASE_DIR:-}}
die() { printf 'release-image acceptance: %s\n' "$*" >&2; exit 1; }
blocked() { printf 'release-image acceptance blocked prerequisite: %s\n' "$*" >&2; exit 75; }

[[ $# -le 1 ]] || die 'usage: test-sync-node-release-images.sh <absolute-verified-release-directory>'
[[ -n $release_dir && $release_dir == /* && $release_dir != *'/../'* && $release_dir != */.. && $release_dir != *'/./'* ]] || die 'release directory must be a normalized absolute path'
[[ -d $release_dir && ! -L $release_dir ]] || die 'release directory is unavailable'
[[ $(CDPATH= cd -P -- "$release_dir" && pwd -P) == "$release_dir" ]] || die 'release directory traverses a symlink'
[[ -f $compose && -x $verifier && -x $loader && -x $failure_summary_helper && -x $release_override_writer ]] || die 'release-image owner assets are unavailable'
command -v jq >/dev/null || blocked 'jq is unavailable'
command -v docker >/dev/null || blocked 'Docker is unavailable'

secret_ownership_validation_mode=exact
if [[ $(uname -s) == Darwin ]]; then
  secret_ownership_validation_mode=local-virtualized
fi

# Verification is deliberately the first release operation. No archive is
# loaded and no Compose project is started until the offline verifier accepts
# the complete release directory and its source-bound evidence.
# The primary database owner is PostgreSQL 18 (`postgres:18`), never a mutable
# or older-major server.
bash "$verifier" "$release_dir" >/dev/null || die 'release artifacts failed verification'
manifest="$release_dir/release-manifest.json"
central_digest=$(jq -er '.images.api.runnable_manifest_sha256' "$manifest") || die 'Central runnable digest is unavailable'
node_digest=$(jq -er '.images.sync_node.runnable_manifest_sha256' "$manifest") || die 'Sync Node runnable digest is unavailable'
[[ $central_digest =~ ^[0-9a-f]{64}$ && $node_digest =~ ^[0-9a-f]{64}$ ]] || die 'release runnable digests are malformed'

# The probe binary is compiled from the checked-out source, so bind it to the
# exact source evidence that the release verifier accepted before compiling.
# Keep these assertions here as well as in verify-release.sh: an implementation
# change must never be tested against an older packaged release by accident.
release_source_commit=$(jq -er '.source.commit' "$manifest") || die 'release source commit is unavailable'
release_source_tree_sha256=$(jq -er '.source.tree_sha256' "$manifest") || die 'release source tree evidence is unavailable'
[[ $release_source_commit =~ ^[0-9a-f]{40}$ ]] || die 'release source commit is malformed'
[[ $release_source_tree_sha256 =~ ^[0-9a-f]{64}$ ]] || die 'release source tree evidence is malformed'
[[ $(git -C "$root" rev-parse HEAD) == "$release_source_commit" ]] || die 'probe source commit differs from release manifest'
[[ -z $(git -C "$root" status --porcelain=v1 --untracked-files=all) ]] || die 'probe source worktree is not clean'
probe_source_tree_sha256=$(git -C "$root" archive --format=tar "$release_source_commit" | shasum -a 256 | awk '{print $1}')
[[ $probe_source_tree_sha256 == "$release_source_tree_sha256" ]] || die 'probe source tree differs from release manifest'

fixture_root=$(mktemp -d /private/tmp/plainpost-release-images.XXXXXX) || die 'cannot create release fixture root'
fixture_root=$(CDPATH= cd -P -- "$fixture_root" && pwd -P)
chmod 0700 "$fixture_root"
project="plainpost-release-images-${RANDOM}${RANDOM}"
loader_workspace=''
cleanup_status=0
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [[ -n $loader_workspace && -f $loader_workspace/oci-registry.env ]]; then
    loader_container=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_REGISTRY_CONTAINER" {print substr($0, index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    loader_network=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_REGISTRY_NETWORK" {print substr($0, index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    loader_central=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_CENTRAL_LOCAL_IMAGE" {print substr($0, index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    loader_node=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_NODE_LOCAL_IMAGE" {print substr($0, index($0,"=")+1)}' "$loader_workspace/oci-registry.env")
    [[ -z $loader_central ]] || docker image rm --force "$loader_central" >/dev/null 2>&1 || cleanup_status=1
    [[ -z $loader_node ]] || docker image rm --force "$loader_node" >/dev/null 2>&1 || cleanup_status=1
    [[ -z $loader_container ]] || docker rm --force --volumes "$loader_container" >/dev/null 2>&1 || cleanup_status=1
    [[ -z $loader_network ]] || docker network rm "$loader_network" >/dev/null 2>&1 || cleanup_status=1
  fi
  [[ -z $loader_workspace || ! -e $loader_workspace ]] || find "$loader_workspace" -depth -delete >/dev/null 2>&1 || cleanup_status=1
  [[ -z $loader_workspace || ! -e $loader_workspace ]] || cleanup_status=1
  [[ ! -e $fixture_root ]] || find "$fixture_root" -depth -delete >/dev/null 2>&1 || cleanup_status=1
  [[ ! -e $fixture_root ]] || cleanup_status=1
  if [[ $status -eq 0 && $cleanup_status -eq 0 ]]; then
    printf 'stage=cleanup\n'
  elif [[ $status -eq 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
loader_workspace=$(mktemp -d /private/tmp/plainpost-native-tls.XXXXXX) || die 'cannot create OCI loader workspace'
loader_workspace=$(CDPATH= cd -P -- "$loader_workspace" && pwd -P)
stage_log="$fixture_root/stages.log"

# The OCI helper is the only archive loader. It checks that each imported
# runnable manifest digest is exactly the digest verified above; Compose then
# uses --pull never and cannot replace either image.
bash "$loader" "$release_dir/plainpost-api.oci.tar" "$central_digest" \
  "$release_dir/plainpost-sync-node.oci.tar" "$node_digest" "$loader_workspace" "$project-loader"
loader_env="$loader_workspace/oci-registry.env"
[[ -f $loader_env ]] || die 'OCI loader did not return image references'
central_image=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_CENTRAL_LOCAL_IMAGE" {print substr($0, index($0,"=")+1)}' "$loader_env")
node_image=$(awk -F= '$1 == "PLAINPOST_NATIVE_TLS_NODE_LOCAL_IMAGE" {print substr($0, index($0,"=")+1)}' "$loader_env")
[[ $central_image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ && $node_image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || die 'OCI loader returned mutable image reference'
[[ ${central_image##*@} == sha256:$central_digest && ${node_image##*@} == sha256:$node_digest ]] || die 'loaded image digests differ from release manifest'

# The existing private-transport owner remains the behavioral authority. This
# reset-only Compose override removes its source binary mounts and replaces
# only the Central/Node images with the already digest-checked release images;
# all generated TLS, artifact, database, fixture, and control mounts remain
# owned by the repository-owned private-transport owner.
release_override="$fixture_root/private-transport.release.override.yaml"
bash "$release_override_writer" "$release_override"

printf 'stage=images-loaded\n' >>"$stage_log"

# These probes execute inside the selected final Node image. The exact
# PostgreSQL 18 pg_dump --version and pg_restore --version commands are run
# below. Source Dockerfile
# inspection cannot establish that the packaged PostgreSQL 18 tools run.
dump_version=$(docker run --rm --pull never --entrypoint /usr/bin/pg_dump "$node_image" --version) || die 'packaged pg_dump cannot execute'
restore_version=$(docker run --rm --pull never --entrypoint /usr/bin/pg_restore "$node_image" --version) || die 'packaged pg_restore cannot execute'
[[ $dump_version == 'pg_dump (PostgreSQL) 18.'* && $restore_version == 'pg_restore (PostgreSQL) 18.'* ]] || die 'release image does not execute PostgreSQL 18 tools'
printf 'stage=postgres-tools\n' >>"$stage_log"

# Exercise the packaged filesystem adapter against the exact restored-root
# topology that production uses: the disposable host directory is bind
# mounted at /node-data, and the test creates restore-stages/<id> below it.
# Prepare the disposable bind root with the packaged runtime identity. The
# source-bound probe binary performs this one-time chown in the final image as
# root; the actual filesystem assertion then runs as the required user. This
# avoids introducing a mutable helper image into the release gate.
attachment_mount_test_binary="$fixture_root/plainpost-attachment-filesystem-test"
attachment_mount_root="$fixture_root/attachment-mount-root"
mkdir -m 0700 "$attachment_mount_root"
if ! (cd "$root/Services/PlainpostGo" &&
  GOCACHE="$fixture_root/go-cache" CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go test -c -trimpath -o "$attachment_mount_test_binary" ./internal/node/attachment); then
  die 'could not compile packaged attachment filesystem probe'
fi
docker run --rm --pull never --user 0:0 \
  --entrypoint /plainpost-attachment-filesystem-test \
  -e TEST_ATTACHMENT_FILESYSTEM_ROOT=/node-data \
  -e PLAINPOST_PREPARE_ATTACHMENT_FILESYSTEM_ROOT=65532:65532 \
  -v "$attachment_mount_root:/node-data:rw" \
  -v "$attachment_mount_test_binary:/plainpost-attachment-filesystem-test:ro" \
  "$node_image" \
  -test.run '^TestFilesystemPrepareMountedRootOwnership$' -test.v -test.timeout=30s \
  || die 'could not prepare packaged attachment probe root ownership'
docker run --rm --pull never --user 65532:65532 \
  --entrypoint /plainpost-attachment-filesystem-test \
  -e TEST_ATTACHMENT_FILESYSTEM_ROOT=/node-data \
  -v "$attachment_mount_root:/node-data:rw" \
  -v "$attachment_mount_test_binary:/plainpost-attachment-filesystem-test:ro" \
  "$node_image" \
  -test.run '^TestFilesystemRelativeRootMountedDataChild$' -test.v -test.timeout=30s \
  || die 'packaged attachment filesystem restored-root probe failed'
printf 'stage=attachment-mount\n' >>"$stage_log"

# Drive the existing behavioral owner against this exact loaded release pair.
# Its scenario owns enrollment, generic IMAP/SMTP, restart, backup/restore,
# replacement fencing, notifications, erase, and privacy evidence; this
# adapter only supplies the immutable-image Compose reset and never duplicates
# the scenario or self-attests stage results. Its closed stage vocabulary is
# The behavioral owner executes SHOW server_version_num and checks the live
# Central/Sync Node databases (plainpost_central and plainpost_sync_node) and
# replacement label before serving traffic.
# tls-readiness, native-enrollment, local-mail-sync, client-api-content,
# client-api-mutations, restart-recovery, backup-restore, replacement-fence,
# notification, erase, privacy-network.
private_owner_log="$fixture_root/private-transport.log"
# The repository-owned private-transport owner creates and consumes the
# complete disposable fixture tree; this release adapter supplies only the
# verified image selectors and reset-only Compose override.
. "$failure_summary_helper"
summarize_private_owner_failure() {
  release_image_failure_summary "$private_owner_log" >&2
}
PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE=1 \
PLAINPOST_SYNC_NODE_RELEASE_CENTRAL_IMAGE="$central_image" \
PLAINPOST_SYNC_NODE_RELEASE_NODE_IMAGE="$node_image" \
PLAINPOST_SYNC_NODE_RELEASE_COMPOSE_OVERRIDE="$release_override" \
PLAINPOST_SYNC_NODE_BOOTSTRAP_PROVISIONER="$release_dir/provision-owner-bootstrap.py" \
PLAINPOST_SECRET_OWNERSHIP_VALIDATION_MODE="$secret_ownership_validation_mode" \
PLAINPOST_SECRET_OWNERSHIP_RELEASE_ADAPTER=release-images-darwin \
PLAINPOST_SYNC_NODE_CLIENT_API=enabled \
PLAINPOST_SYNC_NODE_ACCEPTANCE_DROP_RESPONSES=status \
bash "$root/Scripts/test-sync-node-private-transport.sh" >"$private_owner_log" 2>&1 || {
  summarize_private_owner_failure
  die 'release-image private-transport acceptance failed'
}
grep -F 'release-traffic=swift-client status=passed' "$private_owner_log" >/dev/null || die 'release acceptance did not prove Swift traffic'
grep -F 'release-backup-restore status=passed' "$private_owner_log" >/dev/null || die 'release acceptance did not prove backup/restore runtime evidence'
grep -F 'stage=privacy-audit' "$private_owner_log" >/dev/null || die 'release acceptance did not prove privacy audit'
