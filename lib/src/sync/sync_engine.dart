import 'dart:io';
import 'dart:typed_data';

import '../api/infragis_api.dart';
import '../data/local_store.dart';

/// Outcome of one sync pass, shown on the sync screen.
class SyncReport {
  SyncReport();

  int pushed = 0;
  int conflicts = 0;
  int rejected = 0;
  int retried = 0;
  int photos = 0;
  int downloaded = 0;
  bool revoked = false;
  bool unauthorized = false;
  String? error;

  bool get ok => error == null && !revoked && !unauthorized;
}

/// Offline-first sync: queued writes go first (in order, idempotent by operation UUID), then the
/// photos of assets the server already has, then the server changes since the cursor (a full
/// bootstrap when there is no cursor). The API decides every write; the device only presents
/// conflicts and refusals. A revoked tenant (403/402) wipes the local copy.
class SyncEngine {
  SyncEngine({
    required this.api,
    required this.store,
    DateTime Function()? clock,
    Future<Uint8List> Function(String path)? readFile,
  })  : _clock = clock ?? DateTime.now,
        _readFile = readFile ?? ((path) => File(path).readAsBytes());

  final FieldApi api;
  final LocalStore store;
  final DateTime Function() _clock;
  final Future<Uint8List> Function(String path) _readFile;

  int get _now => _clock().millisecondsSinceEpoch;

  Future<SyncReport> run() async {
    final report = SyncReport();
    try {
      await _push(report);
      await _photos(report);
      await _pull(report);
      store.setMeta('lastSyncAt', _clock().toUtc().toIso8601String());
    } on ApiException catch (error) {
      if (error.revoked) {
        final photos = store.photos().map((photo) => photo.path).toList();
        store.wipe();
        LocalStore.deleteFiles(photos);
        report.revoked = true;
      } else if (error.unauthorized) {
        report.unauthorized = true;
      }
      report.error = error.message;
    }
    return report;
  }

  Future<void> _push(SyncReport report) async {
    while (true) {
      final batch = store.operations(dueOnly: true, nowMs: _now, limit: 100);
      if (batch.isEmpty) return;
      List<Map<String, dynamic>> results;
      try {
        results = await api.push(batch.map((operation) => operation.toWire()).toList());
      } on ApiException catch (error) {
        if (!error.transient) rethrow;
        for (final operation in batch) {
          store.retryLater(operation.uuid, _now);
        }
        report.retried += batch.length;
        return;
      }
      final byUuid = {for (final result in results) normalizeUuid('${result['uuid'] ?? ''}'): result};
      var progressed = false;
      for (final operation in batch) {
        final result = byUuid[normalizeUuid(operation.uuid)];
        final status = '${result?['status'] ?? 'RETRY'}';
        final item = result?['item'] is Map<String, dynamic> ? result!['item'] as Map<String, dynamic> : null;
        switch (status) {
          case 'ACCEPTED':
          case 'DUPLICATE':
            store.completeOperation(operation.uuid, item);
            report.pushed++;
            progressed = true;
          case 'CONFLICT':
            store.markOperation(
              operation.uuid,
              QueueStatus.conflict,
              error: result?['reason'] == 'deleted' ? 'Deleted on the server' : 'Changed on the server',
              serverItem: item,
            );
            report.conflicts++;
            progressed = true;
          case 'REJECTED':
            store.markOperation(operation.uuid, QueueStatus.rejected, error: '${result?['error'] ?? 'Rejected'}');
            report.rejected++;
            progressed = true;
          default:
            store.retryLater(operation.uuid, _now);
            report.retried++;
        }
      }
      if (!progressed) return;
    }
  }

  Future<void> _photos(SyncReport report) async {
    for (final photo in store.duePhotos(_now)) {
      try {
        final bytes = await _readFile(photo.path);
        await api.uploadAttachment(
          assetUuid: photo.assetUuid,
          attachmentUuid: photo.uuid,
          bytes: bytes,
          fileName: photo.fileName,
          kind: photo.kind,
          caption: photo.caption,
          latitude: photo.latitude,
          longitude: photo.longitude,
          capturedAt: photo.capturedAt,
        );
        store.completePhoto(photo.uuid);
        LocalStore.deleteFiles([photo.path]);
        report.photos++;
      } on ApiException catch (error) {
        if (error.revoked || error.unauthorized) rethrow;
        store.retryPhotoLater(photo.uuid, _now, error.message);
      } on FileSystemException catch (error) {
        store.retryPhotoLater(photo.uuid, _now, error.message);
      }
    }
  }

  Future<void> _pull(SyncReport report) async {
    var cursor = store.meta('cursor');
    if (cursor == null) {
      String? page;
      while (true) {
        final result = await api.bootstrap(page);
        // Only once the server answers: offline, the old copy stays on the map.
        if (page == null) store.clearSynced();
        if (result.catalog != null) store.replaceCatalog(result.catalog!);
        store.applyServerItems(result.items);
        report.downloaded += result.items.length;
        page = result.cursor;
        if (result.done) break;
      }
      store.setMeta('cursor', page);
      store.setMeta('catalogAt', _clock().toUtc().toIso8601String());
      return;
    }
    // Catalogs refresh at most once an hour; assets on every pass.
    final catalogAt = DateTime.tryParse(store.meta('catalogAt') ?? '');
    var withCatalog = catalogAt == null || _clock().difference(catalogAt).inMinutes >= 60;
    while (true) {
      final result = await api.changes(cursor!, catalog: withCatalog);
      if (result.catalog != null) {
        store.replaceCatalog(result.catalog!);
        store.setMeta('catalogAt', _clock().toUtc().toIso8601String());
      }
      withCatalog = false;
      store.applyServerItems(result.items);
      report.downloaded += result.items.length;
      cursor = result.cursor;
      store.setMeta('cursor', cursor);
      if (result.done) return;
    }
  }
}
