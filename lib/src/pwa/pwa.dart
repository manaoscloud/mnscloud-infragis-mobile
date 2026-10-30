// Installed web app (PWA) bridge: install state and prompt, and update activation. Native and
// test builds report [PwaInstallState.unavailable] and reload is a no-op.
export 'pwa_stub.dart' if (dart.library.js_interop) 'pwa_web.dart';

/// installed | available (browser prompt ready) | ios (Add to Home Screen steps) | unavailable.
enum PwaInstallState { installed, available, ios, unavailable }

PwaInstallState parsePwaInstallState(String? value) => switch (value) {
      'installed' => PwaInstallState.installed,
      'available' => PwaInstallState.available,
      'ios' => PwaInstallState.ios,
      _ => PwaInstallState.unavailable,
    };
