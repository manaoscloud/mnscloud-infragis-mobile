import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_infragis_mobile/src/api/infragis_api.dart';
import 'package:mnscloud_infragis_mobile/src/data/local_store.dart';
import 'package:mnscloud_infragis_mobile/src/sync/sync_engine.dart';

const a = '0d6f7a52-5b4e-4f7e-9a39-2f1c2d3e4f50';
const b = '1d6f7a52-5b4e-4f7e-9a39-2f1c2d3e4f51';

Map<String, dynamic> item(String uuid, String syncAt, [String name = 'POSTE']) => {
      'IgaUUID': uuid.replaceAll('-', '').toUpperCase(),
      'IgaName': name,
      'IgmLatitude': '-3.1',
      'IgmLongitude': '-60.0',
      'syncAt': syncAt,
      'deleted': false,
    };

/// In-memory server: bootstrap pages, a changes feed and scripted push answers.
class FakeApi implements FieldApi {
  final bootstrapPages = <SyncPage>[];
  final changePages = <SyncPage>[];
  final pushed = <Map<String, dynamic>>[];
  final uploads = <String>[];
  String Function(Map<String, dynamic> operation) answer = (_) => 'ACCEPTED';
  ApiException? failure;
  int bootstrapCalls = 0;
  int changesCalls = 0;

  @override
  Future<SyncPage> bootstrap(String? cursor) async {
    if (failure != null) throw failure!;
    return bootstrapPages[bootstrapCalls++];
  }

  @override
  Future<SyncPage> changes(String cursor, {bool catalog = false}) async {
    if (failure != null) throw failure!;
    changesCalls++;
    return changePages.isEmpty ? SyncPage(items: const [], cursor: cursor, done: true) : changePages.removeAt(0);
  }

  @override
  Future<List<Map<String, dynamic>>> push(List<Map<String, dynamic>> operations) async {
    if (failure != null) throw failure!;
    pushed.addAll(operations);
    return [
      for (final operation in operations)
        {
          'uuid': operation['uuid'],
          'status': answer(operation),
          if (answer(operation) != 'REJECTED') 'item': item(operation['assetUUID'], '2026-10-25 12:00:00.000000', 'SERVER'),
          if (answer(operation) == 'CONFLICT') 'reason': 'changed',
          if (answer(operation) == 'REJECTED') 'error': 'name: Asset name is required',
        },
    ];
  }

  @override
  Future<Map<String, dynamic>> uploadAttachment({
    required String assetUuid,
    required String attachmentUuid,
    required Uint8List bytes,
    required String fileName,
    required String kind,
    String? caption,
    double? latitude,
    double? longitude,
    DateTime? capturedAt,
  }) async {
    uploads.add('$assetUuid/$attachmentUuid');
    return {'IgfUUID': attachmentUuid};
  }
}

SyncEngine engine(FakeApi api, LocalStore store) => SyncEngine(
      api: api,
      store: store,
      clock: () => DateTime.utc(2026, 10, 25, 12),
      readFile: (_) async => Uint8List.fromList([0xff, 0xd8, 0xff]),
    );

void main() {
  test('bootstrap downloads catalogs and pages, then changes apply tombstones', () async {
    final api = FakeApi()
      ..bootstrapPages.addAll([
        SyncPage(
          items: [item(a, '2026-10-25 08:00:00.000000')],
          cursor: 'b1',
          done: false,
          catalog: {
            'projects': [
              {'IprUUID': 'P1', 'IprName': 'REDE'},
            ],
          },
        ),
        SyncPage(items: [item(b, '2026-10-25 08:00:01.000000')], cursor: 'c0', done: true),
      ]);
    final store = LocalStore.open(':memory:', key: '');
    final first = await engine(api, store).run();
    expect(first.ok, isTrue);
    expect(first.downloaded, 2);
    expect(store.meta('cursor'), 'c0');
    expect(store.catalog('projects').single['IprName'], 'REDE');

    api.changePages.add(SyncPage(items: [{'IgaUUID': b, 'deleted': true}], cursor: 'c1', done: true));
    await engine(api, store).run();
    expect(store.assets().map((asset) => asset['IgaUUID']), [a]);
    expect(store.meta('cursor'), 'c1');
    expect(api.bootstrapCalls, 2, reason: 'a cursor means changes only');
  });

  test('push sends the queue in order and handles each answer', () async {
    final api = FakeApi()
      ..bootstrapPages.add(SyncPage(items: [item(a, '2026-10-25 12:00:00.000000', 'SERVER')], cursor: 'c0', done: true));
    final store = LocalStore.open(':memory:', key: '');
    for (final (id, kind, uuid) in [('op-1', 'asset.create', a), ('op-2', 'asset.update', b), ('op-3', 'asset.update', b)]) {
      store.queueAssetWrite(
        operationUuid: id,
        kind: kind,
        assetUuid: uuid,
        data: {'name': id},
        localItem: {'IgaName': id},
        now: DateTime.utc(2026),
      );
    }
    store.queuePhoto(uuid: 'ph-1', assetUuid: a, path: '/nonexistent/ph-1.jpg', fileName: 'ph-1.jpg', kind: 'PHOTO', now: DateTime.utc(2026));
    api.answer = (operation) => switch (operation['uuid']) { 'op-2' => 'CONFLICT', 'op-3' => 'REJECTED', _ => 'ACCEPTED' };
    final report = await engine(api, store).run();

    expect(api.pushed.map((operation) => operation['uuid']), ['op-1', 'op-2', 'op-3']);
    expect(report.pushed, 1);
    expect(report.conflicts, 1);
    expect(report.rejected, 1);
    expect(report.photos, 1, reason: 'the photo goes once its asset exists on the server');
    expect(api.uploads, ['$a/ph-1']);
    final open = store.operations();
    expect(open.map((operation) => operation.status), [QueueStatus.conflict, QueueStatus.rejected]);
    expect(open.first.serverItem!['IgaName'], 'SERVER');
    expect(store.asset(a)!['IgaName'], 'SERVER');
  });

  test('a transient failure keeps the queue for later', () async {
    final api = FakeApi()..failure = const ApiException('down', status: 503);
    final store = LocalStore.open(':memory:', key: '');
    store.queueAssetWrite(operationUuid: 'op-1', kind: 'asset.delete', assetUuid: a, data: const {}, localItem: null, now: DateTime.utc(2026));
    final report = await engine(api, store).run();
    expect(report.retried, 1);
    expect(store.operations().single.attempts, 1);
    expect(report.revoked, isFalse);
  });

  test('a revoked tenant wipes the local copy; an expired session keeps it', () async {
    final store = LocalStore.open(':memory:', key: '');
    store.queueAssetWrite(operationUuid: 'op-1', kind: 'asset.delete', assetUuid: a, data: const {}, localItem: null, now: DateTime.utc(2026));
    final expired = await engine(FakeApi()..failure = const ApiException('expired', status: 401), store).run();
    expect(expired.unauthorized, isTrue);
    expect(store.operations(), hasLength(1));

    final revoked = await engine(FakeApi()..failure = const ApiException('no access', status: 403), store).run();
    expect(revoked.revoked, isTrue);
    expect(store.operations(), isEmpty);
  });
}
