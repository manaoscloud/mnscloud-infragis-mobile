import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnscloud_infragis_mobile/src/data/local_store.dart';
import 'package:mnscloud_infragis_mobile/src/map/offline_map.dart';

/// Network source of the test: every tile answers its coordinates, one is absent, and it can fail.
class FakeSource extends vt.VectorTileProvider {
  FakeSource({this.failAfter});

  final int? failAfter;
  int calls = 0;

  @override
  int get maximumZoom => 14;

  @override
  int get minimumZoom => 0;

  @override
  String get cacheKey => 'https://tiles.example/{z}/{x}/{y}.pbf';

  @override
  Future<vt.TileResponse> load(vt.TileKey tile, {vt.CancellationToken? cancellation}) async {
    calls++;
    if (failAfter != null && calls > failAfter!) return vt.TileResponseError(Exception('offline'));
    if (tile.z == 0) return const vt.TileResponseNotFound();
    return vt.TileResponseData(Uint8List.fromList('${tile.z}/${tile.x}/${tile.y}'.codeUnits));
  }
}

const box = MapBox(west: -60.03, south: -3.13, east: -60.00, north: -3.10);

void main() {
  test('tiles of an area follow the Web Mercator grid and grow by zoom', () {
    expect(tileCount(box, 0, 0), 1);
    final tiles = tilesFor(box, 12, 14).toList();
    expect(tiles.length, tileCount(box, 12, 14));
    expect(tiles.first.z, 12);
    expect(tiles.last.z, 14);
    // Manaus at z14 is around x=5461, y=8332.
    expect(tiles.where((tile) => tile.z == 14).every((tile) => (tile.x - 5461).abs() < 4 && (tile.y - 8332).abs() < 4), isTrue);
  });

  test('a downloaded area is read offline and removing it keeps pending changes', () async {
    final store = LocalStore.open(':memory:', key: '');
    store.queueAssetWrite(
      operationUuid: 'op-1',
      kind: 'asset.create',
      assetUuid: 'asset-1',
      data: const {'IgaName': 'POSTE 1'},
      localItem: const {'IgaName': 'POSTE 1'},
      now: DateTime.utc(2026, 11, 1),
    );
    final network = FakeSource();
    final progress = <MapDownloadProgress>[];
    final package = await downloadMapPackage(
      store: store,
      sources: {network.cacheKey: network},
      name: 'Centro',
      box: box,
      minZoom: 0,
      maxZoom: 14,
      onProgress: progress.add,
      clock: () => DateTime.utc(2026, 11, 1),
    );
    expect(package.complete, isTrue);
    expect(package.tiles, tileCount(box, 0, 14));
    expect(package.bytes, greaterThan(0));
    expect(package.expiresAt, DateTime.utc(2026, 12, 1));
    expect(progress.last.done, package.tiles);

    // Offline (no network provider): package tiles, absent tiles and overzoom limit.
    final offline = OfflineTileProvider(store: () => store, source: network.cacheKey);
    final tile = tilesFor(box, 14, 14).first;
    final hit = await offline.load(tile);
    expect(hit, isA<vt.TileResponseData>());
    expect(String.fromCharCodes((hit as vt.TileResponseData).bytes), '${tile.z}/${tile.x}/${tile.y}');
    expect(await offline.load(const vt.TileKey(0, 0, 0)), isA<vt.TileResponseNotFound>());
    expect(await offline.load(const vt.TileKey(14, 1, 1)), isA<vt.TileResponseNotFound>());
    expect(offline.maximumZoom, 14);

    // Online, a downloaded tile never goes to the network.
    final online = OfflineTileProvider(store: () => store, source: network.cacheKey, inner: network);
    final before = network.calls;
    await online.load(tile);
    expect(network.calls, before);
    await online.load(const vt.TileKey(14, 1, 1));
    expect(network.calls, before + 1);

    store.removeMapPackage(package.uuid);
    expect(store.mapPackages(), isEmpty);
    expect(store.mapTile(network.cacheKey, tile.z, tile.x, tile.y), isNull);
    expect(store.operations().single.uuid, 'op-1');
  });

  test('a download that loses the network keeps what it copied as an incomplete package', () async {
    final store = LocalStore.open(':memory:', key: '');
    final network = FakeSource(failAfter: 3);
    await expectLater(
      downloadMapPackage(
        store: store,
        sources: {network.cacheKey: network},
        name: 'Rural',
        box: box,
        minZoom: 10,
        maxZoom: 14,
      ),
      throwsA(isA<MapDownloadException>()),
    );
    final package = store.mapPackages().single;
    expect(package.complete, isFalse);
    expect(package.tiles, 3);
  });

  test('the style resources are kept and served when the network fails', () async {
    final store = LocalStore.open(':memory:', key: '');
    var online = true;
    final client = OfflineStyleClient(
      () => store,
      MockClient((request) async {
        if (!online) throw http.ClientException('offline');
        return http.Response('{"version":8}', 200, headers: {'content-type': 'application/json'});
      }),
    );
    final url = Uri.parse('https://maps.example/style.json');
    expect((await client.get(url)).body, '{"version":8}');
    online = false;
    final cached = await client.get(url);
    expect(cached.statusCode, 200);
    expect(cached.body, '{"version":8}');
    expect(cached.headers['content-type'], 'application/json');
    await expectLater(client.get(Uri.parse('https://maps.example/other.json')), throwsA(isA<http.ClientException>()));
  });

  test('a remote wipe also removes the map areas and the style copy', () async {
    final store = LocalStore.open(':memory:', key: '');
    final network = FakeSource();
    await downloadMapPackage(store: store, sources: {network.cacheKey: network}, name: 'A', box: box, minZoom: 13, maxZoom: 13);
    store.putMapResource('https://maps.example/style.json', 'application/json', Uint8List.fromList([1]));
    store.wipe();
    expect(store.mapPackages(), isEmpty);
    expect(store.mapResource('https://maps.example/style.json'), isNull);
  });
}
