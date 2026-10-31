import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:http/http.dart' as http;

import 'api/infragis_api.dart';
import 'api/web_api_base.dart';
import 'brand/brand.dart';
import 'brand/brand_dom.dart';
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

  /// Brand of the domain (Settings › Themes › InfraGIS), shared by the login and the app theme.
  final brand = ValueNotifier<Brand?>(null);

  /// Language chosen on the login screen; null follows the device.
  final locale = ValueNotifier<Locale?>(null);

  /// Loads the brand of the platform that serves the app (web: same origin; native: the last API
  /// address used). Without a reachable theme the MNSCloud defaults stay.
  Future<void> loadBrand([String? baseUrl]) async {
    final base = baseUrl ?? (kIsWeb ? webApiBaseUrl() : await vault.lastBaseUrl());
    if (base == null || base.trim().isEmpty) return;
    try {
      final root = base.trim().replaceAll(RegExp(r'/+$'), '');
      final response = await http
          .get(Uri.parse('$root/public/theme/context?app=infragis'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;
      final body = jsonDecode(response.body);
      final value = Brand.fromContext(body is Map ? body['data'] : null);
      brand.value = value;
      if (value?.faviconUrl case final url?) applyFavicon(url);
    } catch (_) {
      // Keeps the MNSCloud defaults.
    }
  }

  bool get signedIn => session != null && store != null;

  /// Restores the previous session (the token stays valid until the API says otherwise).
  Future<void> restore() async {
    final saved = await vault.read();
    if (saved != null) await _open(saved);
  }

  Future<void> signIn(FieldSession value) async {
    await vault.save(value);
    await _open(value);
    unawaited(loadBrand(value.baseUrl));
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
    await current.persist();
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
  Future<void> saveAsset(
      {String? assetUuid, required Map<String, dynamic> data, required Map<String, dynamic> localItem}) async {
    final creating = assetUuid == null;
    final uuid = assetUuid ?? newUuid();
    final current = store!;
    current.queueAssetWrite(
      operationUuid: newUuid(),
      kind: creating ? 'asset.create' : 'asset.update',
      assetUuid: uuid,
      data: data,
      localItem: localItem,
      now: DateTime.now(),
    );
    await current.persist();
    notifyListeners();
    unawaited(sync());
  }

  Future<void> deleteAsset(String assetUuid) async {
    final current = store!;
    current.queueAssetWrite(
      operationUuid: newUuid(),
      kind: 'asset.delete',
      assetUuid: assetUuid,
      data: const {},
      localItem: null,
      now: DateTime.now(),
    );
    await current.persist();
    notifyListeners();
    unawaited(sync());
  }

  Future<void> queuePhoto({
    required String assetUuid,
    required Uint8List bytes,
    required String fileName,
    String? caption,
    double? latitude,
    double? longitude,
  }) async {
    final uuid = newUuid();
    final current = store!;
    current.queuePhoto(
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
    await current.persist();
    notifyListeners();
    unawaited(sync());
  }

  /// Something outside the controller changed the store (a map download): refresh the screens.
  void changed() => notifyListeners();

  bool get workOrdersAvailable => store?.meta('workOrders') == 'available';

  /// Platform map base. The last answer is kept in the encrypted store so the map opens offline.
  Future<Map<String, dynamic>> mapConfig() async {
    final current = store;
    try {
      final config = await api!.mapConfig();
      current?.setMeta('mapConfig', jsonEncode(config));
      await current?.persist();
      return config;
    } catch (_) {
      final cached = current?.meta('mapConfig');
      if (cached != null) {
        try {
          return (jsonDecode(cached) as Map).cast<String, dynamic>();
        } catch (_) {
          // Unreadable: no base map.
        }
      }
      return const {};
    }
  }

  /// Removes an offline map area. Pending changes live in other tables and always stay; a sync is
  /// attempted first so the device leaves the area with nothing waiting when it can.
  Future<void> removeMapPackage(String packageUuid) async {
    await sync();
    final current = store;
    if (current == null) return;
    current.removeMapPackage(packageUuid);
    await current.persist();
    notifyListeners();
  }

  /// Queues a work order action; the material line keeps the operation UUID as its identifier.
  Future<void> workOrderAction(String kind, String orderUuid, Map<String, dynamic> body) async {
    final uuid = newUuid();
    final current = store!;
    current.queueWorkOrderAction(
      operationUuid: uuid,
      kind: kind,
      orderUuid: orderUuid,
      body: {
        ...body,
        if (kind == 'material') 'materialUUID': uuid else if (kind == 'status' || kind == 'note') 'operationUUID': uuid,
      },
      now: DateTime.now(),
    );
    await current.persist();
    notifyListeners();
    unawaited(sync());
  }

  Future<void> resolve(String operationUuid, {required bool keepMine}) async {
    final current = store!;
    keepMine ? current.keepMine(operationUuid) : current.discard(operationUuid);
    await current.persist();
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
