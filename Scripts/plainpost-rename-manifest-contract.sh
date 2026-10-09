#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
rename_script="$repo_root/Scripts/plainpost/rename-manifest.sh"
identity_scanner="$repo_root/Scripts/plainpost/assert-no-retired-identity.sh"
fixture="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT

retired_title="Epis""tyn"
retired_lower="epis""tyn"
retired_upper="EPIS""TYN"
replacement_title="Plainpost"
replacement_lower="plainpost"
replacement_upper="PLAINPOST"
retired_bundle="com.olhapi.$retired_title"
replacement_bundle="com.olhapi.$replacement_title"

make_fixture() {
  local destination="$1"
  mkdir -p "$destination/Sources/${retired_title}Core" \
    "$destination/Sources/$retired_lower" \
    "$destination/Tests/${retired_title}CoreTests"
  printf 'struct %sCore {}\n' "$retired_title" >"$destination/Sources/${retired_title}Core/${retired_title}Core.swift"
  printf 'print("%s")\n' "$retired_lower" >"$destination/Sources/$retired_lower/main.swift"
  chmod +x "$destination/Sources/$retired_lower/main.swift"
  printf 'final class %sCoreTests {}\n' "$retired_title" >"$destination/Tests/${retired_title}CoreTests/${retired_title}CoreTests.swift"
  printf '%s %s %s %s\n' "$retired_title" "$retired_lower" "$retired_upper" "$retired_bundle" >"$destination/plain.txt"
  printf '\377\000resource\n' >"$destination/resource.bin"
  git -C "$destination" init -q
  git -C "$destination" add .
  git -C "$destination" -c commit.gpgSign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial
}

assert_clean() {
  [[ -z "$(git -C "$1" status --porcelain)" ]] || {
    printf 'fixture mutated after rejected manifest: %s\n' "$1" >&2
    exit 1
  }
}

git_metadata_fingerprint() {
  local repository="$1"
  (
    cd "$repository/.git"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      shasum -a 256 "$file"
    done
  )
}

happy="$fixture/happy"
make_fixture "$happy"
manifest="$happy/rename-manifest.tsv"
"$rename_script" --repo "$happy" --output "$manifest"
expected_manifest="$happy/expected.tsv"
{
  printf 'move\tSources/%sCore/%sCore.swift\tSources/%sCore/%sCore.swift\n' "$retired_title" "$retired_title" "$replacement_title" "$replacement_title"
  printf 'move\tSources/%s/main.swift\tSources/%s/main.swift\n' "$retired_lower" "$replacement_lower"
  printf 'move\tTests/%sCoreTests/%sCoreTests.swift\tTests/%sCoreTests/%sCoreTests.swift\n' "$retired_title" "$retired_title" "$replacement_title" "$replacement_title"
  printf 'replace\tSources/%sCore/%sCore.swift\t%s\t%s\n' "$retired_title" "$retired_title" "$retired_title" "$replacement_title"
  printf 'replace\tSources/%s/main.swift\t%s\t%s\n' "$retired_lower" "$retired_lower" "$replacement_lower"
  printf 'replace\tTests/%sCoreTests/%sCoreTests.swift\t%s\t%s\n' "$retired_title" "$retired_title" "$retired_title" "$replacement_title"
  printf 'replace\tplain.txt\t%s\t%s\n' "$retired_bundle" "$replacement_bundle"
  printf 'replace\tplain.txt\t%s\t%s\n' "$retired_title" "$replacement_title"
  printf 'replace\tplain.txt\t%s\t%s\n' "$retired_lower" "$replacement_lower"
  printf 'replace\tplain.txt\t%s\t%s\n' "$retired_upper" "$replacement_upper"
} >"$expected_manifest"
cmp -s "$expected_manifest" "$manifest" || {
  printf 'manifest did not match the exact ordered fixture plan\n' >&2
  exit 1
}
second_manifest="$happy/second.tsv"
"$rename_script" --repo "$happy" --output "$second_manifest"
cmp -s "$manifest" "$second_manifest" || {
  printf 'second manifest generation was not byte-identical\n' >&2
  exit 1
}
git -C "$happy" diff --quiet || {
  printf 'manifest generation changed the fixture\n' >&2
  exit 1
}

"$rename_script" --repo "$happy" --output "$manifest" --apply
test -f "$happy/Sources/${replacement_title}Core/${replacement_title}Core.swift"
test -f "$happy/Sources/$replacement_lower/main.swift"
test -f "$happy/Tests/${replacement_title}CoreTests/${replacement_title}CoreTests.swift"
! LC_ALL=C grep -Fq -- "$retired_title" "$happy/plain.txt"
! LC_ALL=C grep -Fq -- "$retired_lower" "$happy/plain.txt"
! LC_ALL=C grep -Fq -- "$retired_upper" "$happy/plain.txt"
LC_ALL=C grep -Fq -- "$replacement_bundle" "$happy/plain.txt"
[[ "$(stat -f '%Lp' "$happy/Sources/$replacement_lower/main.swift")" == 755 ]] || {
  printf 'executable text mode was not preserved\n' >&2
  exit 1
}
[[ "$(LC_ALL=C git -C "$happy" show :resource.bin | shasum -a 256 | awk '{ print $1 }')" == "$(shasum -a 256 "$happy/resource.bin" | awk '{ print $1 }')" ]] || {
  printf 'binary resource changed\n' >&2
  exit 1
}
(cd "$happy" && "$identity_scanner")
printf '%s\n' "$retired_title" >"$happy/artifact.txt"
if (cd "$happy" && "$identity_scanner" --artifact "$happy/artifact.txt"); then
  printf 'artifact scan did not detect the retired identity\n' >&2
  exit 1
fi
rm "$happy/artifact.txt"

subdirectory_output="$happy/subdirectory.tsv"
if "$rename_script" --repo "$happy/Sources" --output "$subdirectory_output"; then
  printf 'canonical repository subdirectory was accepted\n' >&2
  exit 1
fi

dirty="$fixture/dirty"
make_fixture "$dirty"
dirty_manifest="$dirty/manifest.tsv"
"$rename_script" --repo "$dirty" --output "$dirty_manifest"
printf 'unreviewed tracked change\n' >>"$dirty/plain.txt"
if "$rename_script" --repo "$dirty" --output "$dirty_manifest" --apply; then
  printf 'dirty tracked fixture was applied\n' >&2
  exit 1
fi
test -f "$dirty/Sources/${retired_title}Core/${retired_title}Core.swift"
! test -e "$dirty/Sources/${replacement_title}Core/${replacement_title}Core.swift"
LC_ALL=C grep -Fq -- 'unreviewed tracked change' "$dirty/plain.txt"

collision="$fixture/collision"
make_fixture "$collision"
mkdir -p "$collision/Sources/${replacement_title}Core"
printf 'existing\n' >"$collision/Sources/${replacement_title}Core/${replacement_title}Core.swift"
git -C "$collision" add .
git -C "$collision" -c commit.gpgSign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm destination
if "$rename_script" --repo "$collision" --output "$collision/manifest.tsv"; then
  printf 'collision fixture was accepted\n' >&2
  exit 1
fi
assert_clean "$collision"

untracked_destination="$fixture/untracked-destination"
make_fixture "$untracked_destination"
mkdir -p "$untracked_destination/Sources/${replacement_title}Core"
printf 'untracked\n' >"$untracked_destination/Sources/${replacement_title}Core/${replacement_title}Core.swift"
if "$rename_script" --repo "$untracked_destination" --output "$untracked_destination/manifest.tsv"; then
  printf 'untracked destination was accepted\n' >&2
  exit 1
fi
[[ -f "$untracked_destination/Sources/${replacement_title}Core/${replacement_title}Core.swift" ]] || exit 1
[[ -z "$(git -C "$untracked_destination" diff --name-only)" ]] || exit 1

symlink="$fixture/symlink"
make_fixture "$symlink"
ln -s plain.txt "$symlink/link-${retired_title}"
git -C "$symlink" add "link-${retired_title}"
git -C "$symlink" -c commit.gpgSign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm symlink
if "$rename_script" --repo "$symlink" --output "$symlink/manifest.tsv"; then
  printf 'symlink fixture was accepted\n' >&2
  exit 1
fi
assert_clean "$symlink"

ancestor_collision="$fixture/ancestor-collision"
make_fixture "$ancestor_collision"
mkdir -p "$ancestor_collision/Parent/${retired_title}"
printf 'parent source\n' >"$ancestor_collision/Parent/${retired_title}/file.txt"
git -C "$ancestor_collision" add "Parent/${retired_title}/file.txt"
git -C "$ancestor_collision" -c commit.gpgSign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm parent-source
printf 'blocking parent\n' >"$ancestor_collision/Parent/${replacement_title}"
if "$rename_script" --repo "$ancestor_collision" --output "$ancestor_collision/manifest.tsv"; then
  printf 'destination parent-file collision was accepted\n' >&2
  exit 1
fi
test -f "$ancestor_collision/Sources/${retired_title}Core/${retired_title}Core.swift"
! test -e "$ancestor_collision/Sources/${replacement_title}Core/${replacement_title}Core.swift"
[[ -f "$ancestor_collision/Parent/${replacement_title}" ]] || exit 1

for excluded_root in .build DerivedData xcuserdata; do
  excluded="$fixture/excluded-${excluded_root}"
  make_fixture "$excluded"
  mkdir -p "$excluded/$excluded_root"
  printf '%s\n' "$retired_title" >"$excluded/$excluded_root/unsafe.txt"
  git -C "$excluded" add -f "$excluded_root/unsafe.txt"
  git -C "$excluded" -c commit.gpgSign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm excluded
  if "$rename_script" --repo "$excluded" --output "$excluded/manifest.tsv"; then
    printf 'excluded root was accepted: %s\n' "$excluded_root" >&2
    exit 1
  fi
  assert_clean "$excluded"
done
git_excluded="$fixture/excluded-git"
make_fixture "$git_excluded"
git_metadata_before="$(git_metadata_fingerprint "$git_excluded")"
if "$rename_script" --repo "$git_excluded" --output "$git_excluded/.git/manifest.tsv"; then
  printf 'Git metadata output was accepted\n' >&2
  exit 1
fi
assert_clean "$git_excluded"
[[ ! -e "$git_excluded/.git/manifest.tsv" ]] || {
  printf 'Git metadata output was created despite rejection\n' >&2
  exit 1
}
[[ "$(git_metadata_fingerprint "$git_excluded")" == "$git_metadata_before" ]] || {
  printf 'Git metadata changed despite rejection\n' >&2
  exit 1
}

artifact="$fixture/artifact"
mkdir -p "$artifact/nested"
printf 'clean\n' >"$artifact/nested/clean.txt"
(cd "$happy" && "$identity_scanner" --artifact "$artifact")
mv "$artifact/nested/clean.txt" "$artifact/nested/${retired_title}-filename.txt"
if (cd "$happy" && "$identity_scanner" --artifact "$artifact"); then
  printf 'recursive artifact filename was accepted\n' >&2
  exit 1
fi
mv "$artifact/nested/${retired_title}-filename.txt" "$artifact/nested/clean.txt"
printf '%s\n' "$retired_title" >"$artifact/nested/clean.txt"
if (cd "$happy" && "$identity_scanner" --artifact "$artifact"); then
  printf 'recursive artifact content was accepted\n' >&2
  exit 1
fi
printf 'clean\n' >"$artifact/nested/clean.txt"
ln -s "$artifact/missing" "$artifact/nested/dangling"
if (cd "$happy" && "$identity_scanner" --artifact "$artifact"); then
  printf 'artifact traversal failure was accepted\n' >&2
  exit 1
fi
rm "$artifact/nested/dangling"
chmod 000 "$artifact/nested/clean.txt"
if (cd "$happy" && "$identity_scanner" --artifact "$artifact"); then
  printf 'unreadable artifact file was accepted\n' >&2
  exit 1
fi
chmod 644 "$artifact/nested/clean.txt"
rm "$happy/plain.txt"
if (cd "$happy" && "$identity_scanner"); then
  printf 'missing tracked file was accepted by the identity scanner\n' >&2
  exit 1
fi

detector_failure="$fixture/detector-failure"
make_fixture "$detector_failure"
detector_bin="$detector_failure/bin"
mkdir "$detector_bin"
printf '#!/usr/bin/env bash\nexit 70\n' >"$detector_bin/file"
chmod +x "$detector_bin/file"
detector_status="$(git -C "$detector_failure" status --porcelain)"
if PATH="$detector_bin:$PATH" "$rename_script" --repo "$detector_failure" --output "$detector_failure/manifest.tsv"; then
  printf 'text detector failure was accepted\n' >&2
  exit 1
fi
[[ "$(git -C "$detector_failure" status --porcelain)" == "$detector_status" ]] || {
  printf 'text detector failure mutated the fixture\n' >&2
  exit 1
}
