#!/usr/bin/env bash
# Web build of the encrypted local database: SQLite3MultipleCiphers compiled to WebAssembly by
# package:sqlite3 (same version as pubspec.lock), served next to index.html as web/sqlite3mc.wasm.
# Re-run after bumping sqlite3 in pubspec.lock: downloads the matching release asset, checks it
# against the pinned SHA-256 below and fails when the version or the checksum does not match.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

VERSION="3.8.0"
SHA256="ae9072d27891dc29b3c5fa565f46e725fa6b72917e18e66abb5c775355f8e9a7"

locked="$(awk '/^  sqlite3:$/{found=1} found && /^    version:/{gsub(/"/,"",$2); print $2; exit}' pubspec.lock)"
[[ "$locked" == "$VERSION" ]] || { echo "pubspec.lock has sqlite3 $locked; update VERSION/SHA256 here" >&2; exit 1; }

if [[ "${1:-}" == "--check" ]]; then
  echo "${SHA256}  web/sqlite3mc.wasm" | sha256sum -c --quiet
  exit 0
fi
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl --proto '=https' -fsSL -o "$tmp" \
  "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${VERSION}/sqlite3mc.wasm"
echo "${SHA256}  ${tmp}" | sha256sum -c --quiet
install -m 0644 "$tmp" web/sqlite3mc.wasm
echo "web/sqlite3mc.wasm = sqlite3 ${VERSION}"
