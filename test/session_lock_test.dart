import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnscloud_infragis_mobile/src/api/infragis_api.dart';
import 'package:mnscloud_infragis_mobile/src/data/session_vault.dart';
import 'package:mnscloud_infragis_mobile/src/field_controller.dart';
import 'package:mnscloud_infragis_mobile/src/security/app_lock.dart';

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

http.Response issued(String access, [String? refresh]) => http.Response(
      jsonEncode({
        'data': {'accessToken': access, 'refreshToken': refresh, 'expiresIn': 900},
      }),
      200,
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('PBKDF2-HMAC-SHA256 matches the published test vectors', () {
    expect(hex(pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    expect(hex(pbkdf2(utf8.encode('password'), utf8.encode('salt'), 2)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
  });

  test('the PIN is kept only as a salted hash and wrong PINs are counted', () async {
    final lock = AppLock(iterations: 1000);
    expect(AppLock.validPin('123'), isFalse);
    expect(AppLock.validPin('12a4'), isFalse);
    expect(AppLock.validPin('123456789'), isFalse);
    await lock.setPin('2468');
    final stored = await const FlutterSecureStorage().read(key: 'pin');
    expect(stored, startsWith(r'pbkdf2-sha256$1000$'));
    expect(stored, isNot(contains('2468')));
    expect(await lock.verify('2468'), isNull);
    expect(await lock.verify('1111'), AppLock.maxFailures - 1);
    expect(await lock.verify('1111'), AppLock.maxFailures - 2);
    // A right PIN resets the count.
    expect(await lock.verify('2468'), isNull);
    expect(await lock.verify('1111'), AppLock.maxFailures - 1);
  });

  test('a saved session with a PIN stays locked, and five wrong PINs sign out', () async {
    await const FlutterSecureStorage().write(key: 'baseUrl', value: 'https://dev.example/api/v1');
    await const FlutterSecureStorage().write(key: 'refreshToken', value: 'session.secret');
    await const FlutterSecureStorage().write(key: 'fieldSession', value: '1');
    await const FlutterSecureStorage().write(key: 'environmentUuid', value: 'tenant-a');
    final lock = AppLock(iterations: 1000);
    await lock.setPin('2468');
    final controller = FieldController(lock: lock);
    await controller.restore();
    expect(controller.locked, isTrue);
    expect(controller.store, isNull);
    for (var attempt = 1; attempt < AppLock.maxFailures; attempt++) {
      expect(await controller.unlock('0000'), AppLock.maxFailures - attempt);
      expect(controller.locked, isTrue);
    }
    expect(await controller.unlock('0000'), 0);
    expect(controller.locked, isFalse);
    expect(controller.signedIn, isFalse);
    expect(controller.notice, 'pinLocked');
    expect(await SessionVault().read(), isNull);
    expect(await lock.hasPin(), isFalse);
  });

  test('a 401 rotates the native refresh token once and repeats the request', () async {
    final seen = <String>[];
    String? saved;
    final client = MockClient((request) async {
      seen.add('${request.method} ${request.url.path} ${request.headers['authorization'] ?? '-'}');
      if (request.url.path.endsWith('/infragis/auth/refresh')) {
        expect(jsonDecode(request.body), {'refreshToken': 'r1'});
        return issued('a2', 'r2');
      }
      if (request.headers['authorization'] == 'Bearer a1') return http.Response('{"error":"expired"}', 401);
      return http.Response('{"data":{"config":{"provider":"none"}}}', 200);
    });
    final auth = FieldAuth(
      baseUrl: 'https://dev.example/api/v1',
      accessToken: 'a1',
      refreshToken: 'r1',
      client: client,
      web: false,
      onRotated: (token) async => saved = token,
    );
    final api = InfraGisApi(baseUrl: 'https://dev.example/api/v1', auth: auth, client: client).forTenant(auth, 'tenant-a');
    expect((await api.mapConfig())['provider'], 'none');
    expect(seen, [
      'GET /api/v1/infragis/map/config Bearer a1',
      'POST /api/v1/infragis/auth/refresh -',
      'GET /api/v1/infragis/map/config Bearer a2',
    ]);
    expect(saved, 'r2');
    expect(auth.refreshToken, 'r2');
  });

  test('a refused refresh ends the session without a retry loop', () async {
    var calls = 0;
    String? saved = 'r1';
    final client = MockClient((request) async {
      calls++;
      if (request.url.path.endsWith('/infragis/auth/refresh')) {
        // The web sends no token: the browser presents the HttpOnly cookie.
        expect(jsonDecode(request.body), <String, dynamic>{});
        return http.Response('{"code":"INFRAGIS_SESSION_INVALID"}', 401);
      }
      return http.Response('{"error":"expired"}', 401);
    });
    final auth = FieldAuth(
      baseUrl: 'https://dev.example/api/v1',
      accessToken: 'a1',
      client: client,
      web: true,
      onRotated: (token) async => saved = token,
    );
    final api = InfraGisApi(baseUrl: 'https://dev.example/api/v1', client: client).forTenant(auth, 'tenant-a');
    await expectLater(api.mapConfig(), throwsA(isA<ApiException>().having((e) => e.unauthorized, 'unauthorized', isTrue)));
    expect(calls, 2);
    expect(saved, isNull);
    expect(auth.accessToken, isNull);
  });

  test('sign-in uses the field session route and returns the native refresh token', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/infragis/auth/signin');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['email'], 'tecnico@example.invalid');
      expect(body['clientKind'], 'native');
      return issued('a1', 'r1');
    });
    final tokens = await InfraGisApi(baseUrl: 'https://dev.example/api/v1', client: client)
        .signIn('tecnico@example.invalid', 'secret', deviceName: 'android');
    expect(tokens.accessToken, 'a1');
    expect(tokens.refreshToken, 'r1');
  });

  test('the vault never stores the access token and keeps sessions of older versions', () async {
    final vault = SessionVault();
    await vault.save(const FieldSession(
      baseUrl: 'https://dev.example/api/v1',
      token: 'a1',
      refreshToken: 'r1',
      environmentUuid: 'tenant-a',
      environmentName: 'Tenant A',
    ));
    final values = await const FlutterSecureStorage().readAll();
    expect(values.containsKey('token'), isFalse);
    expect(values['refreshToken'], 'r1');
    final restored = (await vault.read())!;
    expect(restored.token, isNull);
    expect(restored.refreshToken, 'r1');
    await vault.signOut();
    expect(await vault.read(), isNull);

    // Saved by a version before the field sessions: the platform token keeps working until it expires.
    FlutterSecureStorage.setMockInitialValues({
      'baseUrl': 'https://dev.example/api/v1',
      'token': 'platform-jwt',
      'environmentUuid': 'tenant-a',
    });
    final legacy = (await SessionVault().read())!;
    expect(legacy.token, 'platform-jwt');
    expect(legacy.refreshToken, isNull);
  });
}
