import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/ids.dart';

/// Signed-in tenant context kept between launches. [refreshToken] is the rotating token of the
/// field session (native only; the web keeps it in an HttpOnly cookie). [token] is the short access
/// token in memory, or the platform token a session of an older version saved.
class FieldSession {
  const FieldSession({
    required this.baseUrl,
    this.token,
    this.refreshToken,
    required this.environmentUuid,
    required this.environmentName,
  });

  final String baseUrl;
  final String? token;
  final String? refreshToken;
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
    final refresh = values['refreshToken'];
    final environment = values['environmentUuid'];
    final signedIn = token != null || refresh != null || values['fieldSession'] == '1';
    if (baseUrl == null || environment == null || !signedIn) return null;
    return FieldSession(
      baseUrl: baseUrl,
      token: token,
      refreshToken: refresh,
      environmentUuid: environment,
      environmentName: values['environmentName'] ?? environment,
    );
  }

  /// The access token is never stored: it lasts minutes and the refresh token renews it.
  Future<void> save(FieldSession session) async {
    await _storage.write(key: 'baseUrl', value: session.baseUrl);
    await _storage.delete(key: 'token');
    await saveRefreshToken(session.refreshToken);
    await _storage.write(key: 'fieldSession', value: '1');
    await _storage.write(key: 'environmentUuid', value: session.environmentUuid);
    await _storage.write(key: 'environmentName', value: session.environmentName);
  }

  /// Each refresh rotates the token: the new one replaces the old (null when the session ended).
  Future<void> saveRefreshToken(String? token) => token == null || token.isEmpty
      ? _storage.delete(key: 'refreshToken')
      : _storage.write(key: 'refreshToken', value: token);

  /// Sign out keeps the encrypted tenant data for the next sign-in; the tokens go.
  Future<void> signOut() async {
    await _storage.delete(key: 'token');
    await _storage.delete(key: 'refreshToken');
    await _storage.delete(key: 'fieldSession');
  }

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
    await signOut();
    await _storage.delete(key: 'environmentUuid');
  }
}
