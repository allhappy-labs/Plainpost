#!/bin/zsh
set -euo pipefail
fixture="$(mktemp -d)"
outside_sibling=""
trap 'rm -rf "$fixture" "$outside_sibling"' EXIT
repo_root="${0:A:h:h}"

security_stub="$fixture/security-stub"
count_stub="$fixture/count-stub"
fingerprint_stub="$fixture/fingerprint-stub"
read_stub="$fixture/read-stub"
stat_stub="$fixture/stat-stub"
rtk_stub_directory="$fixture/bin"
sync_stub="$rtk_stub_directory/sync"
sync_marker="$fixture/sync-invoked"
mkdir -p "$rtk_stub_directory"

print -r -- '#!/bin/zsh
set -euo pipefail
case "$1" in
  default-keychain)
    if [[ -v FIXTURE_DEFAULT_KEYCHAIN ]]; then
      print -- "\"$FIXTURE_DEFAULT_KEYCHAIN\""
    else
      print -- "\"$FIXTURE_KEYCHAIN\""
    fi
    ;;
  list-keychains) print -- "$FIXTURE_KEYCHAIN" ;;
  dump-keychain) print -u2 -- "unexpected dump-keychain call in contract"; exit 70 ;;
  *) print -u2 -- "unexpected security command: $*"; exit 70 ;;
esac' >"$security_stub"

print -r -- '#!/bin/zsh
set -euo pipefail
[[ "$1" == "$FIXTURE_KEYCHAIN" ]] || exit 70
case "$COUNT_MODE:$2" in
  baseline:Plainpost) print -- 0 ;;
  baseline:test) print -- 2 ;;
  baseline:com.marynavdovenko.Plainpost.Vault) print -- 1 ;;
  changed:Plainpost) print -- 1 ;;
  changed:test) print -- 2 ;;
  changed:com.marynavdovenko.Plainpost.Vault) print -- 1 ;;
  vault-deleted:Plainpost) print -- 0 ;;
  vault-deleted:test) print -- 2 ;;
  vault-deleted:com.marynavdovenko.Plainpost.Vault) print -- 0 ;;
  error:*) exit 70 ;;
  *) exit 70 ;;
esac' >"$count_stub"

print -r -- '#!/bin/zsh
set -euo pipefail
[[ -f "$1" ]] || exit 70
case "${FINGERPRINT_MODE:-baseline}" in
  baseline) /usr/bin/shasum -a 256 "$1" | /usr/bin/awk "{ print \$1 }" ;;
  changed) print -- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  error) exit 70 ;;
  *) exit 70 ;;
esac' >"$fingerprint_stub"

print -r -- '#!/bin/zsh
set -euo pipefail
[[ -f "$1" ]] || exit 70
[[ "${READ_MODE:-baseline}" == baseline ]] || exit 70' >"$read_stub"

print -r -- '#!/bin/zsh
set -euo pipefail
[[ -f "$1" ]] || exit 70
[[ "${STAT_MODE:-baseline}" == baseline ]] || exit 70
command stat -f "%z %Lp %u %g %i %d %m" "$1"' >"$stat_stub"

print -r -- '#!/bin/zsh
set -euo pipefail
print -n -- invoked >"$SYNC_MARKER"
exit 70' >"$sync_stub"

print -r -- "#!/bin/zsh
set -euo pipefail
if [[ \"\$1\" == security ]]; then
  shift
  exec \"\$FIXTURE_SECURITY_STUB\" \"\$@\"
fi
exec \"\$REAL_RTK\" \"\$@\"" >"$rtk_stub_directory/rtk"
chmod +x "$security_stub" "$count_stub" "$fingerprint_stub" "$read_stub" "$stat_stub" "$sync_stub" "$rtk_stub_directory/rtk"

export FIXTURE_KEYCHAIN="${fixture:A}/fixture.keychain-db"
export FIXTURE_SECURITY_STUB="$security_stub"
export REAL_RTK="$(command -v rtk)"
export SYNC_MARKER="$sync_marker"
export PATH="$rtk_stub_directory:$PATH"
print -n -- 'fixture-keychain' >"$FIXTURE_KEYCHAIN"
print -n -- 'fixture-sibling' >"$FIXTURE_KEYCHAIN.sb-1"

git -C "$fixture" init -q
touch "$fixture/keep.txt"
git -C "$fixture" add keep.txt
git -C "$fixture" -c commit.gpgSign=false -c user.name=Test -c user.email=test@example.invalid commit -qm init
git -C "$fixture" remote add origin https://example.invalid/plainpost-fixture.git
output="$fixture/output"
PLAINPOST_SECURITY_COMMAND="$security_stub" "$repo_root/Scripts/plainpost/preflight.sh" --repo "$fixture" --output "$output"
test -s "$output/status.txt"
test -s "$output/worktrees.txt"
test -s "$output/remotes.txt"
test -s "$output/tracked-paths.txt"
test -s "$output/keychain-default.txt"
test -s "$output/keychain-search-list.txt"
if PLAINPOST_SECURITY_COMMAND="$security_stub" "$repo_root/Scripts/plainpost/preflight.sh" --repo "$fixture" --output "$output"; then
  print -u2 -- "preflight overwrote an immutable snapshot"
  exit 1
fi

snapshot="$fixture/keychain-guard"
grep -qx '#!/bin/zsh' "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh"
COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$snapshot"
[[ ! -e "$sync_marker" ]] || {
  print -u2 -- "Keychain baseline invoked sync"
  exit 1
}
grep -qx 'Plainpost=0' "$snapshot/item-counts.txt"
grep -qx 'test=2' "$snapshot/item-counts.txt"
grep -qx 'com.marynavdovenko.Plainpost.Vault=1' "$snapshot/item-counts.txt"
grep -qx 'item-counts+filesystem-fingerprint' "$snapshot/mode.txt"
if COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$snapshot"; then
  print -u2 -- "Keychain baseline overwrote an immutable snapshot"
  exit 1
fi
COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$snapshot"
if COUNT_MODE=changed PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$snapshot"; then
  print -u2 -- "Keychain count change was not detected"
  exit 1
fi

vault_snapshot="$fixture/vault-keychain-guard"
COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$vault_snapshot"
if COUNT_MODE=vault-deleted PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$vault_snapshot"; then
  print -u2 -- "Canonical vault-key deletion was not detected"
  exit 1
fi

replacement_snapshot="$fixture/same-count-replacement-guard"
COUNT_MODE=baseline FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$replacement_snapshot"
if COUNT_MODE=baseline FINGERPRINT_MODE=changed PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$replacement_snapshot"; then
  print -u2 -- "Same-count protected-item replacement was not detected"
  exit 1
fi

if COUNT_MODE=baseline FINGERPRINT_MODE=error PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/count-only-guard"; then
  print -u2 -- "Keychain baseline accepted count-only preservation evidence"
  exit 1
fi
if COUNT_MODE=error FINGERPRINT_MODE=error PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/error-guard"; then
  print -u2 -- "Keychain baseline succeeded without a usable fingerprint"
  exit 1
fi

fallback_snapshot="$fixture/fallback-guard"
COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fallback_snapshot"
grep -qx 'filesystem-fingerprint' "$fallback_snapshot/mode.txt"
grep -q $'fixture.keychain-db\t' "$fallback_snapshot/keychain-fingerprint.txt"
COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$fallback_snapshot"

changed_fallback_snapshot="$fixture/changed-fallback-guard"
COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$changed_fallback_snapshot"
print -n -- 'changed' >>"$FIXTURE_KEYCHAIN.sb-1"
if COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$changed_fallback_snapshot"; then
  print -u2 -- "Keychain fingerprint change was not detected"
  exit 1
fi

new_sibling_snapshot="$fixture/new-sibling-guard"
COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$new_sibling_snapshot"
print -n -- 'new sibling' >"$FIXTURE_KEYCHAIN.sb-new"
if COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$new_sibling_snapshot"; then
  print -u2 -- "New Keychain sibling was not detected"
  exit 1
fi

if COUNT_MODE=error FINGERPRINT_MODE=error PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/fingerprint-error-guard"; then
  print -u2 -- "Keychain baseline succeeded without a usable fingerprint"
  exit 1
fi

escape_directory="$fixture/escaped-parent"
mkdir "$escape_directory"
print -n -- 'outside' >"$fixture/outside.keychain-db"
ln -s "$fixture/outside.keychain-db" "$escape_directory/escaped.keychain-db"
if FIXTURE_KEYCHAIN="${escape_directory:A}/escaped.keychain-db" COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/escaped-keychain-guard"; then
  print -u2 -- "Escaping Keychain symlink was accepted"
  exit 1
fi

for invalid_default in '' / "$HOME" "$fixture"; do
  if FIXTURE_DEFAULT_KEYCHAIN="$invalid_default" COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/invalid-default-${RANDOM}"; then
    print -u2 -- "Unsafe default Keychain target was accepted"
    exit 1
  fi
done

race_snapshot="$fixture/race-guard"
race_hook="$fixture/race-hook"
print -r -- '#!/bin/zsh
set -euo pipefail
mkdir "$1"' >"$race_hook"
chmod +x "$race_hook"
if COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_GUARD_BEFORE_RESERVE_COMMAND="$race_hook" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$race_snapshot"; then
  print -u2 -- "Raced Keychain baseline destination was accepted"
  exit 1
fi
[[ -d "$race_snapshot" ]]

for baseline_kind in directory file dangling-symlink; do
  blocked_snapshot="$fixture/blocked-${baseline_kind}"
  case "$baseline_kind" in
    directory) mkdir "$blocked_snapshot" ;;
    file) print -n -- blocked >"$blocked_snapshot" ;;
    dangling-symlink) ln -s "$fixture/missing-baseline" "$blocked_snapshot" ;;
  esac
  if COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$blocked_snapshot"; then
    print -u2 -- "Existing Keychain baseline $baseline_kind was accepted"
    exit 1
  fi
done

partial_snapshot="$fixture/partial-guard"
mkdir "$partial_snapshot"
touch "$partial_snapshot/.incomplete"
if COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$partial_snapshot"; then
  print -u2 -- "Incomplete Keychain baseline was accepted"
  exit 1
fi
partial_capture="$fixture/partial-capture"
if COUNT_MODE=error FINGERPRINT_MODE=error PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$partial_capture"; then
  print -u2 -- "Failed Keychain baseline capture was accepted"
  exit 1
fi
[[ -d "$partial_capture" && -f "$partial_capture/.incomplete" ]]

dangling_sentinel_snapshot="$fixture/dangling-sentinel-guard"
COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$dangling_sentinel_snapshot"
ln -s "$fixture/missing-sentinel" "$dangling_sentinel_snapshot/.incomplete"
if COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$dangling_sentinel_snapshot"; then
  print -u2 -- "Dangling Keychain baseline sentinel was accepted"
  exit 1
fi

dangling_snapshot="$fixture/dangling-snapshot"
ln -s "$fixture/missing-snapshot" "$dangling_snapshot"
if COUNT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$dangling_snapshot"; then
  print -u2 -- "Dangling Keychain baseline symlink was accepted"
  exit 1
fi

sibling_escape="$FIXTURE_KEYCHAIN.sb-escape"
outside_sibling="$(mktemp)"
print -n -- outside-sibling >"$outside_sibling"
ln -s "$outside_sibling" "$sibling_escape"
if COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/escaped-sibling-guard"; then
  print -u2 -- "Escaping Keychain sibling symlink was accepted"
  exit 1
fi
rm "$sibling_escape"
ln -s "$fixture/missing-sibling" "$FIXTURE_KEYCHAIN.sb-dangling"
if COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/dangling-sibling-guard"; then
  print -u2 -- "Dangling Keychain sibling symlink was accepted"
  exit 1
fi
rm "$FIXTURE_KEYCHAIN.sb-dangling"

for control_name in $'carriage\rreturn' $'escape\evalue' $'delete\177value'; do
  control_path="${FIXTURE_KEYCHAIN}.sb-${control_name}"
  print -n -- control >"$control_path"
  if COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$fixture/control-name-${RANDOM}"; then
    print -u2 -- "Control-character Keychain sibling was accepted"
    exit 1
  fi
  rm "$control_path"
done

for failure_mode in read stat; do
  failure_snapshot="$fixture/${failure_mode}-failure-guard"
  if [[ "$failure_mode" == read ]]; then
    READ_MODE=error
    STAT_MODE=baseline
  else
    READ_MODE=baseline
    STAT_MODE=error
  fi
  if COUNT_MODE=error FINGERPRINT_MODE=baseline READ_MODE="$READ_MODE" STAT_MODE="$STAT_MODE" PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" PLAINPOST_KEYCHAIN_FILE_READ_COMMAND="$read_stub" PLAINPOST_KEYCHAIN_STAT_COMMAND="$stat_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$failure_snapshot"; then
    print -u2 -- "Keychain $failure_mode failure was accepted"
    exit 1
  fi
done

metadata_snapshot="$fixture/metadata-guard"
COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$metadata_snapshot"
chmod 0600 "$FIXTURE_KEYCHAIN.sb-1"
touch -mt 202607270701 "$FIXTURE_KEYCHAIN.sb-1"
if COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$metadata_snapshot"; then
  print -u2 -- "Metadata-only Keychain change was not detected"
  exit 1
fi
chmod 0644 "$FIXTURE_KEYCHAIN.sb-1"

deleted_snapshot="$fixture/deleted-guard"
COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" before "$deleted_snapshot"
rm "$FIXTURE_KEYCHAIN.sb-1"
if COUNT_MODE=error FINGERPRINT_MODE=baseline PLAINPOST_SECURITY_COMMAND="$security_stub" PLAINPOST_KEYCHAIN_ITEM_COUNT_COMMAND="$count_stub" PLAINPOST_KEYCHAIN_FINGERPRINT_COMMAND="$fingerprint_stub" "$repo_root/Scripts/plainpost/assert-keychain-isolation.sh" after "$deleted_snapshot"; then
  print -u2 -- "Deleted Keychain sibling was not detected"
  exit 1
fi

true
