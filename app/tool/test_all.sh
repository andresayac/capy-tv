#!/usr/bin/env bash
# Runs every test suite. Integration files run one at a time: on Windows desktop, several
# files in a single `flutter test` invocation hang when the second app instance starts.
set -euo pipefail
cd "$(dirname "$0")/.."

dart format --output=none --set-exit-if-changed lib test integration_test tool # as CI
flutter analyze
flutter test
if command -v go >/dev/null; then (cd ../server && go vet ./... && go test ./...); fi
# The Samsung TV app: its build (which writes src/gen/), its types, then its remote's focus and
# its player in this machine's Edge, against a panel of their own (no TV, no provider). Skipped
# until its npm install is done
if command -v node >/dev/null && [ -d ../tizen/node_modules ]; then
  (cd ../tizen && node scripts/build.mjs && node node_modules/typescript/bin/tsc --noEmit -p . &&
    node scripts/focus-test.mjs && node scripts/player-test.mjs)
fi

device="${1:-windows}"
# The TMDB key, like the provider account, comes from ../.env
defines=()
if [ -f ../.env ]; then defines+=(--dart-define-from-file=../.env); fi
failed=0 # one file failing does not stop the others
for f in integration_test/*_test.dart; do
  echo "== $f"
  # A previous run that crashed or timed out can leave the app open and block the next one
  if [ "$device" = windows ]; then taskkill //IM capy_tv.exe //F >/dev/null 2>&1 || true; fi
  flutter test "$f" -d "$device" "${defines[@]}" || failed=1
done
exit "$failed"
