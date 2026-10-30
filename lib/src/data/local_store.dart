import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/common.dart';

import 'sqlite_open.dart';

/// Status of a queued write: waiting to be sent, stopped by a server conflict, or refused.
enum QueueStatus { pending, conflict, rejected }

class QueuedOperation {
  const QueuedOperation({
    required this.seq,
    required this.uuid,
    required this.kind,
    required this.assetUuid,
    required this.baseSyncAt,
    required this.data,
    required this.status,
    required this.attempts,
    this.error,
    this.serverItem,
  });

  final int seq;
  final String uuid;
  final String kind;
  final String assetUuid;
  final String? baseSyncAt;
  final Map<String, dynamic> data;
  final QueueStatus status;
  final int attempts;
  final String? error;
  final Map<String, dynamic>? serverItem;

  /// Wire shape of `POST /infragis/sync/push`.
  Map<String, dynamic> toWire() => {
        'uuid': uuid,
        'kind': kind,
        'assetUUID': assetUuid,
        if (baseSyncAt != null) 'baseSyncAt': baseSyncAt,
        if (kind != 'asset.delete') 'data': data,
      };
}

class WorkOrderAction {
  const WorkOrderAction({
    required this.seq,
    required this.uuid,
    required this.kind,
    required this.orderUuid,
    required this.body,
    required this.status,
    this.error,
  });

  final int seq;
  final String uuid;
  final String kind;
  final String orderUuid;
  final Map<String, dynamic> body;
  final String status;
  final String? error;
}

class QueuedAttachment {
  const QueuedAttachment({
    required this.seq,
    required this.uuid,
    required this.assetUuid,
    required this.path,
    required this.fileName,
    required this.kind,
    required this.attempts,
    this.caption,
    this.latitude,
    this.longitude,
    this.capturedAt,
    this.error,
  });

  final int seq;
  final String uuid;
  final String assetUuid;
  final String path;
  final String fileName;
  final String kind;
  final int attempts;
  final String? caption;
  final double? latitude;
  final double? longitude;
  final DateTime? capturedAt;
  final String? error;
}

/// The offline copy of one tenant: catalogs, assets, the write queue, the photo queue and the
/// photos themselves, in one SQLite database encrypted with SQLite3MultipleCiphers (`PRAGMA key`):
/// native files on Android, iOS and desktop, IndexedDB through `sqlite3mc.wasm` on the web. The key
/// and the session token live in secure storage, never in this database.
class LocalStore {
  LocalStore._(this._db);

  static const schemaVersion = 3;
  final CommonDatabase _db;

  /// Opens (or creates) the store at [path] with [key] on native platforms; `:memory:` for tests.
  static LocalStore open(String path, {required String key}) =>
      fromDatabase(openNativeDatabase(path), key: path == ':memory:' ? '' : key);

  /// Store over an opened database: applies the key, the journal mode and the schema. The web has
  /// no write-ahead log (its virtual file system writes whole pages to IndexedDB).
  static LocalStore fromDatabase(CommonDatabase db, {required String key, bool writeAheadLog = true}) {
    // An in-memory database (tests) never touches the disk and takes no key.
    if (key.isNotEmpty) {
      db.execute("PRAGMA key = '${key.replaceAll("'", "''")}'");
    }
    // A wrong key fails here, on the first read of the encrypted pages.
    db.select('SELECT count(*) FROM sqlite_master');
    if (writeAheadLog) db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');
    final store = LocalStore._(db);
    store._migrate();
    return store;
  }

  /// True when the bundled SQLite encrypts (SQLite3MultipleCiphers): `PRAGMA cipher` answers.
  bool get encrypted {
    try {
      return _db.select('PRAGMA cipher').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version >= schemaVersion) return;
    _transaction(() {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS catalog (
          resource TEXT NOT NULL, uuid TEXT NOT NULL, item TEXT NOT NULL,
          PRIMARY KEY (resource, uuid)) STRICT;
        CREATE TABLE IF NOT EXISTS asset (
          uuid TEXT PRIMARY KEY, item TEXT NOT NULL, sync_at TEXT,
          local INTEGER NOT NULL DEFAULT 0) STRICT;
        CREATE TABLE IF NOT EXISTS outbox (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
          asset_uuid TEXT NOT NULL, base_sync_at TEXT, data TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_at INTEGER NOT NULL DEFAULT 0, error TEXT, server_item TEXT,
          created_at TEXT NOT NULL) STRICT;
        CREATE INDEX IF NOT EXISTS outbox_asset ON outbox (asset_uuid, status);
        CREATE TABLE IF NOT EXISTS photo_outbox (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT NOT NULL UNIQUE, asset_uuid TEXT NOT NULL,
          path TEXT NOT NULL, file_name TEXT NOT NULL, kind TEXT NOT NULL, caption TEXT,
          latitude REAL, longitude REAL, captured_at TEXT, attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_at INTEGER NOT NULL DEFAULT 0, error TEXT, created_at TEXT NOT NULL) STRICT;
      ''');
      // v2: work orders assigned to the user and their queued field actions.
      _db.execute('''
        CREATE TABLE IF NOT EXISTS work_order (uuid TEXT PRIMARY KEY, item TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS wo_outbox (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
          order_uuid TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
          attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL DEFAULT 0, error TEXT,
          created_at TEXT NOT NULL) STRICT;
      ''');
      // v3: the photos live in the encrypted database (no loose files; works on the web).
      _db.execute('CREATE TABLE IF NOT EXISTS photo_blob (uuid TEXT PRIMARY KEY, bytes BLOB NOT NULL) STRICT;');
      _db.execute('PRAGMA user_version = $schemaVersion');
    });
  }

  /// Work orders assigned to the user as the server answered (materials embedded per order).
  void replaceWorkOrders(List<Map<String, dynamic>> orders) {
    _transaction(() {
      _db.execute('DELETE FROM work_order');
      for (final order in orders) {
        final uuid = normalizeUuid('${order['WorUUID'] ?? ''}');
        if (uuid.isEmpty) continue;
        _db.execute('INSERT OR REPLACE INTO work_order (uuid, item) VALUES (?, ?)', [uuid, jsonEncode(order)]);
      }
      // Queued actions still show on top of the server copy.
      for (final action in workOrderActions()) {
        _applyLocal(action.orderUuid, action.kind, action.body);
      }
    });
  }

  List<Map<String, dynamic>> workOrders() => _db
      .select('SELECT item FROM work_order')
      .map((row) => jsonDecode(row['item'] as String) as Map<String, dynamic>)
      .toList();

  Map<String, dynamic>? workOrder(String uuid) {
    final rows = _db.select('SELECT item FROM work_order WHERE uuid = ?', [normalizeUuid(uuid)]);
    return rows.isEmpty ? null : jsonDecode(rows.first['item'] as String) as Map<String, dynamic>;
  }

  /// Field action on a work order (status, note, material, issue): applied to the local copy now and
  /// sent on the next sync with its operation UUID (a retry answers the stored state).
  void queueWorkOrderAction({
    required String operationUuid,
    required String kind,
    required String orderUuid,
    required Map<String, dynamic> body,
    required DateTime now,
  }) {
    _transaction(() {
      _db.execute(
        'INSERT INTO wo_outbox (uuid, kind, order_uuid, body, created_at) VALUES (?, ?, ?, ?, ?)',
        [operationUuid, kind, normalizeUuid(orderUuid), jsonEncode(body), now.toUtc().toIso8601String()],
      );
      _applyLocal(normalizeUuid(orderUuid), kind, body);
    });
  }

  void _applyLocal(String orderUuid, String kind, Map<String, dynamic> body) {
    final order = workOrder(orderUuid);
    if (order == null) return;
    if (kind == 'status') {
      order['WorStatus'] = body['status'];
      if (body['status'] == 'DONE') order['WorResolution'] = body['note'];
    } else if (kind == 'material') {
      final materials = [...(order['materials'] is List ? order['materials'] as List : const [])];
      if (!materials.any((m) => m is Map && normalizeUuid('${m['WomUUID']}') == normalizeUuid('${body['materialUUID']}'))) {
        materials.add({
          'WomUUID': body['materialUUID'],
          'ProductName': body['productName'],
          'LocationName': body['locationName'],
          'WomQuantity': body['quantity'],
          'WomStatus': 'PLANNED',
          'pending': true,
        });
      }
      order['materials'] = materials;
    } else if (kind == 'check') {
      order['checklist'] = [
        for (final item in order['checklist'] is List ? order['checklist'] as List : const [])
          if (item is Map && normalizeUuid('${item['WciUUID']}') == normalizeUuid('${body['itemUUID']}'))
            {...item, 'WciDone': body['done'] == true ? 1 : 0, if (body['note'] != null) 'WciNote': body['note'], 'pending': true}
          else
            item,
      ];
    }
    order['pending'] = true;
    _db.execute('UPDATE work_order SET item = ? WHERE uuid = ?', [jsonEncode(order), orderUuid]);
  }

  List<WorkOrderAction> workOrderActions({bool dueOnly = false, int? nowMs}) => (dueOnly
          ? _db.select(
              "SELECT * FROM wo_outbox WHERE status = 'pending' AND next_attempt_at <= ? ORDER BY seq",
              [nowMs ?? 0],
            )
          : _db.select('SELECT * FROM wo_outbox ORDER BY seq'))
      .map((row) => WorkOrderAction(
            seq: row['seq'] as int,
            uuid: row['uuid'] as String,
            kind: row['kind'] as String,
            orderUuid: row['order_uuid'] as String,
            body: jsonDecode(row['body'] as String) as Map<String, dynamic>,
            status: row['status'] as String,
            error: row['error'] as String?,
          ))
      .toList();

  void completeWorkOrderAction(String uuid) => _db.execute('DELETE FROM wo_outbox WHERE uuid = ?', [uuid]);

  void rejectWorkOrderAction(String uuid, String error) =>
      _db.execute("UPDATE wo_outbox SET status = 'rejected', error = ? WHERE uuid = ?", [error, uuid]);

  void retryWorkOrderActionLater(String uuid, int nowMs) => _db.execute(
        'UPDATE wo_outbox SET attempts = attempts + 1, '
        'next_attempt_at = ? + min(900000, 5000 * (1 << min(attempts, 8))) WHERE uuid = ?',
        [nowMs, uuid],
      );

  void discardWorkOrderAction(String uuid) => completeWorkOrderAction(uuid);

  T _transaction<T>(T Function() run) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = run();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => _db.close();

  String? meta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setMeta(String key, String? value) {
    if (value == null) {
      _db.execute('DELETE FROM meta WHERE key = ?', [key]);
    } else {
      _db.execute(
        'INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );
    }
  }

  /// Replaces the catalogs (projects, layers, categories, asset types, statuses).
  void replaceCatalog(Map<String, List<Map<String, dynamic>>> catalog) {
    const uuidKeys = {
      'products': 'SprUUID',
      'locations': 'StlUUID',
      'projects': 'IprUUID',
      'layers': 'IglUUID',
      'categories': 'IacUUID',
      'asset-types': 'IgtUUID',
      'statuses': 'IgsUUID',
    };
    _transaction(() {
      for (final entry in catalog.entries) {
        final key = uuidKeys[entry.key];
        if (key == null) continue;
        _db.execute('DELETE FROM catalog WHERE resource = ?', [entry.key]);
        for (final item in entry.value) {
          final uuid = '${item[key] ?? ''}';
          if (uuid.isEmpty) continue;
          _db.execute(
            'INSERT OR REPLACE INTO catalog (resource, uuid, item) VALUES (?, ?, ?)',
            [entry.key, uuid, jsonEncode(item)],
          );
        }
      }
    });
  }

  List<Map<String, dynamic>> catalog(String resource) => _db
      .select('SELECT item FROM catalog WHERE resource = ?', [resource])
      .map((row) => jsonDecode(row['item'] as String) as Map<String, dynamic>)
      .toList();

  /// Server rows land unless the asset has queued local writes (those win until pushed).
  void applyServerItems(List<Map<String, dynamic>> items) {
    _transaction(() {
      for (final item in items) {
        final uuid = normalizeUuid('${item['IgaUUID'] ?? ''}');
        if (uuid.isEmpty || _hasPending(uuid)) continue;
        if (item['deleted'] == true) {
          _db.execute('DELETE FROM asset WHERE uuid = ?', [uuid]);
          continue;
        }
        _db.execute(
          'INSERT INTO asset (uuid, item, sync_at, local) VALUES (?, ?, ?, 0) '
          'ON CONFLICT(uuid) DO UPDATE SET item = excluded.item, sync_at = excluded.sync_at, local = 0',
          [uuid, jsonEncode(item), item['syncAt'] ?? item['SyncAt']],
        );
      }
    });
  }

  /// Before a full download: server copies go (the download brings them back without tombstones);
  /// assets with queued writes stay.
  void clearSynced() => _db.execute(
        'DELETE FROM asset WHERE NOT EXISTS (SELECT 1 FROM outbox o WHERE o.asset_uuid = asset.uuid)',
      );

  bool _hasPending(String assetUuid) => _db.select(
        'SELECT 1 FROM outbox WHERE asset_uuid = ? LIMIT 1',
        [assetUuid],
      ).isNotEmpty;

  List<Map<String, dynamic>> assets() => _db
      .select('SELECT uuid, item, sync_at, local FROM asset ORDER BY json_extract(item, \'\$.IgaName\')')
      .map((row) => {
            ...jsonDecode(row['item'] as String) as Map<String, dynamic>,
            'IgaUUID': row['uuid'],
            'syncAt': row['sync_at'],
            'local': row['local'] == 1,
            'pending': _hasPending(row['uuid'] as String),
          })
      .toList();

  Map<String, dynamic>? asset(String uuid) {
    final rows = _db.select('SELECT item, sync_at FROM asset WHERE uuid = ?', [normalizeUuid(uuid)]);
    if (rows.isEmpty) return null;
    return {
      ...jsonDecode(rows.first['item'] as String) as Map<String, dynamic>,
      'syncAt': rows.first['sync_at'],
    };
  }

  /// Local write: the asset copy changes now and the operation waits in the queue.
  void queueAssetWrite({
    required String operationUuid,
    required String kind,
    required String assetUuid,
    required Map<String, dynamic> data,
    required Map<String, dynamic>? localItem,
    required DateTime now,
  }) {
    final uuid = normalizeUuid(assetUuid);
    _transaction(() {
      final current = asset(uuid);
      // The base is the server version this edit started from (null for a local-only asset).
      final base = kind == 'asset.create' ? null : current?['syncAt'] as String?;
      _db.execute(
        'INSERT INTO outbox (uuid, kind, asset_uuid, base_sync_at, data, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [operationUuid, kind, uuid, base, jsonEncode(data), now.toUtc().toIso8601String()],
      );
      if (kind == 'asset.delete') {
        _db.execute('DELETE FROM asset WHERE uuid = ?', [uuid]);
      } else if (localItem != null) {
        _db.execute(
          'INSERT INTO asset (uuid, item, sync_at, local) VALUES (?, ?, ?, ?) '
          'ON CONFLICT(uuid) DO UPDATE SET item = excluded.item, local = excluded.local',
          [uuid, jsonEncode({...?current, ...localItem, 'IgaUUID': uuid}), current?['syncAt'], kind == 'asset.create' ? 1 : 0],
        );
      }
    });
  }

  List<QueuedOperation> operations({bool dueOnly = false, int? nowMs, int limit = 100}) {
    final rows = dueOnly
        ? _db.select(
            "SELECT * FROM outbox WHERE status = 'pending' AND next_attempt_at <= ? ORDER BY seq LIMIT ?",
            [nowMs ?? 0, limit],
          )
        : _db.select('SELECT * FROM outbox ORDER BY seq LIMIT ?', [limit]);
    return rows.map(_operation).toList();
  }

  QueuedOperation _operation(Row row) => QueuedOperation(
        seq: row['seq'] as int,
        uuid: row['uuid'] as String,
        kind: row['kind'] as String,
        assetUuid: row['asset_uuid'] as String,
        baseSyncAt: row['base_sync_at'] as String?,
        data: jsonDecode(row['data'] as String) as Map<String, dynamic>,
        status: QueueStatus.values.byName(row['status'] as String),
        attempts: row['attempts'] as int,
        error: row['error'] as String?,
        serverItem: row['server_item'] == null
            ? null
            : jsonDecode(row['server_item'] as String) as Map<String, dynamic>,
      );

  /// Accepted (or duplicate): the operation leaves the queue and the server item becomes the copy.
  void completeOperation(String operationUuid, Map<String, dynamic>? item) {
    _transaction(() {
      final rows = _db.select('SELECT asset_uuid, kind FROM outbox WHERE uuid = ?', [operationUuid]);
      _db.execute('DELETE FROM outbox WHERE uuid = ?', [operationUuid]);
      if (rows.isEmpty) return;
      final assetUuid = rows.first['asset_uuid'] as String;
      if (item != null && !_hasPending(assetUuid)) {
        final syncAt = item['SyncAt'] ?? item['syncAt'];
        _db.execute(
          'INSERT INTO asset (uuid, item, sync_at, local) VALUES (?, ?, ?, 0) '
          'ON CONFLICT(uuid) DO UPDATE SET item = excluded.item, sync_at = excluded.sync_at, local = 0',
          [assetUuid, jsonEncode(item), syncAt],
        );
      } else if (item != null) {
        // Later queued edits keep the local copy; they now start from this server version.
        _db.execute('UPDATE asset SET sync_at = ?, local = 0 WHERE uuid = ?', [item['SyncAt'] ?? item['syncAt'], assetUuid]);
        _db.execute(
          "UPDATE outbox SET base_sync_at = ? WHERE asset_uuid = ? AND kind <> 'asset.create'",
          [item['SyncAt'] ?? item['syncAt'], assetUuid],
        );
      }
    });
  }

  void markOperation(
    String operationUuid,
    QueueStatus status, {
    String? error,
    Map<String, dynamic>? serverItem,
  }) {
    _db.execute(
      'UPDATE outbox SET status = ?, error = ?, server_item = ? WHERE uuid = ?',
      [status.name, error, serverItem == null ? null : jsonEncode(serverItem), operationUuid],
    );
  }

  /// Transient failure: try again later with exponential backoff (at most 15 minutes).
  void retryLater(String operationUuid, int nowMs) {
    _db.execute(
      'UPDATE outbox SET attempts = attempts + 1, '
      'next_attempt_at = ? + min(900000, 5000 * (1 << min(attempts, 8))) WHERE uuid = ?',
      [nowMs, operationUuid],
    );
  }

  /// Conflict resolved by keeping the local change: it goes again on top of the server version.
  void keepMine(String operationUuid) {
    _transaction(() {
      final rows = _db.select('SELECT server_item, asset_uuid FROM outbox WHERE uuid = ?', [operationUuid]);
      if (rows.isEmpty) return;
      final server = rows.first['server_item'] == null
          ? null
          : jsonDecode(rows.first['server_item'] as String) as Map<String, dynamic>;
      _db.execute(
        "UPDATE outbox SET status = 'pending', error = NULL, server_item = NULL, attempts = 0, "
        'next_attempt_at = 0, base_sync_at = ? WHERE uuid = ?',
        [server?['SyncAt'] ?? server?['syncAt'], operationUuid],
      );
    });
  }

  /// Conflict (or refusal) resolved by taking the server: the local change is dropped.
  void discard(String operationUuid) {
    _transaction(() {
      final rows = _db.select('SELECT server_item, asset_uuid, kind FROM outbox WHERE uuid = ?', [operationUuid]);
      if (rows.isEmpty) return;
      final assetUuid = rows.first['asset_uuid'] as String;
      _db.execute('DELETE FROM outbox WHERE uuid = ?', [operationUuid]);
      if (rows.first['kind'] == 'asset.create') {
        _db.execute('DELETE FROM photo_blob WHERE uuid IN (SELECT uuid FROM photo_outbox WHERE asset_uuid = ?)', [assetUuid]);
        _db.execute('DELETE FROM photo_outbox WHERE asset_uuid = ?', [assetUuid]);
      }
      if (_hasPending(assetUuid)) return;
      final server = rows.first['server_item'];
      if (server != null) {
        final item = jsonDecode(server as String) as Map<String, dynamic>;
        _db.execute(
          'INSERT OR REPLACE INTO asset (uuid, item, sync_at, local) VALUES (?, ?, ?, 0)',
          [assetUuid, server, item['SyncAt'] ?? item['syncAt']],
        );
      } else if (rows.first['kind'] == 'asset.create') {
        _db.execute('DELETE FROM asset WHERE uuid = ?', [assetUuid]);
      } else {
        // Without the server version the copy is refreshed by the next full download.
        setMeta('cursor', null);
      }
    });
  }

  /// Queues a photo for upload, storing its bytes in the encrypted database in the same transaction.
  void queuePhoto({
    required String uuid,
    required String assetUuid,
    required Uint8List bytes,
    required String fileName,
    required String kind,
    required DateTime now,
    String? caption,
    double? latitude,
    double? longitude,
    DateTime? capturedAt,
  }) {
    _transaction(() {
      _db.execute('INSERT OR REPLACE INTO photo_blob (uuid, bytes) VALUES (?, ?)', [uuid, bytes]);
      _db.execute(
      'INSERT INTO photo_outbox (uuid, asset_uuid, path, file_name, kind, caption, latitude, longitude, '
      'captured_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        uuid,
        normalizeUuid(assetUuid),
        'db:$uuid',
        fileName,
        kind,
        caption,
        latitude,
        longitude,
        capturedAt?.toUtc().toIso8601String(),
        now.toUtc().toIso8601String(),
      ],
      );
    });
  }

  /// Bytes of a queued photo (null when it was already sent or wiped).
  Uint8List? photoBytes(String uuid) {
    final rows = _db.select('SELECT bytes FROM photo_blob WHERE uuid = ?', [uuid]);
    return rows.isEmpty ? null : rows.first['bytes'] as Uint8List;
  }

  /// Photos whose asset already exists on the server (no queued create left).
  List<QueuedAttachment> duePhotos(int nowMs) => _db
      .select(
        'SELECT * FROM photo_outbox p WHERE next_attempt_at <= ? AND NOT EXISTS ('
        "SELECT 1 FROM outbox o WHERE o.asset_uuid = p.asset_uuid AND o.kind = 'asset.create') ORDER BY seq",
        [nowMs],
      )
      .map(_photo)
      .toList();

  List<QueuedAttachment> photos() =>
      _db.select('SELECT * FROM photo_outbox ORDER BY seq').map(_photo).toList();

  QueuedAttachment _photo(Row row) => QueuedAttachment(
        seq: row['seq'] as int,
        uuid: row['uuid'] as String,
        assetUuid: row['asset_uuid'] as String,
        path: row['path'] as String,
        fileName: row['file_name'] as String,
        kind: row['kind'] as String,
        attempts: row['attempts'] as int,
        caption: row['caption'] as String?,
        latitude: row['latitude'] as double?,
        longitude: row['longitude'] as double?,
        capturedAt: row['captured_at'] == null ? null : DateTime.parse(row['captured_at'] as String),
        error: row['error'] as String?,
      );

  void completePhoto(String uuid) => _transaction(() {
        _db.execute('DELETE FROM photo_outbox WHERE uuid = ?', [uuid]);
        _db.execute('DELETE FROM photo_blob WHERE uuid = ?', [uuid]);
      });

  void retryPhotoLater(String uuid, int nowMs, String error) => _db.execute(
        'UPDATE photo_outbox SET attempts = attempts + 1, error = ?, '
        'next_attempt_at = ? + min(900000, 5000 * (1 << min(attempts, 8))) WHERE uuid = ?',
        [error, nowMs, uuid],
      );

  /// Remote wipe: everything of this tenant leaves the device (the API revoked the access).
  void wipe() {
    _transaction(() {
      for (final table in ['meta', 'catalog', 'asset', 'outbox', 'photo_outbox', 'photo_blob', 'work_order', 'wo_outbox']) {
        _db.execute('DELETE FROM $table');
      }
    });
  }
}

/// UUID text as the API returns it (32 hex characters, upper case) or with dashes: always dashed lower case.
String normalizeUuid(String value) {
  final hex = value.replaceAll('-', '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(hex)) return value.toLowerCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
