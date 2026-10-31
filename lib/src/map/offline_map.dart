import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:http/http.dart' as http;

import '../core/ids.dart';
import '../data/local_store.dart';

/// Offline base map packages (docs/offline-maps.md): the tiles of an area are copied from the
/// platform base map sources (its own PMTiles archive or the style's tile sources) into the
/// encrypted tenant database, and the map reads them first. Downloaded tiles never expire on their
/// own; a package past its validity only asks to be downloaded again.

/// Days a package stays current before the app suggests downloading it again.
const mapPackageValidityDays = 30;

/// Upper bound of one package: keeps the download and the browser storage reasonable.
const mapPackageMaxTiles = 6000;

/// Average vector tile size used for the estimate shown before a download.
const mapTileEstimateBytes = 35 * 1024;

/// Wraps a base map source: a tile of a downloaded package comes from the encrypted database,
/// anything else from [inner] (the network). Without [inner] (offline before the source opened)
/// only package tiles are served and the map overzooms the highest downloaded level.
class OfflineTileProvider extends vt.VectorTileProvider {
  OfflineTileProvider({required this.store, required this.source, this.inner, int? maximumZoom, int? minimumZoom})
      : _maximumZoom = maximumZoom, // ignore: prefer_initializing_formals
        _minimumZoom = minimumZoom; // ignore: prefer_initializing_formals

  final LocalStore Function() store;
  final String source;
  final vt.VectorTileProvider? inner;
  final int? _maximumZoom;
  final int? _minimumZoom;

  @override
  int get maximumZoom => inner?.maximumZoom ?? _maximumZoom ?? store().mapMaxZoom(source) ?? 14;

  @override
  int get minimumZoom => inner?.minimumZoom ?? _minimumZoom ?? 0;

  @override
  String get cacheKey => source;

  @override
  bool get cacheBytesToDisk => inner?.cacheBytesToDisk ?? false;

  @override
  Future<vt.TileResponse> load(vt.TileKey tile, {vt.CancellationToken? cancellation}) async {
    final local = store().mapTile(source, tile.z, tile.x, tile.y);
    if (local != null) return local.isEmpty ? const vt.TileResponseNotFound() : vt.TileResponseData(local);
    final network = inner;
    if (network == null) return const vt.TileResponseNotFound();
    return network.load(tile, cancellation: cancellation);
  }

  @override
  void dispose() => inner?.dispose();
}

/// Keeps every style resource (style JSON, TileJSON, sprites) it fetched in the encrypted
/// database and answers from there when the network fails, so the base map opens offline once it
/// was opened online. Only GET requests to https URLs are kept.
class OfflineStyleClient extends http.BaseClient {
  OfflineStyleClient(this.store, [http.Client? inner]) : _inner = inner ?? http.Client();

  final LocalStore Function() store;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    final cacheable = request.method == 'GET' && request.url.scheme == 'https';
    try {
      final response = await _inner.send(request).timeout(const Duration(seconds: 20));
      if (!cacheable || response.statusCode != 200) return response;
      final body = await response.stream.toBytes();
      store().putMapResource(url, response.headers['content-type'], body);
      return _answer(request, response.headers['content-type'], body);
    } catch (error) {
      final cached = cacheable ? store().mapResource(url) : null;
      if (cached == null) rethrow;
      return _answer(request, cached.$1, cached.$2);
    }
  }

  http.StreamedResponse _answer(http.BaseRequest request, String? contentType, Uint8List body) =>
      http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
        request: request,
        headers: {'content-type': ?contentType},
      );

  @override
  void close() => _inner.close();
}

/// Geographic box (degrees).
class MapBox {
  const MapBox({required this.west, required this.south, required this.east, required this.north});

  final double west;
  final double south;
  final double east;
  final double north;
}

int _lonToX(double lon, int z) => ((lon + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);

int _latToY(double lat, int z) {
  final clamped = lat.clamp(-85.05112878, 85.05112878);
  final rad = clamped * math.pi / 180;
  final n = 1 << z;
  return ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n).floor().clamp(0, n - 1);
}

/// Web Mercator tiles covering [box] at every zoom of [minZoom]..[maxZoom], lowest zoom first.
Iterable<vt.TileKey> tilesFor(MapBox box, int minZoom, int maxZoom) sync* {
  for (var z = minZoom; z <= maxZoom; z++) {
    final x0 = _lonToX(box.west, z);
    final x1 = _lonToX(box.east, z);
    final y0 = _latToY(box.north, z);
    final y1 = _latToY(box.south, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        yield vt.TileKey(z, x, y);
      }
    }
  }
}

int tileCount(MapBox box, int minZoom, int maxZoom) {
  var total = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    total += (_lonToX(box.east, z) - _lonToX(box.west, z) + 1) * (_latToY(box.south, z) - _latToY(box.north, z) + 1);
  }
  return total;
}

/// Progress of a package download: tiles done of [total], bytes kept so far.
class MapDownloadProgress {
  const MapDownloadProgress(this.done, this.total, this.bytes);

  final int done;
  final int total;
  final int bytes;
}

/// Copies the tiles of [box] from every source of the base map into a new package. Absent tiles
/// are kept as empty entries (served as "no tile" offline). A transient failure stops the download
/// and keeps what was copied (the package stays incomplete and can be downloaded again).
Future<MapPackage> downloadMapPackage({
  required LocalStore store,
  required Map<String, vt.VectorTileProvider> sources,
  required String name,
  required MapBox box,
  required int minZoom,
  required int maxZoom,
  void Function(MapDownloadProgress progress)? onProgress,
  bool Function()? cancelled,
  DateTime Function() clock = DateTime.now,
}) async {
  final now = clock().toUtc();
  final package = MapPackage(
    uuid: newUuid(),
    name: name,
    west: box.west,
    south: box.south,
    east: box.east,
    north: box.north,
    minZoom: minZoom,
    maxZoom: maxZoom,
    createdAt: now,
    expiresAt: now.add(const Duration(days: mapPackageValidityDays)),
  );
  store.createMapPackage(package);
  final plan = <(String, vt.VectorTileProvider, vt.TileKey)>[
    for (final entry in sources.entries)
      for (final tile in tilesFor(box, math.max(minZoom, entry.value.minimumZoom), math.min(maxZoom, entry.value.maximumZoom)))
        (entry.key, entry.value, tile),
  ];
  var done = 0;
  var bytes = 0;
  final batch = <String, List<(int, int, int, Uint8List)>>{};
  void flush() {
    for (final entry in batch.entries) {
      store.putMapTiles(package.uuid, entry.key, entry.value);
    }
    batch.clear();
  }

  for (final (source, provider, tile) in plan) {
    if (cancelled?.call() ?? false) break;
    final response = await provider.load(tile);
    final Uint8List data;
    switch (response) {
      case vt.TileResponseData(:final bytes):
        data = bytes;
      case vt.TileResponseNotFound():
        data = Uint8List(0);
      case vt.TileResponseCancelled() || vt.TileResponseError():
        flush();
        throw MapDownloadException(done, plan.length);
    }
    (batch[source] ??= []).add((tile.z, tile.x, tile.y, data));
    bytes += data.length;
    done++;
    if (done % 50 == 0) {
      flush();
      onProgress?.call(MapDownloadProgress(done, plan.length, bytes));
    }
  }
  flush();
  onProgress?.call(MapDownloadProgress(done, plan.length, bytes));
  if (done == plan.length) store.completeMapPackage(package.uuid);
  return store.mapPackages().firstWhere((item) => item.uuid == package.uuid);
}

class MapDownloadException implements Exception {
  const MapDownloadException(this.done, this.total);

  final int done;
  final int total;

  @override
  String toString() => 'Map download stopped at $done of $total tiles.';
}
