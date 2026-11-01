import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnscloud_infragis_mobile/src/api/infragis_api.dart';
import 'package:mnscloud_infragis_mobile/src/api/mns_client.dart';
import 'package:mnscloud_infragis_mobile/src/version/app_build_info.dart';
import 'package:mnscloud_infragis_mobile/src/version/app_update_controller.dart';
import 'package:mnscloud_infragis_mobile/src/version/app_update_overlay.dart';
import 'package:mnscloud_infragis_mobile/src/version/client_policy.dart';
import 'package:mnscloud_infragis_mobile/src/version/runtime_version.dart';

const _policyBody =
    '{"status":"success","data":{"app":"infragis-mobile","product":"mnscloud-infragis-mobile","latest":"0.2.0",'
    '"minimum":{"android":"0.1.5","ios":null,"windows":"0.1.0","macos":null,"linux":null}}}';

AppUpdateController _native(String platformName, {ClientPolicyReader? policy, ValueNotifier<bool>? unsupported}) =>
    AppUpdateController(
      web: false,
      platformName: platformName,
      runningVersion: '0.1.2',
      unsupported: unsupported ?? ValueNotifier<bool>(false),
      policyReader: policy ?? () async => ClientPolicy.fromData(_decodeData(_policyBody)),
    );

Object? _decodeData(String body) => (jsonDecode(body) as Map)['data'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('client headers', () {
    test('every API request carries the client identity and platform', () async {
      final seen = <http.BaseRequest>[];
      final api = InfraGisApi(
        baseUrl: 'https://api.example.test/api/v1',
        client: MockClient((request) async {
          seen.add(request);
          return http.Response('{"data":{"items":[]}}', 200);
        }),
      );
      await api.listAccess();
      final headers = seen.single.headers;
      expect(headers['X-Mns-Client'], '${appBuildInfo.product}/${appBuildInfo.version}');
      expect(headers['X-Mns-Client'], startsWith('mnscloud-infragis-mobile/'));
      expect(headers['X-Mns-Client-Platform'], isNotEmpty);
    });

    test('the session refresh carries them too', () async {
      final seen = <http.BaseRequest>[];
      final auth = FieldAuth(
        baseUrl: 'https://api.example.test/api/v1',
        refreshToken: 'r1',
        web: false,
        client: MockClient((request) async {
          seen.add(request);
          return http.Response('{"data":{"accessToken":"a2","refreshToken":"r2"}}', 200);
        }),
      );
      expect(await auth.refresh(), isTrue);
      expect(seen.single.headers['X-Mns-Client'], startsWith('mnscloud-infragis-mobile/'));
    });

    test('platform names follow the API contract', () {
      expect(clientPlatform(web: true), 'web');
      expect(clientPlatform(web: false, target: TargetPlatform.android), 'android');
      expect(clientPlatform(web: false, target: TargetPlatform.iOS), 'ios');
      expect(clientPlatform(web: false, target: TargetPlatform.windows), 'windows');
      expect(clientPlatform(web: false, target: TargetPlatform.macOS), 'macos');
      expect(clientPlatform(web: false, target: TargetPlatform.linux), 'linux');
    });

    test('a 426 CLIENT_VERSION_UNSUPPORTED raises the signal and the call still fails', () async {
      final unsupported = ValueNotifier<bool>(false);
      final client = MnsApiClient(
        MockClient((_) async => http.Response('{"status":"error","code":"CLIENT_VERSION_UNSUPPORTED"}', 426)),
        unsupported: unsupported,
      );
      final api = InfraGisApi(baseUrl: 'https://api.example.test/api/v1', client: client);
      await expectLater(api.listAccess(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 426)));
      expect(unsupported.value, isTrue);
    });

    test('another 426 does not raise the signal', () async {
      final unsupported = ValueNotifier<bool>(false);
      final client = MnsApiClient(
        MockClient((_) async => http.Response('{"error":"x"}', 426)),
        unsupported: unsupported,
      );
      await client.get(Uri.parse('https://api.example.test/api/v1/user/access'));
      expect(unsupported.value, isFalse);
    });
  });

  group('client policy', () {
    test('reads the policy from the API base with the client headers', () async {
      http.BaseRequest? seen;
      final policy = await fetchClientPolicy(
        () async => 'https://api.example.test/api/v1/',
        client: MockClient((request) async {
          seen = request;
          return http.Response(_policyBody, 200);
        }),
      );
      expect(seen!.url.toString(), 'https://api.example.test/api/v1/public/clients/infragis-mobile/policy');
      expect(seen!.headers['X-Mns-Client'], startsWith('mnscloud-infragis-mobile/'));
      expect(policy!.latest, '0.2.0');
      expect(policy.minimum, {'android': '0.1.5', 'windows': '0.1.0'});
    });

    test('no API base yet or a failure reads nothing', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls += 1;
        return http.Response('down', 503);
      });
      expect(await fetchClientPolicy(() async => null, client: client), isNull);
      expect(calls, 0);
      expect(await fetchClientPolicy(() async => 'https://api.example.test/api/v1', client: client), isNull);
      expect(calls, 1);
    });
  });

  group('installed app', () {
    test('below the platform minimum the notice is critical', () async {
      final controller = _native('android');
      await controller.check(force: true);
      expect(controller.critical, isTrue);
      expect(controller.noticeVisible, isTrue);
      expect(controller.noticeVersion, '0.2.0');
    });

    test('at or above the platform minimum, or without one, nothing shows', () async {
      for (final platformName in ['windows', 'ios', 'macos', 'linux']) {
        final controller = _native(platformName);
        await controller.check(force: true);
        expect(controller.critical, isFalse, reason: platformName);
        expect(controller.noticeVisible, isFalse, reason: platformName);
      }
    });

    test('a failed policy read fails open', () async {
      final failing = _native('android', policy: () async => throw Exception('offline'));
      await failing.check(force: true);
      expect(failing.noticeVisible, isFalse);
      final empty = _native('android', policy: () async => null);
      await empty.check(force: true);
      expect(empty.noticeVisible, isFalse);
    });

    test('a 426 from the API marks the notice critical', () async {
      final unsupported = ValueNotifier<bool>(false);
      final controller = _native('ios', unsupported: unsupported);
      var notified = 0;
      controller.addListener(() => notified += 1);
      controller.start();
      await controller.check(force: true);
      expect(controller.critical, isFalse);
      unsupported.value = true;
      expect(controller.critical, isTrue);
      expect(controller.noticeVisible, isTrue);
      expect(notified, greaterThan(0));
      controller.dispose();
    });

    testWidgets('the critical notice has no buttons on installed apps', (tester) async {
      final controller = _native('android');
      await controller.check(force: true);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en', 'US'),
          supportedLocales: const [Locale('en', 'US')],
          builder: (context, child) =>
              AppUpdateOverlay(busy: () => false, controller: controller, child: child ?? const SizedBox()),
          home: const Scaffold(),
        ),
      );
      await tester.pump();
      expect(find.textContaining('This app version is no longer supported'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  group('web build', () {
    test('ignores the client policy and the 426 signal; build.json still drives the notice', () async {
      final unsupported = ValueNotifier<bool>(true);
      final controller = AppUpdateController(
        web: true,
        runningVersion: '0.1.2',
        unsupported: unsupported,
        policyReader: () async => fail('the web build never reads the client policy'),
        reader: () async => const RuntimeReleaseInfo(version: '0.1.2'),
      );
      await controller.check(force: true);
      expect(controller.critical, isFalse);
      expect(controller.noticeVisible, isFalse);

      final at = DateTime(2026, 11, 1, 12);
      controller.observe(const RuntimeReleaseInfo(version: '0.1.3', minimumVersion: '0.1.3'), at);
      controller.observe(
        const RuntimeReleaseInfo(version: '0.1.3', minimumVersion: '0.1.3'),
        at.add(AppUpdateController.confirmDelay),
      );
      expect(controller.updateAvailable, isTrue);
      expect(controller.critical, isTrue);
      expect(controller.noticeVersion, '0.1.3');
    });

    testWidgets('the web notice keeps its buttons', (tester) async {
      final controller = AppUpdateController(web: true, runningVersion: '0.1.2', reader: () async => null);
      final at = DateTime(2026, 11, 1, 12);
      controller.observe(const RuntimeReleaseInfo(version: '0.1.3'), at);
      controller.observe(const RuntimeReleaseInfo(version: '0.1.3'), at.add(AppUpdateController.confirmDelay));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppUpdateOverlay(busy: () => false, controller: controller, child: child ?? const SizedBox()),
          home: const Scaffold(),
        ),
      );
      await tester.pump();
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });
}
