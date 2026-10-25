import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/ids.dart';

/// Signed-in tenant context kept between launches.
class FieldSession {
  const FieldSession({
    required this.baseUrl,
    required this.token,
    required this.environmentUuid,
    required this.environmentName,
  });

  final String baseUrl;
  final String token;
  final String environmentUuid;
  final String environmentName;
}

/// Platform secure storage (Keychain / Android Keystore) for the session token and the key of each
/// tenant's local database. Nothing secret is written to SQLite or to plain files.
class SessionVault {
  SessionVault([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<FieldSession?> read() async {
    final values = await _storage.readAll();
    final baseUrl = values['baseUrl'];
    final token = values['token'];
    final environment = values['environmentUuid'];
    if (baseUrl == null || token == null || environment == null) return null;
    return FieldSession(
      baseUrl: baseUrl,
      token: token,
      environmentUuid: environment,
      environmentName: values['environmentName'] ?? environment,
    );
  }

  Future<void> save(FieldSession session) async {
    await _storage.write(key: 'baseUrl', value: session.baseUrl);
    await _storage.write(key: 'token', value: session.token);
    await _storage.write(key: 'environmentUuid', value: session.environmentUuid);
    await _storage.write(key: 'environmentName', value: session.environmentName);
  }

  /// Sign out keeps the encrypted tenant data for the next sign-in; the token goes.
  Future<void> signOut() => _storage.delete(key: 'token');

  Future<String?> lastBaseUrl() => _storage.read(key: 'baseUrl');

  /// Key of the tenant database, created on first use.
  Future<String> databaseKey(String environmentUuid) async {
    final name = 'db:$environmentUuid';
    final existing = await _storage.read(key: name);
    if (existing != null && existing.isNotEmpty) return existing;
    final key = newSecret();
    await _storage.write(key: name, value: key);
    return key;
  }

  /// Remote wipe: the tenant key goes with its data.
  Future<void> forgetTenant(String environmentUuid) async {
    await _storage.delete(key: 'db:$environmentUuid');
    await _storage.delete(key: 'token');
    await _storage.delete(key: 'environmentUuid');
  }
}
