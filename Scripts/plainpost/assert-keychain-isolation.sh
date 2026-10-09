#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

script_name="${0:A}"

usage() {
  print -u2 -- \
    "usage: $script_name before|after <snapshot-directory>"
  print -u2 -- \
    "       $script_name run <snapshot-directory> -- <command> [arguments...]"
  exit 64
}

(( $# >= 2 )) || usage
phase="$1"
snapshot_directory="$2"
typeset -a guarded_command

case "$phase" in
  before|after)
    (( $# == 2 )) || usage
    ;;
  run)
    (( $# >= 4 )) || usage
    [[ "$3" == "--" ]] || usage
    guarded_command=("${@:4}")
    ;;
  *) usage ;;
esac

typeset -a security_command
if [[ -n "${PLAINPOST_SECURITY_COMMAND:-}" ]]; then
  security_command=("$PLAINPOST_SECURITY_COMMAND")
else
  security_command=(rtk security)
fi

typeset -a item_count_command
if [[ -n "${PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND:-}" ]]; then
  item_count_command=("$PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND")
fi

typeset -a fingerprint_command
if [[ -n "${PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND:-}" ]]; then
  fingerprint_command=("$PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND")
fi

typeset -a file_read_command
if [[ -n "${PLAINPOST_KEYCHAIN_FILE_READ_COMMAND:-}" ]]; then
  file_read_command=("$PLAINPOST_KEYCHAIN_FILE_READ_COMMAND")
fi

typeset -a stat_command
if [[ -n "${PLAINPOST_KEYCHAIN_STAT_COMMAND:-}" ]]; then
  stat_command=("$PLAINPOST_KEYCHAIN_STAT_COMMAND")
fi

typeset -a before_reserve_command
if [[ -n "${PLAINPOST_KEYCHAIN_GUARD_BEFORE_RESERVE_COMMAND:-}" ]]; then
  before_reserve_command=("$PLAINPOST_KEYCHAIN_GUARD_BEFORE_RESERVE_COMMAND")
fi

escaped_path_for_error() {
  print -r -- "${(q)1}"
}

resolve_default_keychain() {
  local raw_keychain="$1"
  local raw_parent
  local canonical_keychain
  local canonical_parent
  local canonical_home

  [[ -n "$raw_keychain" && "$raw_keychain" == /* && "$raw_keychain" != / ]] || {
    print -u2 -- "unsafe default Keychain path"
    return 1
  }
  raw_parent="${raw_keychain:h}"
  [[ "$raw_parent" != / && "$raw_parent" != "$HOME" && -d "$raw_parent" && -f "$raw_keychain" ]] || {
    print -u2 -- "unsafe default Keychain parent"
    return 1
  }

  canonical_keychain="${raw_keychain:A}"
  canonical_parent="${raw_parent:A}"
  canonical_home="${HOME:A}"
  [[ "$canonical_keychain" != / && "$canonical_keychain" != "$canonical_home" && "$canonical_parent" != / && "$canonical_parent" != "$canonical_home" ]] || {
    print -u2 -- "unsafe canonical default Keychain path"
    return 1
  }
  [[ "${canonical_keychain:h}" == "$canonical_parent" ]] || {
    print -u2 -- "default Keychain symlink escapes its parent"
    return 1
  }
  print -r -- "$canonical_keychain"
}

count_generic_password_items() {
  local keychain="$1"
  local service="$2"
  local count

  if (( ${#item_count_command[@]} )); then
    count="$("${item_count_command[@]}" "$keychain" "$service")" || {
      print -u2 -- "unable to count Keychain items for service: $service"
      return 1
    }
  else
    count="$("${security_command[@]}" dump-keychain "$keychain" | awk -v expected="$service" '
      function finish_item() {
        if (item_class == "genp" && item_service == expected) count++
        item_class = ""
        item_service = ""
      }
      /^keychain: / { saw_keychain = 1 }
      /^class: / {
        finish_item()
        if ($0 ~ /"genp"/) item_class = "genp"
        next
      }
      item_class == "genp" && /0x0000000a/ {
        if ($0 !~ /<blob>="/) exit 2
        item_service = $0
        sub(/^.*<blob>="/, "", item_service)
        sub(/".*$/, "", item_service)
      }
      END {
        finish_item()
        if (!saw_keychain) exit 3
        print count + 0
      }
    ')" || {
      print -u2 -- "unable to count Keychain items for service: $service"
      return 1
    }
  fi

  if [[ "$count" != <-> ]]; then
    print -u2 -- "invalid Keychain item count for service: $service"
    return 1
  fi
  print -- "$count"
}

capture_item_counts() {
  local destination="$1"
  local keychain="$2"
  local service
  local count
  typeset -a protected_services

  protected_services=(
    Plainpost
    test
    com.marynavdovenko.Plainpost.Vault
  )

  {
    for service in "$protected_services[@]"; do
      count="$(count_generic_password_items "$keychain" "$service")" || return 1
      print -- "$service=$count"
    done
  } >"$destination/item-counts.txt"
}

verify_keychain_file_readable() {
  local file="$1"
  local escaped_file

  escaped_file="$(escaped_path_for_error "$file")"
  if (( ${#file_read_command[@]} )); then
    "${file_read_command[@]}" "$file" || {
      print -u2 -- "unable to read Keychain fingerprint target: $escaped_file"
      return 1
    }
  else
    [[ -r "$file" ]] || {
      print -u2 -- "unable to read Keychain fingerprint target: $escaped_file"
      return 1
    }
  fi
}

sha256_for_file() {
  local file="$1"
  local hash
  local escaped_file

  escaped_file="$(escaped_path_for_error "$file")"

  if (( ${#fingerprint_command[@]} )); then
    hash="$("${fingerprint_command[@]}" "$file")" || {
      print -u2 -- "unable to fingerprint Keychain file: $escaped_file"
      return 1
    }
  else
    hash="$(command shasum -a 256 "$file" | command awk '{ print $1 }')" || {
      print -u2 -- "unable to fingerprint Keychain file: $escaped_file"
      return 1
    }
  fi

  [[ "$hash" != *$'\n'* && ${#hash} -eq 64 ]] && print -r -- "$hash" | command grep -Eq '^[[:xdigit:]]{64}$' || {
    print -u2 -- "invalid Keychain fingerprint: $escaped_file"
    return 1
  }
  print -r -- "$hash"
}

capture_filesystem_fingerprint() {
  setopt localoptions nullglob
  local destination="$1"
  local default_keychain="$2"
  local default_parent="${default_keychain:h}"
  local file
  local canonical_file
  local relative_name
  local hash
  local metadata
  local metadata_field
  local escaped_file
  typeset -a files
  typeset -a metadata_fields

  files=("$default_keychain" "${default_keychain}.sb-"*)
  (( ${#files[@]} > 0 )) || {
    print -u2 -- "no Keychain files available to fingerprint"
    return 1
  }

  : >"$destination/keychain-fingerprint.txt"
  for file in ${(on)files}; do
    [[ -f "$file" ]] || {
      print -u2 -- "Keychain fingerprint target is not a regular file: $(escaped_path_for_error "$file")"
      return 1
    }
    canonical_file="${file:A}"
    [[ "${canonical_file:h}" == "$default_parent" ]] || {
      print -u2 -- "Keychain sibling symlink escapes its parent: $(escaped_path_for_error "$file")"
      return 1
    }
    relative_name="${file:t}"
    [[ -n "$relative_name" ]] || {
      print -u2 -- "unsafe Keychain fingerprint filename"
      return 1
    }
    if print -rn -- "$relative_name" | LC_ALL=C command grep -q '[[:cntrl:]]'; then
      print -u2 -- "unsafe Keychain fingerprint filename: $(escaped_path_for_error "$relative_name")"
      return 1
    fi
    verify_keychain_file_readable "$canonical_file" || return 1
    hash="$(sha256_for_file "$canonical_file")" || return 1
    if (( ${#stat_command[@]} )); then
      metadata="$("${stat_command[@]}" "$canonical_file")" || {
        escaped_file="$(escaped_path_for_error "$file")"
        print -u2 -- "unable to stat Keychain file: $escaped_file"
        return 1
      }
    else
      metadata="$(command stat -f '%z %Lp %u %g %i %d %m' "$canonical_file")" || {
        escaped_file="$(escaped_path_for_error "$file")"
        print -u2 -- "unable to stat Keychain file: $escaped_file"
        return 1
      }
    fi
    [[ -n "$metadata" ]] || {
      escaped_file="$(escaped_path_for_error "$file")"
      print -u2 -- "unable to stat Keychain file: $escaped_file"
      return 1
    }
    metadata_fields=(${=metadata})
    (( ${#metadata_fields[@]} == 7 )) || {
      print -u2 -- "invalid Keychain file metadata"
      return 1
    }
    for metadata_field in "$metadata_fields[@]"; do
      [[ "$metadata_field" == <-> ]] || {
        print -u2 -- "invalid Keychain file metadata"
        return 1
      }
    done
    print -r -- "${relative_name}"$'\t'"${hash}"$'\t'"${metadata}" >>"$destination/keychain-fingerprint.txt"
  done
}

capture_snapshot() {
  local destination="$1"
  local default_output
  local search_list
  local default_keychain
  local resolved_keychain
  local item_counts_available=0

  default_output="$("${security_command[@]}" default-keychain -d user)" || {
    print -u2 -- "unable to determine default Keychain"
    return 1
  }
  search_list="$("${security_command[@]}" list-keychains -d user)" || {
    print -u2 -- "unable to determine Keychain search list"
    return 1
  }
  print -r -- "$default_output" >"$destination/default-keychain.txt"
  print -r -- "$search_list" >"$destination/search-list.txt"
  default_keychain="$(print -r -- "$default_output" | command sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
  resolved_keychain="$(resolve_default_keychain "$default_keychain")" || return 1

  if capture_item_counts "$destination" "$resolved_keychain"; then
    item_counts_available=1
  else
    command rm -f "$destination/item-counts.txt"
  fi

  capture_filesystem_fingerprint "$destination" "$resolved_keychain" || return 1
  if (( item_counts_available )); then
    print -r -- 'item-counts+filesystem-fingerprint' \
      >"$destination/mode.txt"
  else
    print -r -- 'filesystem-fingerprint' >"$destination/mode.txt"
  fi
}

reserve_snapshot_directory() {
  local destination="$1"
  local reserve_pid
  local reserve_status

  mkdir -p "${destination:h}"
  if (( ${#before_reserve_command[@]} )); then
    "${before_reserve_command[@]}" "$destination" &
    reserve_pid=$!
    while true; do
      set +e
      wait "$reserve_pid"
      reserve_status=$?
      set -e
      if (( reserve_status >= 128
            && ${guarded_pending_signal_status:-0} != 0 )); then
        if kill -0 -- "$reserve_pid" 2>/dev/null; then
          continue
        fi
      fi
      break
    done
    if (( reserve_status != 0 )); then
      print -u2 -- "unable to prepare Keychain baseline reservation"
      return 1
    fi
  fi
  mkdir "$destination" || {
    print -u2 -- "refusing to overwrite Keychain baseline: $(escaped_path_for_error "$destination")"
    return 1
  }
  : >"$destination/.incomplete" || {
    print -u2 -- "unable to mark Keychain baseline incomplete"
    return 1
  }
}

finalize_snapshot_directory() {
  local destination="$1"

  # Exact mkdir reservation and the sentinel retain fail-closed publication
  # state until all capture writes have completed.
  command rm -f "$destination/.incomplete" || {
    print -u2 -- "unable to finalize Keychain baseline"
    return 1
  }
}

publish_baseline() {
  local destination="$1"

  reserve_snapshot_directory "$destination" || exit 65
  capture_snapshot "$destination" || exit 1
  finalize_snapshot_directory "$destination" || exit 1
}

assert_snapshot_unchanged() {
  local destination="$1"
  local mode
  local current_directory
  local name
  local assertion_status=0
  typeset -a comparison_names

  [[ ! -L "$destination" && -d "$destination" && ! -e "$destination/.incomplete" && ! -L "$destination/.incomplete" ]] || {
    print -u2 -- "missing or incomplete Keychain snapshot"
    return 66
  }

  for name in default-keychain.txt search-list.txt mode.txt; do
    [[ ! -L "$destination/$name" && -f "$destination/$name" ]] || {
      print -u2 -- "incomplete Keychain snapshot: $name"
      return 66
    }
  done

  mode="$(<"$destination/mode.txt")"
  case "$mode" in
    item-counts+filesystem-fingerprint)
      comparison_names=(
        item-counts.txt
        keychain-fingerprint.txt
      )
      ;;
    filesystem-fingerprint)
      comparison_names=(keychain-fingerprint.txt)
      ;;
    *)
      print -u2 -- "unknown Keychain isolation snapshot mode"
      return 1
      ;;
  esac
  for name in "$comparison_names[@]"; do
    [[ ! -L "$destination/$name" && -f "$destination/$name" ]] || {
      print -u2 -- "incomplete Keychain snapshot: $name"
      return 66
    }
  done

  current_directory="$(mktemp -d)"
  if ! capture_snapshot "$current_directory"; then
    assertion_status=1
  else
    for name in default-keychain.txt search-list.txt mode.txt; do
      if ! diff -u "$destination/$name" "$current_directory/$name"; then
        print -u2 -- "Keychain isolation assertion failed: $name changed"
        assertion_status=1
      fi
    done

    for name in "$comparison_names[@]"; do
      if ! diff -u "$destination/$name" "$current_directory/$name"; then
        print -u2 -- "Keychain isolation assertion failed: $name changed"
        assertion_status=1
      fi
    done
  fi
  command rm -rf "$current_directory"
  return "$assertion_status"
}

if [[ "$phase" == before ]]; then
  publish_baseline "$snapshot_directory"
  exit 0
fi

if [[ "$phase" == after ]]; then
  assert_snapshot_unchanged "$snapshot_directory"
  exit $?
fi

typeset -gi guarded_after_status=0
typeset -gi guarded_after_complete=0
typeset -gi guarded_child_pid=0
typeset -g guarded_pending_signal_name=""
typeset -gi guarded_pending_signal_status=0
typeset -g guarded_handshake_directory=""

run_guarded_after_comparison() {
  if (( guarded_after_complete )); then
    return "$guarded_after_status"
  fi
  guarded_after_complete=1
  set +e
  assert_snapshot_unchanged "$snapshot_directory"
  guarded_after_status=$?
  set -e
  return "$guarded_after_status"
}

cleanup_guarded_handshake() {
  local directory="$guarded_handshake_directory"

  [[ -n "$directory" ]] || return 0
  [[ "$directory" == /* && "$directory" != / && "$directory" != "$HOME" ]] || {
    print -u2 -- "unsafe Keychain guard handshake directory"
    return 1
  }
  [[ ! -L "$directory" && -d "$directory" ]] || {
    print -u2 -- "missing Keychain guard handshake directory"
    return 1
  }
  command rm -rf -- "$directory"
  guarded_handshake_directory=""
}

handle_guarded_exit() {
  local command_status=$?
  local after_status
  local cleanup_status

  trap - EXIT HUP INT TERM
  set +e
  run_guarded_after_comparison
  after_status=$?
  cleanup_guarded_handshake
  cleanup_status=$?
  set -e
  if (( after_status != 0 )); then
    print -u2 -- \
      "Keychain isolation after-comparison failed; baseline retained at: $snapshot_directory"
    exit "$after_status"
  fi
  if (( cleanup_status != 0 )); then
    print -u2 -- "Keychain guard handshake cleanup failed"
    exit "$cleanup_status"
  fi
  exit "$command_status"
}

guarded_child_or_group_is_alive() {
  (( guarded_child_pid > 0 )) || return 1
  kill -0 -- "$guarded_child_pid" 2>/dev/null \
    || kill -0 -- "-$guarded_child_pid" 2>/dev/null
}

terminate_guarded_process_group() {
  local signal_name="$1"
  local attempt

  (( guarded_child_pid > 0 )) || return 0
  kill -s "$signal_name" -- "-$guarded_child_pid" 2>/dev/null || true
  kill -s "$signal_name" -- "$guarded_child_pid" 2>/dev/null || true
  kill -s "$signal_name" -- "-$guarded_child_pid" 2>/dev/null || true
  for attempt in {1..25}; do
    guarded_child_or_group_is_alive || break
    command sleep 0.02
  done
  if guarded_child_or_group_is_alive; then
    kill -KILL -- "-$guarded_child_pid" 2>/dev/null || true
    kill -KILL -- "$guarded_child_pid" 2>/dev/null || true
    kill -KILL -- "-$guarded_child_pid" 2>/dev/null || true
  fi
  set +e
  wait "$guarded_child_pid" 2>/dev/null
  set -e
  guarded_child_pid=0
}

handle_guarded_signal() {
  local signal_name="$1"
  local signal_status="$2"

  if (( guarded_pending_signal_status == 0 )); then
    guarded_pending_signal_name="$signal_name"
    guarded_pending_signal_status="$signal_status"
  fi
  (( guarded_child_pid > 0 )) || return 0

  trap - HUP INT TERM
  terminate_guarded_process_group "$signal_name"
  exit "$signal_status"
}

trap 'handle_guarded_signal HUP 129' HUP
trap 'handle_guarded_signal INT 130' INT
trap 'handle_guarded_signal TERM 143' TERM

publish_baseline "$snapshot_directory"
trap 'handle_guarded_exit' EXIT
print -r -- "Keychain isolation baseline retained at: $snapshot_directory"

if (( guarded_pending_signal_status != 0 )); then
  trap - HUP INT TERM
  exit "$guarded_pending_signal_status"
fi

guarded_handshake_directory="$(mktemp -d)"
chmod 700 "$guarded_handshake_directory"
guarded_ready_file="$guarded_handshake_directory/ready"
guarded_release_file="$guarded_handshake_directory/release"

if (( guarded_pending_signal_status != 0 )); then
  trap - HUP INT TERM
  exit "$guarded_pending_signal_status"
fi

set +e
/usr/bin/perl -MPOSIX=setsid -MFcntl=:DEFAULT -e '
  my ($ready_file, $release_file, @command) = @ARGV;
  setsid() >= 0 or die "setsid failed: $!";
  sysopen(
    my $ready_handle,
    $ready_file,
    O_WRONLY | O_CREAT | O_EXCL,
    0600
  ) or die "ready handshake failed: $!";
  print {$ready_handle} "ready\n" or die "ready handshake write failed: $!";
  close $ready_handle or die "ready handshake close failed: $!";
  until (-e $release_file) {
    select undef, undef, undef, 0.005;
  }
  exec @command or die "exec failed: $!";
' -- "$guarded_ready_file" "$guarded_release_file" "${guarded_command[@]}" &
guarded_child_pid=$!

if (( guarded_pending_signal_status != 0 )); then
  trap - HUP INT TERM
  terminate_guarded_process_group "$guarded_pending_signal_name"
  exit "$guarded_pending_signal_status"
fi

while [[ ! -e "$guarded_ready_file" ]]; do
  if ! kill -0 -- "$guarded_child_pid" 2>/dev/null; then
    wait "$guarded_child_pid"
    guarded_command_status=$?
    guarded_child_pid=0
    set -e
    exit "$guarded_command_status"
  fi
  command sleep 0.005
done

if [[ -L "$guarded_ready_file" || ! -f "$guarded_ready_file" ]]; then
  terminate_guarded_process_group KILL
  set -e
  print -u2 -- "invalid Keychain guard launch handshake"
  exit 1
fi

(
  setopt localoptions noclobber
  : >"$guarded_release_file"
) || {
  terminate_guarded_process_group KILL
  set -e
  print -u2 -- "unable to release guarded Keychain command"
  exit 1
}

wait "$guarded_child_pid"
guarded_command_status=$?
guarded_child_pid=0
set -e
exit "$guarded_command_status"
