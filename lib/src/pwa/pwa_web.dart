import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'pwa.dart';

/// `window.mnscloudPwa`, appended to flutter_bootstrap.js by the runtime-kit PWA tooling.
JSObject? get _bridge {
  final value = globalContext['mnscloudPwa'];
  return value.isA<JSObject>() ? value as JSObject : null;
}

PwaInstallState pwaInstallState() {
  final bridge = _bridge;
  if (bridge == null) return PwaInstallState.unavailable;
  try {
    final state = bridge.callMethod<JSString>('installState'.toJS);
    return parsePwaInstallState(state.toDart);
  } catch (_) {
    return PwaInstallState.unavailable;
  }
}

/// Opens the browser install prompt; true when the user accepted.
Future<bool> pwaPromptInstall() async {
  final bridge = _bridge;
  if (bridge == null) return false;
  try {
    final outcome = await bridge.callMethod<JSPromise<JSString>>('promptInstall'.toJS).toDart;
    return outcome.toDart == 'accepted';
  } catch (_) {
    return false;
  }
}

void pwaOnInstallChange(void Function() listener) {
  final bridge = _bridge;
  if (bridge == null) return;
  bridge.callMethod<JSAny?>('onInstallChange'.toJS, ((JSString _) => listener()).toJS);
}

/// "Update now": activates the waiting service worker revision and reloads (plain reload when the
/// page is not controlled by the MNSCloud service worker).
Future<void> pwaApplyUpdate() async {
  final bridge = _bridge;
  if (bridge == null) {
    web.window.location.reload();
    return;
  }
  try {
    await bridge.callMethod<JSPromise<JSAny?>>('applyUpdate'.toJS).toDart;
  } catch (_) {
    web.window.location.reload();
  }
}
