import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'local_store.dart';

Future<String> _path(String environmentUuid) async =>
    '${(await getApplicationSupportDirectory()).path}/infragis-$environmentUuid.db';

Future<LocalStore> openTenantStore(String environmentUuid, String key) async =>
    LocalStore.open(await _path(environmentUuid), key: key);

/// Remote wipe: the database file and its write-ahead log leave the device.
Future<void> deleteTenantStore(String environmentUuid) async {
  final path = await _path(environmentUuid);
  for (final file in [path, '$path-wal', '$path-shm']) {
    try {
      File(file).deleteSync();
    } catch (_) {
      // Already gone.
    }
  }
}
