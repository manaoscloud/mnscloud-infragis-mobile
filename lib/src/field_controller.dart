import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/infragis_api.dart';
import 'core/ids.dart';
import 'data/local_store.dart';
import 'data/session_vault.dart';
import 'data/tenant_store.dart';
import 'sync/sync_engine.dart';

/// App state: the signed-in tenant, its encrypted local store and the sync loop.
class FieldController extends ChangeNotifier {
  FieldController({SessionVault? vault}) : vault = vault ?? SessionVault();

  final SessionVault vault;
  FieldSession? session;
  LocalStore? store;
  InfraGisApi? api;
  SyncReport? lastReport;
  bool syncing = false;
  String? notice;
  Timer? _timer;

  bool get signedIn => session != null && store != null;

  /// Restores the previous session (the token stays valid until the API says otherwise).
  Future<void> restore() async {
    final saved = await vault.read();
    if (saved != null) await _open(saved);
  }

  Future<void> signIn(FieldSession value) async {
    await vault.save(value);
    await _open(value);
  }

  Future<void> _open(FieldSession value) async {
    final key = await vault.databaseKey(value.environmentUuid);
    store?.close();
    store = await openTenantStore(value.environmentUuid, key);
    session = value;
    api = InfraGisApi(baseUrl: value.baseUrl).forTenant(value.token, value.environmentUuid);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => sync());
    notifyListeners();
    unawaited(sync());
  }

  Future<void> sync() async {
    final current = store;
    final client = api;
    if (current == null || client == null || syncing) return;
    syncing = true;
    notifyListeners();
    final report = await SyncEngine(api: client, store: current).run();
    syncing = false;
    lastReport = report;
    if (report.revoked) {
      notice = 'revoked';
      final environmentUuid = session!.environmentUuid;
      await vault.forgetTenant(environmentUuid);
      await _close();
      // The rows (photos included) are already wiped; the database itself goes too.
      await deleteTenantStore(environmentUuid);
    } else if (report.unauthorized) {
      notice = 'sessionExpired';
      await vault.signOut();
      await _close();
    }
    notifyListeners();
  }

  /// Queues an asset create or update (data in the `POST/PUT /infragis/assets` shape).
  void saveAsset({String? assetUuid, required Map<String, dynamic> data, required Map<String, dynamic> localItem}) {
    final creating = assetUuid == null;
    final uuid = assetUuid ?? newUuid();
    store!.queueAssetWrite(
      operationUuid: newUuid(),
      kind: creating ? 'asset.create' : 'asset.update',
      assetUuid: uuid,
      data: data,
      localItem: localItem,
      now: DateTime.now(),
    );
    notifyListeners();
    unawaited(sync());
  }

  void deleteAsset(String assetUuid) {
    store!.queueAssetWrite(
      operationUuid: newUuid(),
      kind: 'asset.delete',
      assetUuid: assetUuid,
      data: const {},
      localItem: null,
      now: DateTime.now(),
    );
    notifyListeners();
    unawaited(sync());
  }

  void queuePhoto({
    required String assetUuid,
    required Uint8List bytes,
    required String fileName,
    String? caption,
    double? latitude,
    double? longitude,
  }) {
    final uuid = newUuid();
    store!.queuePhoto(
      uuid: uuid,
      assetUuid: assetUuid,
      bytes: bytes,
      fileName: fileName,
      kind: 'PHOTO',
      caption: caption,
      latitude: latitude,
      longitude: longitude,
      capturedAt: DateTime.now(),
      now: DateTime.now(),
    );
    notifyListeners();
    unawaited(sync());
  }

  bool get workOrdersAvailable => store?.meta('workOrders') == 'available';

  /// Queues a work order action; the material line keeps the operation UUID as its identifier.
  void workOrderAction(String kind, String orderUuid, Map<String, dynamic> body) {
    final uuid = newUuid();
    store!.queueWorkOrderAction(
      operationUuid: uuid,
      kind: kind,
      orderUuid: orderUuid,
      body: {
        ...body,
        if (kind == 'material') 'materialUUID': uuid else if (kind == 'status' || kind == 'note') 'operationUUID': uuid,
      },
      now: DateTime.now(),
    );
    notifyListeners();
    unawaited(sync());
  }

  void resolve(String operationUuid, {required bool keepMine}) {
    keepMine ? store!.keepMine(operationUuid) : store!.discard(operationUuid);
    notifyListeners();
    if (keepMine) unawaited(sync());
  }

  Future<void> signOut() async {
    await vault.signOut();
    await _close();
    notifyListeners();
  }

  Future<void> _close() async {
    _timer?.cancel();
    store?.close();
    store = null;
    session = null;
    api = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    store?.close();
    super.dispose();
  }
}
