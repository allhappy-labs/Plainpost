#!/bin/sh

# Publish one bounded, privacy-safe terminal marker for a control action.
publish_release_backup_restore_marker() {
  marker=$1
  other_marker=$2
  marker_class=$3
  rm -f "$marker" "$other_marker" || return 1
  marker_tmp="$marker.$$"
  if ! printf 'terminal_class=%s\n' "$marker_class" >"$marker_tmp" ||
     ! chmod 0600 "$marker_tmp" ||
     ! mv -f "$marker_tmp" "$marker"; then
    rm -f "$marker_tmp" || true
    return 1
  fi
}
