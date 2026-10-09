#!/bin/zsh
set -euo pipefail

repo=""
output=""
while (( $# )); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) print -u2 -- "unexpected argument: $1"; exit 64 ;;
  esac
done
[[ -n "$repo" && -n "$output" ]]

if [[ -e "$output" && -n "$(command find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  print -u2 -- "refusing to overwrite non-empty preflight output: $output"
  exit 65
fi
mkdir -p "$output"

typeset -a security_command
if [[ -n "${PLAINPOST_SECURITY_COMMAND:-}" ]]; then
  security_command=("$PLAINPOST_SECURITY_COMMAND")
else
  security_command=(rtk security)
fi

rtk git -C "$repo" status --short >"$output/status.txt"
rtk git -C "$repo" worktree list --porcelain >"$output/worktrees.txt"
rtk git -C "$repo" remote -v >"$output/remotes.txt"
rtk git -C "$repo" ls-files >"$output/tracked-paths.txt"
"${security_command[@]}" default-keychain -d user >"$output/keychain-default.txt"
"${security_command[@]}" list-keychains -d user >"$output/keychain-search-list.txt"
