import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../pwa/pwa.dart';
import 'runtime_version.dart';

/// Reads `build.json`, written by mnscloud-webapps next to `index.html` of the
/// active release, so the version is the one a reload would load.
Future<RuntimeReleaseInfo?> fetchLatestRuntimeRelease(String product) async {
  try {
    final base = Uri.parse(web.document.baseURI);
    final url = base
        .resolve('build.json')
        .replace(
          queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'},
        );
    final response = await web.window
        .fetch(
          url.toString().toJS,
          web.RequestInit(cache: 'no-store', credentials: 'omit'),
        )
        .toDart;
    if (!response.ok) return null;

    final body = (await response.text().toDart).toDart;
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['product'] != product) return null;

    final version = normalizeVersion(decoded['version']?.toString());
    if (!isReleaseVersion(version)) return null;
    final buildRef = decoded['ref']?.toString().trim();
    final minimum = normalizeVersion(decoded['minimumVersion']?.toString());
    return RuntimeReleaseInfo(
      version: version,
      buildRef: buildRef == null || buildRef.isEmpty ? null : buildRef,
      minimumVersion: isReleaseVersion(minimum) ? minimum : null,
    );
  } catch (_) {
    return null;
  }
}

/// Calls [onVisible] whenever the tab becomes visible again.
void listenPageVisible(void Function() onVisible) {
  web.document.addEventListener(
    'visibilitychange',
    ((web.Event _) {
      if (web.document.visibilityState == 'visible') onVisible();
    }).toJS,
  );
  web.window.addEventListener('online', ((web.Event _) => onVisible()).toJS);
}

bool isPageVisible() => web.document.visibilityState == 'visible';

/// Activates the waiting PWA revision (service worker) and reloads; plain reload without it.
void reloadPage() => pwaApplyUpdate();
