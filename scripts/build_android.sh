#!/usr/bin/env bash
# Build the supported Android release APKs for SpotiFLAC Mobile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/build/app/outputs/flutter-apk"
AUDIT_FLAGS=()
if [[ -f "$PROJECT_DIR/third_party/spotiflac_discord/sdk/discord_partner_sdk.aar" ]]; then
  AUDIT_FLAGS+=(--discord-sdk)
fi

cd "$PROJECT_DIR"
BUILD_GIT_COMMIT="$(git rev-parse --short=8 HEAD)"
flutter build apk \
  --release \
  --split-per-abi \
  --target-platform android-arm,android-arm64 \
  --dart-define="GIT_COMMIT=$BUILD_GIT_COMMIT" \
  "$@"

for target in armeabi-v7a arm64-v8a universal; do
  apk="app-$target-release.apk"
  abis="$target"
  if [[ "$target" == "universal" ]]; then
    apk=app-release.apk
    abis=armeabi-v7a,arm64-v8a
  fi
  if [[ ! -f "$OUTPUT_DIR/$apk" ]]; then
    echo "Error: expected APK was not created: $OUTPUT_DIR/$apk" >&2
    exit 1
  fi
  python3 scripts/check_backend_apk.py "$OUTPUT_DIR/$apk" \
    --backend rust --abis "$abis" "${AUDIT_FLAGS[@]}"
done

echo "Built Android release APKs in $OUTPUT_DIR"
