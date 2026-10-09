#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
  echo "usage: $0 ABSOLUTE_PRIVATE_DIRECTORY ABSOLUTE_ACCOUNT_PUBLIC_DIRECTORY ABSOLUTE_SESSION_PUBLIC_DIRECTORY EXPECTED_ACCOUNT_ROOT_SHA256 ABSOLUTE_SESSION_KEY_LOCATION" >&2
  exit 2
fi

private_directory=$1
account_public_directory=$2
session_public_directory=$3
expected_account_root_sha256=$4
session_key_location=$5
for path in "$private_directory" "$account_public_directory" "$session_public_directory" "$session_key_location"; do
  case "$path" in
    /*) ;;
    *) echo "authority paths must be absolute" >&2; exit 2 ;;
  esac
done

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root/Services/PlainpostGo"
export GOPROXY=off
export GOSUMDB=off
exec go run ./cmd/plainpost-verify-key-authority \
  --private-dir "$private_directory" \
  --account-public-dir "$account_public_directory" \
  --session-public-dir "$session_public_directory" \
  --expected-account-root-sha256 "$expected_account_root_sha256" \
  --session-key-location "$session_key_location"
