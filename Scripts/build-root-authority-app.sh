#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
profile_path="${PLAINPOST_ROOT_AUTHORITY_PROFILE:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/f1455314-5b46-4535-bb7a-8bd86c9503cb.provisionprofile}"
identity_sha1="${PLAINPOST_ROOT_AUTHORITY_IDENTITY_SHA1:-67D0B76B019381B32C7634776FDBBAB98FB35F4B}"
signing_keychain="${PLAINPOST_ROOT_AUTHORITY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
destination=""
receipt=""
executable_source=""
executable_source_commit=""

while (( $# > 0 )); do
  case "$1" in
    --profile) profile_path="$2"; shift 2 ;;
    --identity-sha1) identity_sha1="$2"; shift 2 ;;
    --keychain) signing_keychain="$2"; shift 2 ;;
    --destination) destination="$2"; shift 2 ;;
    --receipt) receipt="$2"; shift 2 ;;
    --executable) executable_source="$2"; shift 2 ;;
    --executable-source-commit) executable_source_commit="$2"; shift 2 ;;
    *) print -u2 -- "unknown argument: $1"; exit 64 ;;
  esac
done

if [[ -z "$destination" || -z "$receipt" || "$destination" != /* || "$receipt" != /* ]]; then
  print -u2 -- "usage: $0 --destination /absolute/Plainpost\\ Root\\ Authority.app --receipt /absolute/build-receipt.json [--profile PATH] [--identity-sha1 SHA1] [--keychain PATH] [--executable ABSOLUTE_PATH --executable-source-commit COMMIT]"
  exit 64
fi
if [[ -n "$executable_source" || -n "$executable_source_commit" ]]; then
  if [[ "$executable_source" != /* || -z "$executable_source_commit" ]]; then
    print -u2 -- "--executable and --executable-source-commit must be supplied together"
    exit 64
  fi
fi
if [[ -e "$destination" || -e "$receipt" ]]; then
  print -u2 -- "refusing to overwrite destination or receipt"
  exit 1
fi
if [[ ! -f "$profile_path" || ! -f "$signing_keychain" ]]; then
  print -u2 -- "provisioning profile or signing keychain not found"
  exit 1
fi

staging="$(mktemp -d /private/tmp/plainpost-root-authority-build.XXXXXX)"
destination_created=0
cleanup() {
  local exit_code=$?
  rm -rf -- "$staging"
  if (( exit_code != 0 && destination_created == 1 )); then rm -rf -- "$destination"; fi
  return $exit_code
}
trap cleanup EXIT
profile_plist="$staging/profile.plist"
/usr/bin/security cms -D -i "$profile_path" > "$profile_plist"
profile_certificate_sha1="$(/usr/bin/python3 "$repo_root/Scripts/validate-root-authority-signing.py" profile "$profile_plist")"
if [[ "$profile_certificate_sha1" != "$identity_sha1" ]]; then
  print -u2 -- "profile certificate does not match the requested signing identity"
  exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning "$signing_keychain" | /usr/bin/grep -Fq "$identity_sha1"; then
  print -u2 -- "requested Apple Development signing identity is unavailable"
  exit 1
fi

compiled_source_paths=(
  Package.swift
  Sources/PlainpostAccountProtocol
  Tools/PlainpostRootAuthority
)
source_paths=(
  "${compiled_source_paths[@]}"
  Scripts/build-root-authority-app.sh
  Scripts/validate-root-authority-signing.py
  docs/superpowers/plans/2026-09-06-production-key-authority.md
)
if [[ -n "$(git -C "$repo_root" status --porcelain -- "${source_paths[@]}")" ]]; then
  print -u2 -- "refusing to build from uncommitted root-authority source"
  exit 1
fi
packaging_commit="$(git -C "$repo_root" rev-parse HEAD)"

scratch_path="${PLAINPOST_ROOT_AUTHORITY_SCRATCH_PATH:-$staging/swift-build}"
if [[ -z "$executable_source" ]]; then
  swift build --package-path "$repo_root" --scratch-path "$scratch_path" --disable-sandbox -c release --product plainpost-root-authority
  executable_source="$scratch_path/release/plainpost-root-authority"
  executable_source_commit="$packaging_commit"
else
  executable_source_commit="$(git -C "$repo_root" rev-parse --verify "$executable_source_commit^{commit}")"
  if ! git -C "$repo_root" diff --quiet "$executable_source_commit" -- "${compiled_source_paths[@]}"; then
    print -u2 -- "current compiled sources do not match --executable-source-commit"
    exit 1
  fi
fi
if [[ ! -x "$executable_source" ]]; then
  print -u2 -- "root authority executable was not produced"
  exit 1
fi
if [[ "$(git -C "$repo_root" rev-parse HEAD)" != "$packaging_commit" || -n "$(git -C "$repo_root" status --porcelain -- "${source_paths[@]}")" ]]; then
  print -u2 -- "root-authority source changed during the build"
  exit 1
fi

app="$staging/Plainpost Root Authority.app"
unsigned_executable_sha256="$(/usr/bin/shasum -a 256 "$executable_source" | /usr/bin/awk '{print $1}')"
/bin/mkdir -p "$app/Contents/MacOS"
/bin/cp "$repo_root/Tools/PlainpostRootAuthority/App/Info.plist" "$app/Contents/Info.plist"
/bin/cp "$profile_path" "$app/Contents/embedded.provisionprofile"
/bin/cp "$executable_source" "$app/Contents/MacOS/plainpost-root-authority"
/bin/chmod 0755 "$app/Contents/MacOS/plainpost-root-authority"
entitlements="$repo_root/Tools/PlainpostRootAuthority/App/PlainpostRootAuthority.entitlements"
/usr/bin/codesign --force --sign "$identity_sha1" --keychain "$signing_keychain" --timestamp=none --entitlements "$entitlements" "$app/Contents/MacOS/plainpost-root-authority"
/usr/bin/codesign --force --sign "$identity_sha1" --keychain "$signing_keychain" --timestamp=none --entitlements "$entitlements" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

effective_entitlements="$staging/effective-entitlements.plist"
/usr/bin/codesign -d --xml --entitlements - "$app/Contents/MacOS/plainpost-root-authority" > "$effective_entitlements"
/usr/bin/python3 "$repo_root/Scripts/validate-root-authority-signing.py" entitlements "$effective_entitlements"

requirement="$(/usr/bin/codesign -d -r- "$app/Contents/MacOS/plainpost-root-authority" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
if [[ -z "$requirement" ]]; then
  print -u2 -- "designated requirement was not emitted"
  exit 1
fi
executable_sha256="$(/usr/bin/shasum -a 256 "$app/Contents/MacOS/plainpost-root-authority" | /usr/bin/awk '{print $1}')"
entitlements_sha256="$(/usr/bin/shasum -a 256 "$effective_entitlements" | /usr/bin/awk '{print $1}')"
/bin/mkdir "$destination"
destination_created=1
/usr/bin/ditto "$app/Contents" "$destination/Contents"
persisted_executable="$destination/Contents/MacOS/plainpost-root-authority"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"
persisted_entitlements="$staging/persisted-effective-entitlements.plist"
/usr/bin/codesign -d --xml --entitlements - "$persisted_executable" > "$persisted_entitlements"
/usr/bin/python3 "$repo_root/Scripts/validate-root-authority-signing.py" entitlements "$persisted_entitlements"
persisted_executable_sha256="$(/usr/bin/shasum -a 256 "$persisted_executable" | /usr/bin/awk '{print $1}')"
persisted_entitlements_sha256="$(/usr/bin/shasum -a 256 "$persisted_entitlements" | /usr/bin/awk '{print $1}')"
persisted_requirement="$(/usr/bin/codesign -d -r- "$persisted_executable" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
if [[ "$persisted_executable_sha256" != "$executable_sha256" || "$persisted_entitlements_sha256" != "$entitlements_sha256" || "$persisted_requirement" != "$requirement" ]]; then
  print -u2 -- "persisted helper does not match the verified staging app"
  exit 1
fi
if [[ "$(git -C "$repo_root" rev-parse HEAD)" != "$packaging_commit" || -n "$(git -C "$repo_root" status --porcelain -- "${source_paths[@]}")" ]]; then
  print -u2 -- "root-authority source changed before receipt creation"
  exit 1
fi
receipt_plist="$staging/receipt.plist"
/usr/bin/plutil -create xml1 "$receipt_plist"
/usr/bin/plutil -insert kind -string "plainpost-root-authority-build-receipt.v1" "$receipt_plist"
/usr/bin/plutil -insert bundleIdentifier -string "com.marynavdovenko.Plainpost" "$receipt_plist"
/usr/bin/plutil -insert displayName -string "Plainpost Root Authority" "$receipt_plist"
/usr/bin/plutil -insert accessGroup -string "9XN7WN8JN2.com.marynavdovenko.Plainpost.RootAuthority" "$receipt_plist"
/usr/bin/plutil -insert accountRootKeyID -string "plainpost-root-prod-2026-09" "$receipt_plist"
/usr/bin/plutil -insert accountRootApplicationTag -string "com.marynavdovenko.Plainpost.account.offline-root.prod-2026-09" "$receipt_plist"
/usr/bin/plutil -insert sessionRootKeyID -string "plainpost-session-root-prod-2026-09" "$receipt_plist"
/usr/bin/plutil -insert sessionRootApplicationTag -string "com.marynavdovenko.Plainpost.session.offline-root.prod-2026-09" "$receipt_plist"
/usr/bin/plutil -insert profileUUID -string "f1455314-5b46-4535-bb7a-8bd86c9503cb" "$receipt_plist"
/usr/bin/plutil -insert profileName -string "Plainpost Mac Development" "$receipt_plist"
/usr/bin/plutil -insert profileExpiresAt -string "2027-08-09T17:31:23Z" "$receipt_plist"
/usr/bin/plutil -insert profileCertificateSHA1 -string "$profile_certificate_sha1" "$receipt_plist"
/usr/bin/plutil -insert signingIdentitySHA1 -string "$identity_sha1" "$receipt_plist"
/usr/bin/plutil -insert signingKeychain -string "$signing_keychain" "$receipt_plist"
/usr/bin/plutil -insert unsignedExecutableSHA256 -string "$unsigned_executable_sha256" "$receipt_plist"
/usr/bin/plutil -insert executableSHA256 -string "$persisted_executable_sha256" "$receipt_plist"
/usr/bin/plutil -insert effectiveEntitlementsSHA256 -string "$persisted_entitlements_sha256" "$receipt_plist"
/usr/bin/plutil -insert designatedRequirement -string "$persisted_requirement" "$receipt_plist"
/usr/bin/plutil -insert sourceCommit -string "$executable_source_commit" "$receipt_plist"
/usr/bin/plutil -insert packagingCommit -string "$packaging_commit" "$receipt_plist"
/usr/bin/plutil -convert json -o "$staging/receipt.json" "$receipt_plist"
( setopt noclobber; /bin/cat "$staging/receipt.json" > "$receipt" )
/bin/chmod 0600 "$receipt"
if [[ "$(/usr/bin/stat -f '%Lp' "$receipt")" != "600" ]]; then
  print -u2 -- "persisted build receipt is not owner-only"
  exit 1
fi

print -- "$destination"
print -- "$receipt"
