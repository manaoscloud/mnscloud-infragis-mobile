import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:http/http.dart' as http;

import 'api/infragis_api.dart';
import 'api/mns_client.dart';
import 'api/web_api_base.dart';
import 'brand/brand.dart';
import 'brand/brand_dom.dart';
import 'core/ids.dart';
import 'data/local_store.dart';
import 'data/session_vault.dart';
import 'data/tenant_store.dart';
import 'security/app_lock.dart';
import 'sync/sync_engine.dart';

/// App state: the signed-in tenant and InfraGIS account, its encrypted local store and the sync loop.
class FieldController extends ChangeNotifier {
  FieldController({SessionVault? vault, AppLock? lock, DateTime Function()? clock, this.httpClient})
      : vault = vault ?? SessionVault(),
        lock = lock ?? AppLock(),
        _clock = clock ?? DateTime.now;

  final SessionVault vault;
  final AppLock lock;
  final DateTime Function() _clock;
  /// HTTP client of the API calls (tests pass a mock); null uses a new client.
  final http.Client? httpClient;
  FieldSession? session;

  /// Signed in, the operator chooses the InfraGIS account of the local copy among these.
  bool needsAccount = false;
  List<AccountOption> accountChoices = const [];
  FieldSession? _choosing;

  /// Authentication of the open session: kept to list accounts after its copy closed.
  FieldAuth? _auth;

  /// The PIN (or biometrics) is asked before the encrypted copy opens.
  bool locked = false;

  /// Signed in without a PIN yet: the app asks for one before the field screens.
  bool needsPin = false;
  FieldSession? _lockedSession;
  DateTime? _backgroundSince;
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
    final base = baseUrl ?? await apiBase();
    if (base == null || base.trim().isEmpty) return;
    final client = MnsApiClient.wrap(httpClient);
    try {
      final root = base.trim().replaceAll(RegExp(r'/+$'), '');
      final response = await client
          .get(Uri.parse('$root/public/theme/context?app=infragis'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;
      final body = jsonDecode(response.body);
      final value = Brand.fromContext(body is Map ? body['data'] : null);
      brand.value = value;
      if (value?.faviconUrl case final url?) applyFavicon(url);
    } catch (_) {
      // Keeps the MNSCloud defaults.
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// API address of the app (web: same origin; native: the open session or the last one used);
  /// null before the first sign-in on a native device.
  Future<String?> apiBase() async => session?.baseUrl ?? (kIsWeb ? webApiBaseUrl() : await vault.lastBaseUrl());

  bool get signedIn => session != null && store != null;

  /// Restores the previous session. With a PIN the encrypted copy stays closed until it is
  /// unlocked; a session saved before the PIN existed opens and asks to create one.
  Future<void> restore() async {
    final saved = await vault.read();
    if (saved == null) return;
    if (await lock.hasPin()) {
      _lockedSession = saved;
      locked = true;
      notifyListeners();
      return;
    }
    await _open(saved);
    needsPin = true;
    notifyListeners();
  }

  Future<void> signIn(FieldSession value) async {
    _auth = FieldAuth(
      baseUrl: value.baseUrl,
      accessToken: value.token,
      refreshToken: value.refreshToken,
      onRotated: vault.saveRefreshToken,
    );
    await vault.save(value.withAccount(null, null));
    needsPin = !await lock.hasPin();
    await _chooseAccount(value.withAccount(null, null));
    notifyListeners();
    unawaited(loadBrand(value.baseUrl));
  }

  InfraGisApi _tenantApi(FieldSession value) => InfraGisApi(baseUrl: value.baseUrl, client: httpClient).forTenant(
        _auth ??
            FieldAuth(
              baseUrl: value.baseUrl,
              accessToken: value.token,
              refreshToken: value.refreshToken,
              onRotated: vault.saveRefreshToken,
            ),
        value.environmentUuid,
      );

  /// One account opens directly; several ask the operator. Without accounts (no permission to list
  /// them, an older server) the copy keeps every account, as before. A tenant-wide copy of an older
  /// version with work still queued opens first, so nothing waiting is stranded.
  Future<void> _chooseAccount(FieldSession value) async {
    if (await _tenantWideCopyBusy(value)) {
      await _open(value.withAccount(null, null));
      return;
    }
    List<AccountOption> options;
    try {
      options = await _tenantApi(value).accounts();
    } on ApiException {
      options = const [];
    }
    if (options.length <= 1) {
      await _openAccount(value, options.isEmpty ? null : options.first);
      return;
    }
    _choosing = value;
    accountChoices = options;
    needsAccount = true;
    notifyListeners();
  }

  Future<bool> _tenantWideCopyBusy(FieldSession value) async {
    if (!await vault.hasTenantWideCopy(value.environmentUuid)) return false;
    final copy = await openTenantStore(value.environmentUuid, await vault.databaseKey(value.environmentUuid));
    try {
      return hasPendingWork(copy);
    } finally {
      copy.close();
    }
  }

  /// The operator chose the account of the local copy.
  Future<void> selectAccount(AccountOption option) async {
    final value = _choosing;
    if (value == null) return;
    _choosing = null;
    needsAccount = false;
    accountChoices = const [];
    await _openAccount(value, option);
  }

  Future<void> _openAccount(FieldSession value, AccountOption? option) async {
    // The legacy internal account carries a server-made name: the screens show "own network".
    final next = value.withAccount(option?.uuid, option == null || option.legacy ? null : option.name);
    await vault.save(next);
    if (next.accountUuid != null && await vault.hasTenantWideCopy(next.environmentUuid)) {
      // The tenant-wide copy of an older version has nothing queued (checked before): it goes.
      await deleteTenantStore(next.environmentUuid);
      await vault.forgetAccount(next.environmentUuid, null);
    }
    await _open(next);
  }

  /// Changes the account of the local copy. The current copy is synced first and must have nothing
  /// waiting; it stays on the device for a later return. Returns the reason when it cannot switch.
  Future<String?> switchAccount() async {
    final current = session;
    if (current == null || store == null) return null;
    await sync();
    final open = store;
    if (open == null) return null;
    if (hasPendingWork(open)) return 'switchPending';
    List<AccountOption> options;
    try {
      options = await api!.accounts();
    } on ApiException {
      return 'accountsUnavailable';
    }
    if (options.isEmpty || (options.length == 1 && options.first.uuid == current.accountUuid)) {
      return 'noOtherAccount';
    }
    await _close();
    _choosing = current.withAccount(null, null);
    accountChoices = options;
    needsAccount = true;
    notifyListeners();
    return null;
  }

  /// The account of the copy is out of the operator's scope or deactivated: its copy leaves the
  /// device (like the remote wipe of a tenant) and the operator chooses again.
  Future<void> _accountLost(FieldSession value) async {
    notice = 'accountRevoked';
    await _close();
    await deleteTenantStore(value.environmentUuid, accountUuid: value.accountUuid);
    await vault.forgetAccount(value.environmentUuid, value.accountUuid);
    await _chooseAccount(value.withAccount(null, null));
  }

  /// Creates the local PIN (and turns biometrics on when asked and available).
  Future<void> createPin(String pin, {bool biometrics = false}) async {
    await lock.setPin(pin);
    await lock.setBiometrics(biometrics && await lock.biometricsAvailable());
    needsPin = false;
    notifyListeners();
  }

  /// Opens the encrypted copy with the PIN. Returns null when unlocked, otherwise the attempts
  /// left; at zero the session ends (the copy stays encrypted on the device).
  Future<int?> unlock(String pin) async {
    final saved = _lockedSession;
    if (saved == null) return null;
    final left = await lock.verify(pin);
    if (left == null) {
      await _unlocked(saved);
      return null;
    }
    if (left == 0) {
      notice = 'pinLocked';
      await lock.clear();
      await vault.signOut();
      _lockedSession = null;
      locked = false;
      notifyListeners();
    }
    return left;
  }

  Future<bool> unlockWithBiometrics(String reason) async {
    final saved = _lockedSession;
    if (saved == null || !await lock.unlockWithBiometrics(reason)) return false;
    await _unlocked(saved);
    return true;
  }

  Future<void> _unlocked(FieldSession saved) async {
    _lockedSession = null;
    locked = false;
    await _open(saved);
  }

  /// The app went to the background or was hidden.
  void backgrounded() => _backgroundSince ??= _clock();

  /// Back in the foreground: after [AppLock.idle] the copy closes and the PIN is asked again.
  Future<void> foregrounded() async {
    final since = _backgroundSince;
    _backgroundSince = null;
    final current = session;
    if (since == null || current == null || locked || needsPin) return;
    if (_clock().difference(since) < AppLock.idle || !await lock.hasPin()) return;
    _lockedSession = current;
    await _close();
    locked = true;
    notifyListeners();
  }

  Future<void> _open(FieldSession value) async {
    final key = await vault.databaseKey(value.environmentUuid, value.accountUuid);
    store?.close();
    store = await openTenantStore(value.environmentUuid, key, accountUuid: value.accountUuid);
    session = value;
    final auth = _auth ??= FieldAuth(
      baseUrl: value.baseUrl,
      accessToken: value.token,
      refreshToken: value.refreshToken,
      onRotated: vault.saveRefreshToken,
    );
    api = InfraGisApi(baseUrl: value.baseUrl, client: httpClient)
        .forTenant(auth, value.environmentUuid, accountUuid: value.accountUuid);
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
    final account = session?.accountUuid;
    if (account != null) {
      AccountState? state;
      try {
        state = await client.accountState(account);
      } on ApiException {
        // Offline, no permission to read accounts or a revoked tenant: the sync below decides.
      }
      if (state == AccountState.lost) {
        syncing = false;
        await _accountLost(session!);
        notifyListeners();
        return;
      }
    }
    final report = await SyncEngine(api: client, store: current).run();
    await current.persist();
    syncing = false;
    lastReport = report;
    if (report.revoked) {
      notice = 'revoked';
      final environmentUuid = session!.environmentUuid;
      final copies = await vault.accountCopies(environmentUuid);
      await vault.forgetTenant(environmentUuid);
      await lock.clear();
      await _close();
      _auth = null;
      // The rows (photos included) are already wiped; the databases themselves go too, those of
      // the other accounts of the tenant included.
      await deleteTenantStore(environmentUuid);
      for (final copy in copies) {
        await deleteTenantStore(environmentUuid, accountUuid: copy);
      }
    } else if (report.unauthorized) {
      notice = 'sessionExpired';
      await vault.signOut();
      await lock.clear();
      await _close();
      _auth = null;
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
    await (api ?? (_choosing == null ? null : _tenantApi(_choosing!)))?.signOut();
    await vault.signOut();
    await lock.clear();
    needsPin = false;
    needsAccount = false;
    accountChoices = const [];
    _choosing = null;
    await _close();
    _auth = null;
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

/// Writes, photos or work order actions still waiting on the device (conflicts and refusals included).
bool hasPendingWork(LocalStore store) =>
    store.operations().isNotEmpty || store.photos().isNotEmpty || store.workOrderActions().isNotEmpty;
