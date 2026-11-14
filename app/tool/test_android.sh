#!/usr/bin/env bash
# Runs the integration tests on an Android phone, TV or emulator, then pulls the journey
# screenshots to build/screenshots/android/.
#   tool/test_android.sh [device-id]          (needed when adb lists more than one)
# The device cannot read ../.env, so its values are passed as defines.
# Tests use the software decoder, as emulators' hardware decoders stall on some streams; on a
# real device set HW_DECODER=1 to test the hardware decoder the app uses by default.
set -euo pipefail
cd "$(dirname "$0")/.."

adb="${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}/platform-tools/adb"
devices=$("$adb" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
if [ -z "${1:-}" ] && [ "$(echo "$devices" | wc -l)" -gt 1 ]; then
  echo "More than one device, say which:" $devices >&2
  exit 1
fi
device="${1:-$devices}"
defines=()
if [ -n "${HW_DECODER:-}" ]; then defines+=(--dart-define=HW_DECODER=true); fi
if [ -f ../.env ]; then defines+=(--dart-define-from-file=../.env); fi

failed=0 # one file failing does not stop the others, nor the screenshots coming
for f in integration_test/*_test.dart; do
  echo "== $f on $device"
  flutter test "$f" -d "$device" --no-uninstall "${defines[@]}" || failed=1 # keep the app: screenshots live in its folder
done

out=build/screenshots/android
rm -rf "$out" && mkdir -p "$out"
MSYS_NO_PATHCONV=1 "$adb" -s "$device" pull /sdcard/Android/data/com.capytv.app.test/files/screenshots/. "$out" >/dev/null
echo "Screenshots in $out"
exit "$failed"
