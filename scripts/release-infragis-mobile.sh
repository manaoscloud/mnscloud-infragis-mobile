#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_runtime_kit() {
  local candidate
  for candidate in \
    "${MNSCLOUD_RUNTIME_KIT_DIR:-}" \
    "${ROOT_DIR}/../mnscloud-runtime-kit" \
    "/opt/mnscloud/runtime-kit" \
    "/opt/mnscloud/repos/mnscloud-runtime-kit"; do
    [[ -n "$candidate" && -r "${candidate}/lib/release.sh" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

cd "$ROOT_DIR"
RUNTIME_KIT_DIR="$(find_runtime_kit)" || {
  printf '[mnscloud-infragis-mobile] ERROR: mnscloud-runtime-kit lib/release.sh not found\n' >&2
  exit 1
}

# shellcheck source=/opt/mnscloud/runtime-kit/lib/release.sh
source "${RUNTIME_KIT_DIR}/lib/release.sh"

# Static web release artifact consumed by mnscloud-webapps (APP_SOURCE=release): an installable
# PWA (runtime-kit app-shell service worker, with the encrypted database engine precached so the
# installed app opens offline). Built with the same-origin API and a portable root base href; the
# hosting runtime rewrites <base href> to its own path.
export MNSCLOUD_RUNTIME_KIT_DIR="$RUNTIME_KIT_DIR"
pwa_generate='python3 "$MNSCLOUD_RUNTIME_KIT_DIR/scripts/flutter-pwa.py" generate --build-dir build/web --app infragis --precache sqlite3mc.wasm'
pwa_validate='python3 "$MNSCLOUD_RUNTIME_KIT_DIR/scripts/flutter-pwa.py" validate --build-dir build/web --base-href /'
package_web_artifact='"$MNSCLOUD_RUNTIME_KIT_DIR/scripts/package-static-artifact.sh" --source-dir build/web --name "mnscloud-infragis-mobile-web-v$(tr -d "[:space:]" < VERSION).tar.gz"'

mrtk_release_prepare \
  --product mnscloud-infragis-mobile \
  --repository manaoscloud/mnscloud-infragis-mobile \
  --minimum-version 0.1.0 \
  --sync-pubspec \
  --add-path lib/src/version/app_build_info.dart \
  --validate "grep -q '^version:' pubspec.yaml" \
  --validate "bash scripts/sync-app-build-info.sh" \
  --validate "bash scripts/fetch-sqlite-wasm.sh --check" \
  --validate "flutter pub get" \
  --validate "flutter build web --release --base-href / --no-web-resources-cdn" \
  --validate "grep -qF '<base href=\"/\">' build/web/index.html" \
  --validate "$pwa_generate" \
  --validate "$pwa_validate" \
  --validate "$package_web_artifact" \
  --asset-glob "releases/mnscloud-infragis-mobile-web-v*.tar.gz*" \
  "$@"
