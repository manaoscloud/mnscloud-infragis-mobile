import 'package:sqlite3/wasm.dart';

import 'local_store.dart';

const _fileSystemName = 'mnscloud-infragis';
WasmSqlite3? _sqlite;
IndexedDbFileSystem? _fileSystem;

/// SQLite3MultipleCiphers compiled to WebAssembly (web/sqlite3mc.wasm, same version as
/// pubspec.lock) over an IndexedDB file system, so the web copy is encrypted like the native one.
Future<(WasmSqlite3, IndexedDbFileSystem)> _open() async {
  final sqlite = _sqlite ??= await WasmSqlite3.loadFromUrl(Uri.base.resolve('sqlite3mc.wasm'));
  final fileSystem = _fileSystem ??= await IndexedDbFileSystem.open(dbName: _fileSystemName);
  sqlite.registerVirtualFileSystem(fileSystem, makeDefault: true);
  return (sqlite, fileSystem);
}

Future<LocalStore> openTenantStore(String environmentUuid, String key) async {
  final (sqlite, _) = await _open();
  return LocalStore.fromDatabase(sqlite.open('/infragis-$environmentUuid.db'), key: key, writeAheadLog: false);
}

/// Remote wipe: the tenant database leaves the browser storage.
Future<void> deleteTenantStore(String environmentUuid) async {
  final (_, fileSystem) = await _open();
  final path = '/infragis-$environmentUuid.db';
  for (final file in [path, '$path-journal']) {
    try {
      fileSystem.xDelete(file, 0);
    } catch (_) {
      // Already gone.
    }
  }
  await fileSystem.flush();
}
