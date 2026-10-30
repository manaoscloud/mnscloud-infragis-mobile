import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_infragis_mobile/src/data/local_store.dart';

const asset = '0d6f7a52-5b4e-4f7e-9a39-2f1c2d3e4f50';

Map<String, dynamic> serverItem(String syncAt, {String name = 'POSTE 1'}) => {
      'IgaUUID': asset.replaceAll('-', '').toUpperCase(),
      'IgaName': name,
      'IgmLatitude': '-3.1000000',
      'IgmLongitude': '-60.0000000',
      'SyncAt': syncAt,
      'syncAt': syncAt,
    };

void main() {
  test('the database is encrypted and needs its key', () {
    final directory = Directory.systemTemp.createTempSync('infragis-store');
    final path = '${directory.path}/tenant.db';
    final store = LocalStore.open(path, key: 'right-key');
    expect(store.encrypted, isTrue);
    store.setMeta('cursor', 'abc');
    store.close();
    expect(File(path).readAsBytesSync().take(16).toList(), isNot(equals('SQLite format 3\u0000'.codeUnits)));
    expect(() => LocalStore.open(path, key: 'wrong-key'), throwsA(anything));
    final reopened = LocalStore.open(path, key: 'right-key');
    expect(reopened.meta('cursor'), 'abc');
    reopened.close();
    directory.deleteSync(recursive: true);
  });

  test('local writes queue in order and server rows wait for them', () {
    final store = LocalStore.open(':memory:', key: 'k');
    store.applyServerItems([serverItem('2026-10-25 08:00:00.000001')]);
    expect(store.asset(asset)!['syncAt'], '2026-10-25 08:00:00.000001');

    store.queueAssetWrite(
      operationUuid: 'op-1',
      kind: 'asset.update',
      assetUuid: asset,
      data: {'name': 'Poste 1b'},
      localItem: {'IgaName': 'POSTE 1B'},
      now: DateTime.utc(2026, 10, 25),
    );
    final queued = store.operations().single;
    expect(queued.baseSyncAt, '2026-10-25 08:00:00.000001');
    expect(queued.toWire()['data'], {'name': 'Poste 1b'});
    expect(store.assets().single['pending'], isTrue);

    // A server change of the same asset does not overwrite the local edit before it is pushed.
    store.applyServerItems([serverItem('2026-10-25 09:00:00.000000', name: 'OTHER')]);
    expect(store.asset(asset)!['IgaName'], 'POSTE 1B');

    store.completeOperation('op-1', serverItem('2026-10-25 10:00:00.000000', name: 'POSTE 1B'));
    expect(store.operations(), isEmpty);
    expect(store.asset(asset)!['syncAt'], '2026-10-25 10:00:00.000000');
    store.close();
  });

  test('conflicts keep the local change or take the server version', () {
    final store = LocalStore.open(':memory:', key: 'k');
    store.applyServerItems([serverItem('2026-10-25 08:00:00.000000')]);
    for (final id in ['op-a', 'op-b']) {
      store.queueAssetWrite(
        operationUuid: id,
        kind: 'asset.update',
        assetUuid: asset,
        data: {'name': id},
        localItem: {'IgaName': id},
        now: DateTime.utc(2026),
      );
    }
    final server = serverItem('2026-10-25 11:00:00.000000', name: 'SERVER');
    store.markOperation('op-a', QueueStatus.conflict, error: 'Changed', serverItem: server);
    store.keepMine('op-a');
    final kept = store.operations().first;
    expect(kept.status, QueueStatus.pending);
    expect(kept.baseSyncAt, '2026-10-25 11:00:00.000000');

    store.markOperation('op-b', QueueStatus.conflict, serverItem: server);
    store.discard('op-b');
    expect(store.operations().map((op) => op.uuid), ['op-a']);
    // Without a server version the next pass downloads everything again.
    store.setMeta('cursor', 'c');
    store.discard('op-a');
    expect(store.operations(), isEmpty);
    expect(store.meta('cursor'), isNull);
    store.clearSynced();
    expect(store.assets(), isEmpty);
    store.close();
  });

  test('a discarded offline create removes the asset and its photos', () {
    final store = LocalStore.open(':memory:', key: 'k');
    store.queueAssetWrite(
      operationUuid: 'op-create',
      kind: 'asset.create',
      assetUuid: asset,
      data: {'name': 'Novo'},
      localItem: {'IgaName': 'NOVO'},
      now: DateTime.utc(2026),
    );
    expect(store.assets().single['local'], isTrue);
    expect(store.operations().single.baseSyncAt, isNull);
    store.queuePhoto(
        uuid: 'photo-1', assetUuid: asset, bytes: Uint8List.fromList([1, 2, 3]), fileName: 'x.jpg', kind: 'PHOTO', now: DateTime.utc(2026));
    expect(store.photoBytes('photo-1'), [1, 2, 3], reason: 'the photo bytes live in the encrypted store');
    expect(store.duePhotos(0), isEmpty, reason: 'the asset does not exist on the server yet');
    store.markOperation('op-create', QueueStatus.rejected, error: 'name: Asset name is required');
    store.discard('op-create');
    expect(store.assets(), isEmpty);
    expect(store.photos(), isEmpty);
    expect(store.photoBytes('photo-1'), isNull, reason: 'discarding the create drops its photos too');
    store.close();
  });

  test('backoff postpones a transient failure and wipe empties the tenant', () {
    final store = LocalStore.open(':memory:', key: 'k');
    store.queueAssetWrite(
      operationUuid: 'op-1',
      kind: 'asset.delete',
      assetUuid: asset,
      data: const {},
      localItem: null,
      now: DateTime.utc(2026),
    );
    expect(store.operations(dueOnly: true, nowMs: 0), hasLength(1));
    store.retryLater('op-1', 1000);
    expect(store.operations(dueOnly: true, nowMs: 1000), isEmpty);
    expect(store.operations(dueOnly: true, nowMs: 7000), hasLength(1));
    expect(store.operations().single.toWire().containsKey('data'), isFalse);
    store.setMeta('cursor', 'x');
    store.wipe();
    expect(store.operations(), isEmpty);
    expect(store.meta('cursor'), isNull);
    store.close();
  });

  test('normalizes API UUIDs', () {
    expect(normalizeUuid('0D6F7A525B4E4F7E9A392F1C2D3E4F50'), asset);
    expect(normalizeUuid(asset.toUpperCase()), asset);
  });
}
