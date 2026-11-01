import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Local unlock of the field app (docs/security.md): a PIN, and the device biometrics where the
/// platform has them, gate opening the encrypted tenant copy after the app was closed or stayed
/// in the background. The PIN never leaves the device and is kept only as a PBKDF2-HMAC-SHA256
/// hash in the platform secure storage; [maxFailures] wrong PINs in a row sign out (the copy
/// stays encrypted on the device, the session tokens go).
class AppLock {
  AppLock({FlutterSecureStorage? storage, this.biometrics, this.iterations = 60000})
      : _storage = storage ?? const FlutterSecureStorage();

  static const maxFailures = 5;
  static const minLength = 4;
  static const maxLength = 8;

  /// Background time after which the app asks for the PIN again.
  static const idle = Duration(minutes: 5);

  final FlutterSecureStorage _storage;
  /// Device authentication (tests replace it); null uses the platform plugin.
  final LocalAuthentication? biometrics;
  final int iterations;

  static bool validPin(String pin) => RegExp('^[0-9]{$minLength,$maxLength}\$').hasMatch(pin);

  Future<bool> hasPin() async => (await _storage.read(key: 'pin')) != null;

  Future<void> setPin(String pin) async {
    if (!validPin(pin)) throw ArgumentError('PIN must have $minLength to $maxLength digits.');
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final hash = pbkdf2(utf8.encode(pin), salt, iterations);
    await _storage.write(key: 'pin', value: 'pbkdf2-sha256\$$iterations\$${base64Encode(salt)}\$${base64Encode(hash)}');
    await _storage.delete(key: 'pinFailures');
  }

  /// Checks the PIN; a wrong one counts towards [maxFailures]. Returns the failures left, or null
  /// when the PIN is right.
  Future<int?> verify(String pin) async {
    final stored = await _storage.read(key: 'pin');
    final parts = stored?.split('\$') ?? const [];
    if (parts.length == 4 && parts[0] == 'pbkdf2-sha256') {
      final rounds = int.tryParse(parts[1]) ?? iterations;
      final hash = pbkdf2(utf8.encode(pin), base64Decode(parts[2]), rounds);
      if (_same(hash, base64Decode(parts[3]))) {
        await _storage.delete(key: 'pinFailures');
        return null;
      }
    }
    final failures = (int.tryParse(await _storage.read(key: 'pinFailures') ?? '') ?? 0) + 1;
    await _storage.write(key: 'pinFailures', value: '$failures');
    return max(0, maxFailures - failures);
  }

  /// Too many wrong PINs or a sign-out: the PIN goes with the session.
  Future<void> clear() async {
    await _storage.delete(key: 'pin');
    await _storage.delete(key: 'pinFailures');
    await _storage.delete(key: 'biometrics');
  }

  bool get biometricsPlatform =>
      !kIsWeb &&
      const {TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.windows}
          .contains(defaultTargetPlatform);

  /// The device can unlock with biometrics (or its own credential) and the user turned it on.
  Future<bool> biometricsEnabled() async =>
      (await _storage.read(key: 'biometrics')) == '1' && await biometricsAvailable();

  Future<bool> biometricsAvailable() async {
    if (!biometricsPlatform) return false;
    try {
      final auth = biometrics ?? LocalAuthentication();
      return await auth.isDeviceSupported() && (await auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> setBiometrics(bool enabled) =>
      enabled ? _storage.write(key: 'biometrics', value: '1') : _storage.delete(key: 'biometrics');

  Future<bool> unlockWithBiometrics(String reason) async {
    try {
      return await (biometrics ?? LocalAuthentication()).authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// PBKDF2-HMAC-SHA256 (RFC 8018), one 32-byte block.
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = Uint8List.fromList(block);
  for (var i = 1; i < iterations; i++) {
    block = hmac.convert(block).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= block[j];
    }
  }
  return result;
}
