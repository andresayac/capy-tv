#!/usr/bin/env bash
# Builds the Windows installer, CapyTV-Setup.exe, with the values from ../.env built in, as
# tool/build_apk.sh does: the TMDB key, the sync server the sign-in form starts with, and the
# language model; never the provider accounts there for the tests. Leaves it (git-ignored) at the
# repository root, and adds it to ../release/app/ as "windows-x64", for the computers signed in to the
# sync server to update themselves (see server/README.md, "App updates").
#
# It joins the release tool/build_apk.sh made: run that first, so the installer has the APKs'
# build number (BUILD_NUMBER overrides it). A release of another number keeps no installer: one
# offered under a newer number than it has would be offered again and again.
#
# Needs Inno Setup 6 (winget install JRSoftware.InnoSetup), besides what flutter build windows
# needs (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

iscc=$(command -v iscc || true)
for candidate in "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe" \
  "${LOCALAPPDATA:-}/Programs/Inno Setup 6/ISCC.exe"; do
  [ -z "$iscc" ] && [ -f "$candidate" ] && iscc=$candidate
done
if [ -z "$iscc" ]; then
  echo "No Inno Setup 6 (ISCC.exe): winget install JRSoftware.InnoSetup" >&2
  exit 1
fi

published=$(sed -n 's/.*"build": *\([0-9]*\).*/\1/p' ../release/app/app.json 2>/dev/null || true)
build=${BUILD_NUMBER:-$published}
if [ -z "$build" ]; then
  echo "No ../release/app/app.json to join: run tool/build_apk.sh first, or give BUILD_NUMBER" >&2
  exit 1
fi
version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
echo "Version $version, build $build"

defines=$(mktemp)
out=$(mktemp -d)
trap 'rm -f "$defines"; rm -rf "$out"' EXIT
if [ -f ../.env ]; then
  grep -E '^(TMDB_API_KEY|SYNC_SERVER|AI_BASE_URL|AI_MODEL|AI_API_KEY)=' ../.env > "$defines" || true
else
  echo "WARNING: no ../.env, so this build has no TMDB key and no sync server built in" >&2
fi
echo "Built in: $(cut -d= -f1 "$defines" | tr '\n' ' ')"

# The versions pubspec.lock says: nothing is built with a newer dependency nobody tried
flutter pub get --enforce-lockfile
flutter build windows --release --build-number="$build" --dart-define-from-file="$defines" \
  --dart-define=COMMIT="$(git rev-parse --short HEAD)"

# Inno Setup's switches start with "/": not paths for Git Bash to rewrite
MSYS_NO_PATHCONV=1 "$iscc" /Q "/DVersion=$version" "/DBuild=$build" \
  "/DSource=$(cygpath -w "$PWD/build/windows/x64/runner/Release")" "/DOutput=$(cygpath -w "$out")" \
  "$(cygpath -w "$PWD/windows/installer/capy_tv.iss")"
cp "$out/CapyTV-Setup.exe" ../CapyTV-Setup.exe
echo "Ready: CapyTV-Setup.exe at the repository root"

if [ "$build" = "$published" ]; then
  cp "$out/CapyTV-Setup.exe" ../release/app/CapyTV-Setup.exe
  # In the manifest once, beside the APKs: an entry left from before goes first
  sed -i -e 's/"windows-x64": *"[^"]*", *//; s/, *"windows-x64": *"[^"]*"//' \
    -e 's/"files": *{/"files": {"windows-x64": "CapyTV-Setup.exe", /; s/, *}/}/' ../release/app/app.json
  echo "For the sync server: release/app/ (now with CapyTV-Setup.exe as windows-x64)"
else
  echo "Not added to release/app/: its build is ${published:-none}, this one $build" >&2
fi
