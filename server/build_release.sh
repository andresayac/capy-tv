#!/usr/bin/env bash
# Builds the sync server for Linux, on any machine, into ../release/sync/ (git-ignored), beside the
# app's release in ../release/app/: sync-server-linux-amd64 (most servers) and
# sync-server-linux-arm64 (a Raspberry Pi, ARM machines), the source they were built from
# (server-src.tar.gz) and the commit (COMMIT). Pure Go with no C, so nothing of this machine goes
# into them: -trimpath leaves out its paths too.
set -euo pipefail
cd "$(dirname "$0")"
out=../release/sync
next=../release/sync.tmp
rm -rf "$next"
mkdir -p "$next"
trap 'rm -rf "$next"' EXIT
commit=$(git rev-parse --short HEAD)
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags="-s -w" -o "$next/sync-server-linux-$arch" .
done
git archive --format=tar.gz -o "$next/server-src.tar.gz" HEAD .
if ! git diff --quiet HEAD -- .; then
  echo "WARNING: server/ has changes not committed: the binaries have them, the source archive does not" >&2
  commit="$commit+changes"
fi
echo "$commit" > "$next/COMMIT"
rm -rf "$out" && mv "$next" "$out"
echo "Ready: release/sync/ (built from $commit)"
