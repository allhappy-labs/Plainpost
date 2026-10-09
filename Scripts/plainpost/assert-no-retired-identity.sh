#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' "usage: $0 [--allow <tracked-path>] [--artifact <path>]" >&2
  exit 64
}

retired_title="Epis""tyn"
retired_lower="epis""tyn"
retired_upper="EPIS""TYN"
allowed_paths=()
artifacts=()
while (($#)); do
  case "$1" in
    --allow)
      (($# >= 2)) || usage
      allowed_paths+=("$2")
      shift 2
      ;;
    --artifact)
      (($# >= 2)) || usage
      artifacts+=("$2")
      shift 2
      ;;
    *) usage ;;
  esac
done

is_allowed() {
  local path="$1"
  local allowed
  for allowed in "${allowed_paths[@]}"; do
    [[ "$allowed" == "$path" ]] && return 0
  done
  return 1
}

assert_value_is_clean() {
  local value="$1"
  local context="$2"
  local token
  for token in "$retired_title" "$retired_lower" "$retired_upper"; do
    [[ "$value" != *"$token"* ]] || {
      printf 'retired identity in %s\n' "$context" >&2
      exit 1
    }
  done
}

assert_file_is_clean() {
  local file="$1"
  local context="$2"
  local token
  local status
  [[ -f "$file" && -r "$file" ]] || {
    printf 'unreadable regular file in %s\n' "$context" >&2
    exit 1
  }
  for token in "$retired_title" "$retired_lower" "$retired_upper"; do
    if LC_ALL=C grep -Fq -- "$token" "$file"; then
      printf 'retired identity in %s\n' "$context" >&2
      exit 1
    else
      status=$?
      (( status == 1 )) || {
        printf 'scan failed for %s\n' "$context" >&2
        exit 1
      }
    fi
  done
}

declare -A tracked=()
tracked_listing="$(mktemp "${TMPDIR:-/tmp}/plainpost-tracked-paths.XXXXXX")"
if ! git ls-files -z >"$tracked_listing"; then
  rm -f "$tracked_listing"
  printf 'unable to enumerate tracked paths\n' >&2
  exit 1
fi
while IFS= read -r -d '' path; do
  tracked["$path"]=1
done <"$tracked_listing"
rm -f "$tracked_listing"
for allowed in "${allowed_paths[@]}"; do
  [[ -n "${tracked[$allowed]+x}" ]] || {
    printf 'allowed path is not tracked: %s\n' "$allowed" >&2
    exit 1
  }
done
for path in "${!tracked[@]}"; do
  is_allowed "$path" && continue
  assert_value_is_clean "$path" "tracked path: $path"
  assert_file_is_clean "$path" "tracked text: $path"
done

for artifact in "${artifacts[@]}"; do
  [[ -e "$artifact" && ! -L "$artifact" ]] || {
    printf 'artifact does not exist: %s\n' "$artifact" >&2
    exit 1
  }
  listing="$(mktemp "${TMPDIR:-/tmp}/plainpost-artifact-list.XXXXXX")"
  if ! find -P "$artifact" -print0 >"$listing"; then
    rm -f "$listing"
    printf 'artifact traversal failed: %s\n' "$artifact" >&2
    exit 1
  fi
  while IFS= read -r -d '' entry; do
    assert_value_is_clean "$entry" "artifact path: $entry"
    [[ ! -L "$entry" ]] || {
      rm -f "$listing"
      printf 'artifact symlink is unsafe: %s\n' "$entry" >&2
      exit 1
    }
    if [[ -d "$entry" ]]; then
      [[ -r "$entry" && -x "$entry" ]] || {
        rm -f "$listing"
        printf 'artifact directory is unreadable: %s\n' "$entry" >&2
        exit 1
      }
    else
      assert_file_is_clean "$entry" "artifact text: $entry"
    fi
  done <"$listing"
  rm -f "$listing"
done
