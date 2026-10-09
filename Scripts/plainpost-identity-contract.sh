#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' "usage: $0 [--allow <tracked-migration-document>]" >&2
  exit 64
}

retired_title="Epis""tyn"
retired_lower="epis""tyn"
retired_upper="EPIS""TYN"
native_host_name="com.marynavdovenko.plainpost.browser"
invalid_native_host="com.marynavdovenko.Plain""post.browser"
allowed_paths=()

while (($#)); do
  case "$1" in
    --allow)
      (($# >= 2)) || usage
      allowed_paths+=("$2")
      shift 2
      ;;
    *) usage ;;
  esac
done

test -d Plainpost.xcodeproj
test -d Apps/PlainpostiOS
test -d Apps/PlainpostBrowserExtension
test -d Sources/PlainpostCore
test -d Sources/plainpost
test -d Tests/PlainpostCoreTests
test -d Support/PlainpostApp
test -d Support/PlainpostBackgroundAgent
rtk swift package describe | rtk rg -q '^Name: Plainpost$'
rtk swift package describe | rtk rg -q 'PlainpostService'
rtk swift package describe | rtk rg -q 'plainpost'
rtk rg -q 'PRODUCT_BUNDLE_IDENTIFIER = com\.marynavdovenko\.Plainpost;' Plainpost.xcodeproj/project.pbxproj
rtk rg -q 'PRODUCT_BUNDLE_IDENTIFIER = com\.marynavdovenko\.Plainpost\.iOS;' Apps/PlainpostiOS/Plainpost.xcodeproj/project.pbxproj
[[ "$native_host_name" =~ ^[a-z0-9_]+(\.[a-z0-9_]+)*$ ]]
rtk grep -Fq -- "connectNative('$native_host_name')" Apps/PlainpostBrowserExtension/entrypoints/background.ts
rtk grep -Fq -- "public static let hostName = \"$native_host_name\"" Sources/PlainpostBrowserIntegration/BrowserNativeHostInstaller.swift

is_allowed() {
  local path="$1"
  local allowed
  for allowed in "${allowed_paths[@]}"; do
    [[ "$allowed" == "$path" ]] && return 0
  done
  return 1
}

declare -A tracked_paths=()
tracked_listing="$(mktemp "${TMPDIR:-/tmp}/plainpost-tracked-paths.XXXXXX")"
if ! git ls-files -z >"$tracked_listing"; then
  rm -f "$tracked_listing"
  printf 'unable to enumerate tracked paths\n' >&2
  exit 1
fi
while IFS= read -r -d '' path; do
  tracked_paths["$path"]=1
done <"$tracked_listing"
rm -f "$tracked_listing"

for allowed in "${allowed_paths[@]}"; do
  [[ -n "${tracked_paths[$allowed]+x}" ]] || {
    printf 'allowed path is not tracked: %s\n' "$allowed" >&2
    exit 1
  }
done

for path in "${!tracked_paths[@]}"; do
  if is_allowed "$path"; then
    continue
  fi
  if [[ -f "$path" && -r "$path" ]] &&
     LC_ALL=C rtk grep -Fq -- "$invalid_native_host" "$path"; then
    printf 'invalid uppercase native host identity in tracked text: %s\n' "$path" >&2
    exit 1
  fi
  for token in "$retired_title" "$retired_lower" "$retired_upper"; do
    if [[ "$path" == *"$token"* ]]; then
      printf 'retired identity in tracked path: %s\n' "$path" >&2
      exit 1
    fi
    [[ -f "$path" && -r "$path" ]] || {
      printf 'unreadable tracked file: %s\n' "$path" >&2
      exit 1
    }
    if LC_ALL=C rtk grep -Fq -- "$token" "$path"; then
      printf 'retired identity in tracked text: %s\n' "$path" >&2
      exit 1
    else
      scan_status=$?
      (( scan_status == 1 )) || {
        printf 'tracked text scan failed: %s\n' "$path" >&2
        exit 1
      }
    fi
  done
done
