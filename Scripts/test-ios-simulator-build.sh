#!/usr/bin/env bash
set -euo pipefail
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
artifacts="$root/Scripts/lib/build_artifacts.py"
derived="${PLAINPOST_IOS_DERIVED_DATA:-$(rtk proxy python3 "$artifacts" cache --root "$root" --purpose ios-build --sdk iphonesimulator --signing automatic)}"
output="${PLAINPOST_IOS_BUILD_OUTPUT:-$root/.build/ios-simulator-build-logs/$(date -u +%Y%m%dT%H%M%S)-$$}"
if [[ -e "$output" ]]; then
  printf 'Refusing to overwrite existing iOS build evidence: %s\n' "$output" >&2
  exit 64
fi
mkdir -p "$output"
printf 'derived_data=%s logs=%s\n' "$derived" "$output"
for scheme in PlainpostUI Plainpost; do
  log="$output/$scheme.log"
  product="PlainpostUI=Build/Products/Debug-iphonesimulator/PlainpostUI.o"
  [[ "$scheme" != Plainpost ]] || product="Plainpost=Build/Products/Debug-iphonesimulator/Plainpost.app"
  if rtk proxy python3 "$artifacts" build --root "$root" --cache "$derived" \
      --sdk iphonesimulator --configuration Debug --signing automatic \
      --receipt "$output/$scheme-receipt.json" --product "$product" -- rtk proxy xcodebuild -project "$root/Apps/PlainpostiOS/Plainpost.xcodeproj" -scheme "$scheme" \
      -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" build >"$log" 2>&1; then
    printf 'stage=ios-simulator-build scheme=%s outcome=pass\n' "$scheme"
  else
    rtk proxy grep -E 'error:' "$log" | rtk proxy sort -u >&2 || true
    printf 'stage=ios-simulator-build scheme=%s outcome=fail\n' "$scheme" >&2
    exit 1
  fi
done
