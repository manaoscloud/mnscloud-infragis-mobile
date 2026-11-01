import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnscloud_infragis_mobile/src/api/infragis_api.dart';
import 'package:mnscloud_infragis_mobile/src/data/session_vault.dart';
import 'package:mnscloud_infragis_mobile/src/data/store_name.dart';
import 'package:mnscloud_infragis_mobile/src/field_controller.dart';
import 'package:mnscloud_infragis_mobile/src/security/app_lock.dart';

const base = 'https://dev.example/api/v1';

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

Map<String, dynamic> account(String uuid, String name, {String? customer, int legacy = 0, int status = 1}) => {
      'IgcUUID': uuid,
      'IgcName': name,
      'CustomerName': customer,
      'IgcIsLegacy': legacy,
      'IgcStatus': status,
    };

InfraGisApi tenantApi(http.Client client, {String? accountUuid}) =>
    InfraGisApi(baseUrl: base, client: client).forTenant(
      FieldAuth(baseUrl: base, accessToken: 'access'),
      'tenant-a',
      accountUuid: accountUuid,
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('accounts are read from the operator scope, the legacy account flagged', () async {
    late http.Request seen;
    final api = tenantApi(MockClient((request) async {
      seen = request;
      return json({
        'data': {
          'items': [
            account('acc-own', 'INTERNAL LEGACY TENANT', legacy: 1),
            account('acc-c1', 'REDE CLIENTE', customer: 'CLIENTE UM'),
            {'IgcName': 'no uuid'},
          ],
        },
      });
    }));
    final options = await api.accounts();
    expect(seen.url.path, '/api/v1/infragis/accounts');
    expect(seen.url.queryParameters, {'status': '1', 'limit': '500'});
    expect(seen.headers['X-Environment-UUID'], 'tenant-a');
    expect(options.map((option) => option.uuid), ['acc-own', 'acc-c1']);
    expect(options.first.legacy, isTrue);
    expect(options.first.customer, isNull);
    expect(options.last.customer, 'CLIENTE UM');
  });

  test('an account out of scope (404) or deactivated is lost; other failures keep the copy', () async {
    Future<AccountState> stateFor(http.Response response) =>
        tenantApi(MockClient((_) async => response)).accountState('acc-c1');
    expect(await stateFor(json({'data': {'item': account('acc-c1', 'A')}})), AccountState.available);
    expect(await stateFor(json({'data': {'item': account('acc-c1', 'A', status: 0)}})), AccountState.lost);
    expect(await stateFor(json({'error': 'InfraGIS account not found'}, 404)), AccountState.lost);
    await expectLater(stateFor(json({'error': 'Forbidden'}, 403)), throwsA(isA<ApiException>()));
    await expectLater(stateFor(json({'error': 'down'}, 503)), throwsA(isA<ApiException>()));
  });

  test('sync pages carry the account of the copy, and none without one', () async {
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      return json({'data': {'items': [], 'cursor': 'c2', 'done': true}});
    });
    await tenantApi(client, accountUuid: 'acc-c1').bootstrap(null);
    await tenantApi(client, accountUuid: 'acc-c1').changes('c1', catalog: true);
    await tenantApi(client).changes('c1');
    expect(urls[0].queryParameters, {'accountUUID': 'acc-c1'});
    expect(urls[1].queryParameters, {'cursor': 'c1', 'catalog': '1', 'accountUUID': 'acc-c1'});
    expect(urls[2].queryParameters, {'cursor': 'c1'});
  });

  test('each account has its own key and file; losing one keeps the others', () async {
    final vault = SessionVault();
    const session = FieldSession(baseUrl: base, environmentUuid: 'tenant-a', environmentName: 'Tenant A');
    await vault.save(session.withAccount('acc-c1', 'REDE CLIENTE'));
    await vault.save(session.withAccount('acc-c2', null));
    final saved = (await vault.read())!;
    expect(saved.accountUuid, 'acc-c2');
    expect(saved.accountName, isNull);
    expect(await vault.accountCopies('tenant-a'), ['acc-c1', 'acc-c2']);

    final tenantWide = await vault.databaseKey('tenant-a');
    final first = await vault.databaseKey('tenant-a', 'acc-c1');
    final second = await vault.databaseKey('tenant-a', 'acc-c2');
    expect({tenantWide, first, second}.length, 3);
    expect(await vault.databaseKey('tenant-a', 'acc-c1'), first);
    expect(await vault.hasTenantWideCopy('tenant-a'), isTrue);

    await vault.forgetAccount('tenant-a', 'acc-c2');
    expect(await vault.accountCopies('tenant-a'), ['acc-c1']);
    expect((await vault.read())!.accountUuid, isNull);
    expect(await vault.databaseKey('tenant-a', 'acc-c1'), first);
    expect(await vault.databaseKey('tenant-a', 'acc-c2'), isNot(second));

    await vault.forgetAccount('tenant-a', null);
    expect(await vault.hasTenantWideCopy('tenant-a'), isFalse);

    await vault.forgetTenant('tenant-a');
    expect(await vault.accountCopies('tenant-a'), isEmpty);
    expect(await vault.databaseKey('tenant-a', 'acc-c1'), isNot(first));
  });

  test('the copy of an account is a file of its own; the tenant-wide name is kept', () {
    expect(storeFileName('tenant-a', null), 'infragis-tenant-a.db');
    expect(storeFileName('tenant-a', 'acc-c1'), 'infragis-tenant-a-acc-c1.db');
  });

  test('with several accounts the operator chooses before any copy opens', () async {
    final controller = FieldController(
      lock: AppLock(iterations: 1000),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/infragis/accounts')) {
          return json({
            'data': {
              'items': [account('acc-own', 'INTERNAL LEGACY', legacy: 1), account('acc-c1', 'REDE CLIENTE')],
            },
          });
        }
        return json({'data': {}});
      }),
    );
    await controller.signIn(const FieldSession(
      baseUrl: base,
      token: 'access',
      refreshToken: 'refresh',
      environmentUuid: 'tenant-a',
      environmentName: 'Tenant A',
    ));
    expect(controller.needsAccount, isTrue);
    expect(controller.accountChoices.map((option) => option.uuid), ['acc-own', 'acc-c1']);
    expect(controller.store, isNull);
    expect(controller.signedIn, isFalse);
    expect(await controller.switchAccount(), isNull);

    await controller.signOut();
    expect(controller.needsAccount, isFalse);
    expect(controller.accountChoices, isEmpty);
  });
}
