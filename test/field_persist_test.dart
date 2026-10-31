import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_infragis_mobile/src/data/local_store.dart';
import 'package:mnscloud_infragis_mobile/src/field_controller.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('a field change is reported only after the store has it on disk', () async {
    var persisted = Completer<void>();
    var calls = 0;
    final store = LocalStore.fromDatabase(sqlite3.openInMemory(), key: '', persist: () {
      calls++;
      return persisted.future;
    });
    // No session or API: the sync that follows a change returns at once.
    final controller = FieldController()..store = store;
    var notified = 0;
    controller.addListener(() => notified++);

    var done = false;
    final saving = controller
        .saveAsset(data: const {'IgaName': 'POSTE 1'}, localItem: const {'IgaName': 'POSTE 1'})
        .then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(store.operations(), hasLength(1));
    expect(calls, 1);
    expect(done, isFalse);
    expect(notified, 0);

    persisted.complete();
    await saving;
    expect(notified, 1);

    persisted = Completer<void>()..complete();
    await controller.deleteAsset(store.operations().single.assetUuid!);
    expect(calls, 2);
    expect(notified, 2);
  });
}
