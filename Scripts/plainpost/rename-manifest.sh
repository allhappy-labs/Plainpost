#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' "usage: $0 --repo <absolute-canonical-path> --output <absolute-canonical-path> [--apply]" >&2
  exit 64
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

repo=""
output=""
apply=0
while (($#)); do
  case "$1" in
    --repo)
      (($# >= 2)) || usage
      repo="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || usage
      output="$2"
      shift 2
      ;;
    --apply)
      apply=1
      shift
      ;;
    *) usage ;;
  esac
done

[[ -n "$repo" && -n "$output" ]] || usage
[[ "$repo" == /* && "$repo" != / ]] || fail "repository path must be absolute"
canonical_repo="$(cd "$repo" && pwd -P)" || fail "repository path is not accessible"
[[ "$repo" == "$canonical_repo" ]] || fail "repository path must be canonical"
[[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || fail "repository path is not a Git checkout"
[[ "$(git -C "$repo" rev-parse --show-toplevel)" == "$canonical_repo" ]] || fail "repository path must be the Git top level"

[[ "$output" == /* && "$output" != / ]] || fail "output path must be absolute"
[[ "$output" != *//* && "$output" != */./* && "$output" != */../* && "$output" != */. && "$output" != */.. ]] || fail "output path must be canonical"
output_parent="${output%/*}"
output_name="${output##*/}"
[[ -n "$output_parent" && -n "$output_name" && "$output_parent" != "$output" ]] || fail "output path is invalid"
[[ "$output" != */.git/* && "$output" != */.git ]] || fail "output path cannot be inside Git metadata"
state_output="${output}.state"

retired_title="Epis""tyn"
retired_lower="epis""tyn"
retired_upper="EPIS""TYN"
replacement_title="Plainpost"
replacement_lower="plainpost"
replacement_upper="PLAINPOST"
retired_bundle="com.olhapi.$retired_title"
replacement_bundle="com.olhapi.$replacement_title"
from_tokens=("$retired_bundle" "$retired_title" "$retired_lower" "$retired_upper")
to_tokens=("$replacement_bundle" "$replacement_title" "$replacement_lower" "$replacement_upper")

has_excluded_component() {
  local path="$1"
  local component
  local -a components
  IFS=/ read -r -a components <<<"$path"
  for component in "${components[@]}"; do
    case "$component" in
      .git|.build|DerivedData|xcuserdata) return 0 ;;
    esac
  done
  return 1
}

reject_symlink_components() {
  local path="$1"
  local current="$repo"
  local component
  local -a components
  IFS=/ read -r -a components <<<"$path"
  for component in "${components[@]}"; do
    current="$current/$component"
    [[ ! -L "$current" ]] || fail "symlink path component is unsafe: $path"
  done
}

validate_destination_ancestors() {
  local path="$1"
  local current="$repo"
  local component
  local -a components
  IFS=/ read -r -a components <<<"$(dirname "$path")"
  for component in "${components[@]}"; do
    current="$current/$component"
    [[ ! -L "$current" ]] || fail "destination symlink component is unsafe: $path"
    if [[ -e "$current" ]]; then
      [[ -d "$current" ]] || fail "destination ancestor is not a directory: $path"
    fi
  done
}

transform() {
  local value="$1"
  local index
  for index in "${!from_tokens[@]}"; do
    value="${value//"${from_tokens[$index]}"/"${to_tokens[$index]}"}"
  done
  printf '%s' "$value"
}

is_utf8_text() {
  local file="$1"
  local kind
  [[ -s "$file" ]] || return 0
  kind="$(LC_ALL=C file -b -- "$file")" || fail "text detector failed: $file"
  if [[ "$kind" == *text* || "$kind" == *JSON* || "$kind" == *XML* ]]; then
    iconv -f UTF-8 -t UTF-8 "$file" >/dev/null || fail "text encoding detector failed: $file"
    return 0
  fi
  return 1
}

contains_token() {
  local file="$1"
  local token="$2"
  local status
  if LC_ALL=C grep -Fq -- "$token" "$file"; then
    return 0
  else
    status=$?
    (( status == 1 )) && return 1
    fail "text scan failed: $file"
  fi
}

write_state() {
  git -C "$repo" rev-parse HEAD
  git -C "$repo" ls-files -s
}

declare -A tracked=()
declare -A destinations=()
paths=()
tracked_listing="$(mktemp "${TMPDIR:-/tmp}/plainpost-tracked-paths.XXXXXX")"
if ! git -C "$repo" ls-files -z >"$tracked_listing"; then
  rm -f "$tracked_listing"
  fail "unable to enumerate tracked paths"
fi
while IFS= read -r -d '' path; do
  [[ "$path" != *$'\t'* && "$path" != *$'\n'* ]] || fail "tracked path cannot be represented in a TSV manifest"
  has_excluded_component "$path" && fail "excluded tracked path: $path"
  reject_symlink_components "$path"
  [[ -f "$repo/$path" && -r "$repo/$path" ]] || fail "tracked path is not a readable regular file: $path"
  tracked["$path"]=1
  paths+=("$path")
done <"$tracked_listing"
rm -f "$tracked_listing"

for path in "${paths[@]}"; do
  destination="$(transform "$path")"
  if [[ "$destination" != "$path" ]]; then
    has_excluded_component "$destination" && fail "excluded destination path: $destination"
    validate_destination_ancestors "$destination"
    [[ -z "${destinations[$destination]+x}" ]] || fail "duplicate destination: $destination"
    [[ -z "${tracked[$destination]+x}" ]] || fail "destination is already tracked: $destination"
    [[ ! -e "$repo/$destination" && ! -L "$repo/$destination" ]] || fail "destination already exists: $destination"
    destinations["$destination"]=1
  fi
done

plan="$(mktemp "${TMPDIR:-/tmp}/plainpost-rename-manifest.XXXXXX")"
state="$(mktemp "${TMPDIR:-/tmp}/plainpost-rename-state.XXXXXX")"
temporary_files=()
cleanup() {
  rm -f "$plan" "$state" "${temp_output:-}" "${temp_state_output:-}" "${temporary_files[@]}"
}
trap cleanup EXIT

for path in "${paths[@]}"; do
  destination="$(transform "$path")"
  [[ "$destination" == "$path" ]] || printf 'move\t%s\t%s\n' "$path" "$destination" >>"$plan"
done
for path in "${paths[@]}"; do
  file="$repo/$path"
  is_utf8_text "$file" || continue
  for index in "${!from_tokens[@]}"; do
    if contains_token "$file" "${from_tokens[$index]}"; then
      printf 'replace\t%s\t%s\t%s\n' "$path" "${from_tokens[$index]}" "${to_tokens[$index]}" >>"$plan"
    fi
  done
done

write_state >"$state"

if (( ! apply )); then
  mkdir -p "$output_parent"
  [[ ! -L "$output_parent" ]] || fail "output parent is a symlink"
  canonical_output_parent="$(cd "$output_parent" && pwd -P)"
  [[ "$output_parent" == "$canonical_output_parent" ]] || fail "output parent must be canonical"
  temp_output="$(mktemp "$output_parent/.plainpost-rename-manifest.XXXXXX")"
  temp_state_output="$(mktemp "$output_parent/.plainpost-rename-state.XXXXXX")"
  cat "$plan" >"$temp_output"
  cat "$state" >"$temp_state_output"
  mv -f "$temp_output" "$output"
  mv -f "$temp_state_output" "$state_output"
  temp_output=""
  temp_state_output=""
  exit 0
fi

[[ -f "$output" && -f "$state_output" ]] || fail "reviewed manifest and state are required before apply"
cmp -s "$plan" "$output" || fail "reviewed manifest does not match current plan"
cmp -s "$state" "$state_output" || fail "reviewed repository state does not match current state"
git -C "$repo" diff --quiet || fail "tracked worktree changes require a new reviewed manifest"
git -C "$repo" diff --cached --quiet || fail "staged changes require a new reviewed manifest"

for destination in "${!destinations[@]}"; do
  target_parent="$(dirname "$repo/$destination")"
  mkdir -p "$target_parent" || fail "unable to prepare destination parent: $destination"
  [[ -d "$target_parent" && ! -L "$target_parent" && -w "$target_parent" ]] || fail "destination parent is not writable: $destination"
done

replacement_sources=()
replacement_destinations=()
replacement_temps=()
for path in "${paths[@]}"; do
  file="$repo/$path"
  is_utf8_text "$file" || continue
  changed=0
  for index in "${!from_tokens[@]}"; do
    contains_token "$file" "${from_tokens[$index]}" && changed=1
  done
  (( changed )) || continue
  destination="$(transform "$path")"
  directory="$(dirname "$repo/$destination")"
  temporary="$(mktemp "$directory/.plainpost-replace.XXXXXX")" || fail "unable to prepare replacement: $path"
  temporary_files+=("$temporary")
  cp -p "$file" "$temporary" || fail "unable to prepare replacement: $path"
  for index in "${!from_tokens[@]}"; do
    FROM_TOKEN="${from_tokens[$index]}" TO_TOKEN="${to_tokens[$index]}" perl -0pi -e 's/\Q$ENV{FROM_TOKEN}\E/$ENV{TO_TOKEN}/g' "$temporary" || fail "unable to prepare replacement: $path"
  done
  replacement_sources+=("$path")
  replacement_destinations+=("$destination")
  replacement_temps+=("$temporary")
done

while IFS=$'\t' read -r kind source destination; do
  [[ "$kind" == move ]] || continue
  depth="${source//[^\/]/}"
  printf '%08d\t%s\t%s\n' "${#depth}" "$source" "$destination"
done <"$plan" | sort -rn | while IFS=$'\t' read -r _ source destination; do
  [[ ! -e "$repo/$destination" && ! -L "$repo/$destination" ]] || fail "destination changed before apply: $destination"
  mkdir -p "$(dirname "$repo/$destination")"
  git -C "$repo" mv -- "$source" "$destination"
done

for index in "${!replacement_temps[@]}"; do
  mv -f "${replacement_temps[$index]}" "$repo/${replacement_destinations[$index]}" || fail "unable to install replacement: ${replacement_sources[$index]}"
  temporary_files[$index]=""
done
