#!/usr/bin/env bash
# Builds the release APK to install, with the values from ../.env built in: the TMDB key, the
# sync server the sign-in form starts with, and the language model. Only those: the provider
# accounts in .env are for the tests and never go into the app. Leaves the APKs (git-ignored) at
# the repository root.
#   tool/build_apk.sh          CapyTV.apk: one file for phones, tablets, Android TV and Fire TV
#   tool/build_apk.sh small    one smaller file per processor, to send over a chat:
#                              CapyTV-64bit.apk (phones and tablets) and
#                              CapyTV-32bit.apk (Fire TV, TVs and Android boxes: many run a 32-bit Android on a 64-bit chip)
# All of them carry the same version, so any of them installs over another. The build number is
# the count of commits, or one more than the last build when that is not lower (BUILD_NUMBER
# overrides it), so each build is newer than the one before, from any worktree.
# ../release/app/ gets the same APKs and an app.json: what goes on the sync server for the devices to
# update themselves (see server/README.md, "App updates"). It is replaced only when all went well.
# Signed with android/key.properties (see README). Without it the script stops, as devices would
# refuse the APK as an update; ALLOW_DEBUG_KEY=1 builds with the debug key anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f android/key.properties ] && [ -z "${ALLOW_DEBUG_KEY:-}" ]; then
  echo "No android/key.properties: devices would refuse this APK as an update. ALLOW_DEBUG_KEY=1 builds it anyway." >&2
  exit 1
fi

# Devices only take a higher number. The last one is kept next to git's own files, which every
# worktree shares, and what is published counts too
counter="$(git rev-parse --git-common-dir)/capy-last-build"
published=$(sed -n 's/.*"build": *\([0-9]*\).*/\1/p' ../release/app/app.json 2>/dev/null || true)
last=$(cat "$counter" 2>/dev/null || echo 0)
last=$(( last > ${published:-0} ? last : ${published:-0} ))
commits=$(git rev-list --count HEAD)
build=${BUILD_NUMBER:-$(( commits > last ? commits : last + 1 ))}
version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
echo "Version $version, build $build"
next=../release/app.tmp
rm -rf "$next"
mkdir -p "$next"

defines=$(mktemp)
trap 'rm -f "$defines"; rm -rf "$next"' EXIT
if [ -f ../.env ]; then
  grep -E '^(TMDB_API_KEY|SYNC_SERVER|AI_BASE_URL|AI_MODEL|AI_API_KEY)=' ../.env > "$defines" || true
else
  echo "WARNING: no ../.env, so this APK has no TMDB key and no sync server built in" >&2
fi
echo "Built in: $(cut -d= -f1 "$defines" | tr '\n' ' ')"

# The versions pubspec.lock says: an APK is not built with a newer dependency nobody tried
flutter pub get --enforce-lockfile

out=build/app/outputs/flutter-apk/app-release.apk
if [ "${1:-}" = small ]; then
  for target in "android-arm64 64bit" "android-arm 32bit"; do
    set -- $target
    flutter build apk --release --target-platform "$1" --build-number="$build" --dart-define-from-file="$defines" --dart-define=COMMIT="$(git rev-parse --short HEAD)"
    cp "$out" "../CapyTV-$2.apk"
    cp "$out" "$next/CapyTV-$2.apk"
  done
  files='"arm64-v8a": "CapyTV-64bit.apk", "armeabi-v7a": "CapyTV-32bit.apk"'
  echo "Ready: CapyTV-64bit.apk and CapyTV-32bit.apk at the repository root"
else
  flutter build apk --release --build-number="$build" --dart-define-from-file="$defines" --dart-define=COMMIT="$(git rev-parse --short HEAD)"
  cp "$out" ../CapyTV.apk
  cp "$out" "$next/CapyTV.apk"
  files='"universal": "CapyTV.apk"'
  echo "Ready: CapyTV.apk at the repository root"
fi
printf '{"version": "%s", "build": %s, "files": {%s}}\n' "$version" "$build" "$files" > "$next/app.json"
rm -rf ../release/app && mv "$next" ../release/app # release/sync/, the server's, stays
echo "$build" > "$counter"
echo "For the sync server: release/app/ (the APKs and app.json)"
