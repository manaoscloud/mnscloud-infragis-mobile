import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_infragis_mobile/src/api/infragis_api.dart';
import 'package:mnscloud_infragis_mobile/src/data/local_store.dart';
import 'package:mnscloud_infragis_mobile/src/sync/sync_engine.dart';

const a = '0d6f7a52-5b4e-4f7e-9a39-2f1c2d3e4f50';
const b = '1d6f7a52-5b4e-4f7e-9a39-2f1c2d3e4f51';
const order = '2d6f7a52-5b4e-4f7e-9a39-2f1c2d3e4f52';

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

  final orders = <Map<String, dynamic>>[];
  final sentActions = <String>[];
  ApiException? workOrderFailure;
  ApiException? actionFailure;

  @override
  Future<List<Map<String, dynamic>>> myWorkOrders() async {
    if (workOrderFailure != null) throw workOrderFailure!;
    return orders.map((order) => {...order}).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> workOrderMaterials(String orderUuid) async => const [];

  final checklist = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> workOrderChecklist(String orderUuid) async =>
      checklist.map((item) => {...item}).toList();

  @override
  Future<List<Map<String, dynamic>>> stockProducts() async => [
        {'SprUUID': 'P1', 'SprName': 'CABO DROP'},
      ];

  @override
  Future<List<Map<String, dynamic>>> stockLocations() async => [
        {'StlUUID': 'L1', 'StlName': 'ALMOXARIFADO'},
      ];

  @override
  Future<void> sendWorkOrderAction(String kind, String orderUuid, Map<String, dynamic> body) async {
    if (actionFailure != null) throw actionFailure!;
    sentActions.add('$kind:$orderUuid:${body['status'] ?? body['note'] ?? body['productUUID'] ?? body['itemUUID'] ?? ''}');
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
    store.queuePhoto(
        uuid: 'ph-1', assetUuid: a, bytes: Uint8List.fromList([0xff, 0xd8, 0xff]), fileName: 'ph-1.jpg', kind: 'PHOTO', now: DateTime.utc(2026));
    api.answer = (operation) => switch (operation['uuid']) { 'op-2' => 'CONFLICT', 'op-3' => 'REJECTED', _ => 'ACCEPTED' };
    final report = await engine(api, store).run();

    expect(api.pushed.map((operation) => operation['uuid']), ['op-1', 'op-2', 'op-3']);
    expect(report.pushed, 1);
    expect(report.conflicts, 1);
    expect(report.rejected, 1);
    expect(report.photos, 1, reason: 'the photo goes once its asset exists on the server');
    expect(api.uploads, ['$a/ph-1']);
    expect(store.photoBytes('ph-1'), isNull, reason: 'a sent photo leaves the encrypted store');
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

  test('work order actions go in order, then the assigned orders and the stock catalog refresh', () async {
    final api = FakeApi()
      ..bootstrapPages.add(const SyncPage(items: [], cursor: 'c0', done: true))
      ..orders.add({'WorUUID': order.replaceAll('-', '').toUpperCase(), 'WorTitle': 'Instalar', 'WorStatus': 'ASSIGNED'});
    final store = LocalStore.open(':memory:', key: '');
    await engine(api, store).run();
    expect(store.meta('workOrders'), 'available');
    expect(store.workOrders().single['WorTitle'], 'Instalar');
    expect(store.catalog('products').single['SprName'], 'CABO DROP');

    store.queueWorkOrderAction(operationUuid: 'op-1', kind: 'status', orderUuid: order, body: {'status': 'IN_PROGRESS', 'operationUUID': 'op-1'}, now: DateTime.utc(2026));
    store.queueWorkOrderAction(operationUuid: 'op-2', kind: 'material', orderUuid: order, body: {'materialUUID': 'op-2', 'productUUID': 'P1', 'locationUUID': 'L1', 'quantity': 2, 'productName': 'CABO DROP'}, now: DateTime.utc(2026));
    final local = store.workOrder(order)!;
    expect(local['WorStatus'], 'IN_PROGRESS');
    expect((local['materials'] as List).single['WomStatus'], 'PLANNED');

    final report = await engine(api, store).run();
    expect(api.sentActions, ['status:$order:IN_PROGRESS', 'material:$order:P1']);
    expect(report.workOrderActions, 2);
    expect(store.workOrderActions(), isEmpty);
  });

  test('a refused action stays visible; a missing module hides the tab without wiping', () async {
    final api = FakeApi()..bootstrapPages.add(const SyncPage(items: [], cursor: 'c0', done: true));
    final store = LocalStore.open(':memory:', key: '');
    store.queueWorkOrderAction(operationUuid: 'op-1', kind: 'status', orderUuid: order, body: {'status': 'DONE'}, now: DateTime.utc(2026));
    api.actionFailure = const ApiException('Work order note is required (400)', status: 400);
    final refused = await engine(api, store).run();
    expect(refused.workOrderRejected, 1);
    expect(store.workOrderActions().single.status, 'rejected');
    store.applyServerItems([item(a, '2026-10-25 08:00:00.000000')]);

    api.workOrderFailure = const ApiException('Commercial entitlement required (402)', status: 402);
    final report = await engine(api, store).run();
    expect(report.revoked, isFalse);
    expect(store.meta('workOrders'), 'unavailable');
    expect(store.assets(), isNotEmpty, reason: 'the asset copy stays');
  });

  test('checking a checklist item applies offline and survives the next order refresh', () async {
    final api = FakeApi()
      ..bootstrapPages.add(const SyncPage(items: [], cursor: 'c0', done: true))
      ..orders.add({'WorUUID': order, 'WorTitle': 'Instalar', 'WorStatus': 'IN_PROGRESS'})
      ..checklist.add({'WciUUID': 'I1', 'WciLabel': 'Medir sinal', 'WciRequired': 1, 'WciDone': 0});
    final store = LocalStore.open(':memory:', key: '');
    await engine(api, store).run();
    expect((store.workOrder(order)!['checklist'] as List).single['WciDone'], 0);

    store.queueWorkOrderAction(operationUuid: 'c1', kind: 'check', orderUuid: order, body: {'itemUUID': 'I1', 'done': true}, now: DateTime.utc(2026));
    expect((store.workOrder(order)!['checklist'] as List).single['WciDone'], 1);
    api.actionFailure = const ApiException('offline', status: 503);
    await engine(api, store).run();
    expect((store.workOrder(order)!['checklist'] as List).single['WciDone'], 1, reason: 'the queued check is re-applied');

    api.actionFailure = null;
    api.checklist.first['WciDone'] = 1;
    // After the backoff.
    await SyncEngine(api: api, store: store, clock: () => DateTime.now().add(const Duration(hours: 1))).run();
    expect(api.sentActions, ['check:$order:I1']);
    expect(store.workOrderActions(), isEmpty);
  });
}
