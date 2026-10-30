#!/usr/bin/env bash
# Stamps the pubspec.yaml version into lib/src/version/app_build_info.dart, so the web bundle knows
# its own version and can compare it with the build.json of the release that is live.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
file="lib/src/version/app_build_info.dart"
version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | tr -d '[:space:]')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  { printf '[sync-app-build-info] invalid pubspec version: %s\n' "$version" >&2; exit 1; }
# Match the field wherever dart format puts it (one line or one argument per line).
[[ "$(grep -oE 'version: "[^"]*"' "$file" | wc -l)" == "1" ]] ||
  { printf '[sync-app-build-info] expected one version field in %s\n' "$file" >&2; exit 1; }
sed -i -E "s/version: \"[^\"]*\"/version: \"${version}\"/" "$file"
grep -qF "version: \"${version}\"" "$file" ||
  { printf '[sync-app-build-info] stamping failed\n' >&2; exit 1; }
printf '[sync-app-build-info] %s = %s\n' "$file" "$version"
