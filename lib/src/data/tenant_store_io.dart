import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'local_store.dart';
import 'store_name.dart';

Future<String> _path(String environmentUuid, String? accountUuid) async =>
    '${(await getApplicationSupportDirectory()).path}/${storeFileName(environmentUuid, accountUuid)}';

Future<LocalStore> openTenantStore(String environmentUuid, String key, {String? accountUuid}) async =>
    LocalStore.open(await _path(environmentUuid, accountUuid), key: key);

/// Remote wipe: the database file and its write-ahead log leave the device.
Future<void> deleteTenantStore(String environmentUuid, {String? accountUuid}) async {
  final path = await _path(environmentUuid, accountUuid);
  for (final file in [path, '$path-wal', '$path-shm']) {
    try {
      File(file).deleteSync();
    } catch (_) {
      // Already gone.
    }
  }
}
