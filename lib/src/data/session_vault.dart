import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/ids.dart';

/// Signed-in tenant context kept between launches. [refreshToken] is the rotating token of the
/// field session (native only; the web keeps it in an HttpOnly cookie). [token] is the short access
/// token in memory, or the platform token a session of an older version saved. [accountUuid] is the
/// InfraGIS account of the local copy; null (sessions of older versions, servers without accounts)
/// keeps one copy of every account the operator may use.
class FieldSession {
  const FieldSession({
    required this.baseUrl,
    this.token,
    this.refreshToken,
    required this.environmentUuid,
    required this.environmentName,
    this.accountUuid,
    this.accountName,
  });

  final String baseUrl;
  final String? token;
  final String? refreshToken;
  final String environmentUuid;
  final String environmentName;
  final String? accountUuid;
  final String? accountName;

  FieldSession withAccount(String? uuid, String? name) => FieldSession(
        baseUrl: baseUrl,
        token: token,
        refreshToken: refreshToken,
        environmentUuid: environmentUuid,
        environmentName: environmentName,
        accountUuid: uuid,
        accountName: name,
      );
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
      accountUuid: values['accountUuid'],
      accountName: values['accountName'],
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
    await _optional('accountUuid', session.accountUuid);
    await _optional('accountName', session.accountName);
    if (session.accountUuid case final account?) await _remember(session.environmentUuid, account);
  }

  Future<void> _optional(String key, String? value) => value == null || value.isEmpty
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);

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

  /// Key of the database of a tenant (and account), created on first use.
  Future<String> databaseKey(String environmentUuid, [String? accountUuid]) async {
    final name = _keyName(environmentUuid, accountUuid);
    final existing = await _storage.read(key: name);
    if (existing != null && existing.isNotEmpty) return existing;
    final key = newSecret();
    await _storage.write(key: name, value: key);
    return key;
  }

  static String _keyName(String environmentUuid, String? accountUuid) =>
      accountUuid == null ? 'db:$environmentUuid' : 'db:$environmentUuid:$accountUuid';

  /// A copy of every account of the tenant (versions without accounts) is still on the device.
  Future<bool> hasTenantWideCopy(String environmentUuid) async =>
      (await _storage.read(key: _keyName(environmentUuid, null)))?.isNotEmpty ?? false;

  /// Accounts of the tenant with a local copy on this device (the web cannot list its files).
  Future<List<String>> accountCopies(String environmentUuid) async =>
      ((await _storage.read(key: 'copies:$environmentUuid')) ?? '')
          .split(',')
          .where((value) => value.isNotEmpty)
          .toList();

  Future<void> _remember(String environmentUuid, String accountUuid) async {
    final copies = await accountCopies(environmentUuid);
    if (copies.contains(accountUuid)) return;
    await _storage.write(key: 'copies:$environmentUuid', value: [...copies, accountUuid].join(','));
  }

  /// The copy of one account left the device (account lost, or the tenant-wide copy replaced by an
  /// account copy when [accountUuid] is null): its key goes, and the session forgets the account.
  Future<void> forgetAccount(String environmentUuid, String? accountUuid) async {
    await _storage.delete(key: _keyName(environmentUuid, accountUuid));
    if (accountUuid == null) return;
    final copies = await accountCopies(environmentUuid);
    await _optional('copies:$environmentUuid', copies.where((value) => value != accountUuid).join(','));
    if (await _storage.read(key: 'accountUuid') == accountUuid) {
      await _storage.delete(key: 'accountUuid');
      await _storage.delete(key: 'accountName');
    }
  }

  /// Remote wipe: the keys of the tenant (and of its account copies) go with their data.
  Future<void> forgetTenant(String environmentUuid) async {
    for (final account in await accountCopies(environmentUuid)) {
      await _storage.delete(key: _keyName(environmentUuid, account));
    }
    await _storage.delete(key: 'copies:$environmentUuid');
    await _storage.delete(key: 'db:$environmentUuid');
    await signOut();
    await _storage.delete(key: 'environmentUuid');
    await _storage.delete(key: 'accountUuid');
    await _storage.delete(key: 'accountName');
  }
}
