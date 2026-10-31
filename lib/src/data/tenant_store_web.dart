import 'package:sqlite3/wasm.dart';

import 'local_store.dart';

const _fileSystemName = 'mnscloud-infragis';
const _vfsName = 'mnscloud-infragis-idb';
Future<(WasmSqlite3, IndexedDbFileSystem)>? _loading;

/// SQLite3MultipleCiphers compiled to WebAssembly (web/sqlite3mc.wasm, same version as
/// pubspec.lock) over an IndexedDB file system, so the web copy is encrypted like the native one.
/// The file system is registered once per page (a second registration throws).
Future<(WasmSqlite3, IndexedDbFileSystem)> _open() => _loading ??= () async {
      final sqlite = await WasmSqlite3.loadFromUrl(Uri.base.resolve('sqlite3mc.wasm'));
      final fileSystem = await IndexedDbFileSystem.open(dbName: _fileSystemName, vfsName: _vfsName);
      sqlite.registerVirtualFileSystem(fileSystem, makeDefault: true);
      return (sqlite, fileSystem);
    }();

Future<LocalStore> openTenantStore(String environmentUuid, String key) async {
  final (sqlite, fileSystem) = await _open();
  // Only the cipher wrapper of the file system encrypts: opened on the plain VFS (by name or as the
  // default), `PRAGMA key` fails with "Encryption is not supported by the VFS".
  return LocalStore.fromDatabase(sqlite.open('/infragis-$environmentUuid.db', vfs: 'multipleciphers-$_vfsName'),
      key: key, writeAheadLog: false, persist: fileSystem.flush);
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
