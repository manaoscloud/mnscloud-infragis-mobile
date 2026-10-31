import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Error answered by the API (or the network). [status] is the HTTP status, 0 without a response.
class ApiException implements Exception {
  const ApiException(this.message, {this.status = 0});

  final String message;
  final int status;

  /// The session is no longer valid: sign in again (local data stays encrypted on the device).
  bool get unauthorized => status == 401;

  /// The tenant access or the module was removed: the local copy of that tenant must go.
  bool get revoked => status == 403 || status == 402;

  /// No answer or a server failure: keep the queue and try again later.
  bool get transient => status == 0 || status == 408 || status == 429 || status >= 500;

  @override
  String toString() => message;
}

class EnvironmentAccess {
  const EnvironmentAccess({required this.uuid, required this.name});

  final String uuid;
  final String name;
}

/// One page of the sync contract (`/infragis/sync/bootstrap` or `/infragis/sync/changes`).
class SyncPage {
  const SyncPage({
    required this.items,
    required this.cursor,
    required this.done,
    this.catalog,
  });

  final List<Map<String, dynamic>> items;
  final String cursor;
  final bool done;
  final Map<String, List<Map<String, dynamic>>>? catalog;
}

/// Contract of the API used by the sync engine (a fake implements it in tests).
abstract class FieldApi {
  Future<SyncPage> bootstrap(String? cursor);
  Future<SyncPage> changes(String cursor, {bool catalog = false});
  Future<List<Map<String, dynamic>>> push(List<Map<String, dynamic>> operations);
  Future<Map<String, dynamic>> uploadAttachment({
    required String assetUuid,
    required String attachmentUuid,
    required Uint8List bytes,
    required String fileName,
    required String kind,
    String? caption,
    double? latitude,
    double? longitude,
    DateTime? capturedAt,
  });

  /// Open work orders assigned to the signed-in user.
  Future<List<Map<String, dynamic>>> myWorkOrders();
  Future<List<Map<String, dynamic>>> workOrderMaterials(String orderUuid);
  Future<List<Map<String, dynamic>>> workOrderChecklist(String orderUuid);
  /// Stock products and locations for the material picker.
  Future<List<Map<String, dynamic>>> stockProducts();
  Future<List<Map<String, dynamic>>> stockLocations();
  /// One queued field action: `status`, `note`, `material`, `issue` or `check` (checklist item).
  Future<void> sendWorkOrderAction(String kind, String orderUuid, Map<String, dynamic> body);
}

/// Result of the field sign-in: the short access token and, on native platforms, the rotating
/// refresh token (the web keeps it only in the HttpOnly cookie the API sets).
class FieldTokens {
  const FieldTokens({required this.accessToken, this.refreshToken});

  final String accessToken;
  final String? refreshToken;
}

/// Tokens of the InfraGIS field session (`/infragis/auth/*`): the access token lives in memory
/// and lasts minutes; the refresh token rotates on every use. A 401 refreshes once and repeats the
/// request. Native clients send the refresh token they keep in secure storage ([onRotated] saves
/// each new one); the web sends nothing and the browser presents the HttpOnly cookie.
/// A session saved by an older version (platform token, no refresh token) keeps working until it
/// expires, then asks for a new sign-in.
class FieldAuth {
  FieldAuth({
    required this.baseUrl,
    this.accessToken,
    this.refreshToken,
    this.onRotated,
    http.Client? client,
    bool? web,
  })  : _client = client ?? http.Client(),
        web = web ?? kIsWeb;

  final String baseUrl;
  final bool web;
  final Future<void> Function(String? refreshToken)? onRotated;
  final http.Client _client;
  String? accessToken;
  String? refreshToken;
  Future<bool>? _refreshing;

  bool get canRefresh => web || (refreshToken?.isNotEmpty ?? false);

  /// One refresh at a time: concurrent requests that got a 401 wait for the same rotation.
  Future<bool> refresh() {
    final running = _refreshing;
    if (running != null) return running;
    final next = _rotate();
    _refreshing = next;
    next.whenComplete(() => _refreshing = null).ignore();
    return next;
  }

  Future<bool> _rotate() async {
    if (!canRefresh) return false;
    final root = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$root/infragis/auth/refresh'),
            headers: const {'Accept': 'application/json', 'Content-Type': 'application/json'},
            body: jsonEncode(web ? const {} : {'refreshToken': refreshToken}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (error) {
      throw ApiException('Network unavailable: $error');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      accessToken = null;
      refreshToken = null;
      await onRotated?.call(null);
      return false;
    }
    final tokens = InfraGisApi.fieldTokens(InfraGisApi.decode(response));
    accessToken = tokens.accessToken;
    if (!web) {
      refreshToken = tokens.refreshToken;
      await onRotated?.call(refreshToken);
    }
    return true;
  }
}

/// MNSCloud API client: the platform login, tenant access and the InfraGIS field routes.
class InfraGisApi implements FieldApi {
  InfraGisApi({
    required this.baseUrl,
    this.auth,
    this.environmentUuid,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final FieldAuth? auth;
  final String? environmentUuid;
  final http.Client _client;

  String? get token => auth?.accessToken;

  InfraGisApi forTenant(FieldAuth auth, String environmentUuid) => InfraGisApi(
        baseUrl: baseUrl,
        auth: auth,
        environmentUuid: environmentUuid,
        client: _client,
      );

  Uri uri(String path, [Map<String, String>? query]) {
    final root = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final normalized = path.startsWith('/') ? path : '/$path';
    final parsed = Uri.parse('$root$normalized');
    return query == null ? parsed : parsed.replace(queryParameters: query);
  }

  Map<String, String> headers({bool json = true}) => {
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
        if (environmentUuid != null && environmentUuid!.isNotEmpty)
          'X-Environment-UUID': environmentUuid!,
      };

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    var response = await _attempt(request);
    // The access token lasts minutes: a 401 rotates the session once and repeats the request.
    final session = auth;
    if (response.statusCode == 401 && session != null && session.canRefresh && await session.refresh()) {
      response = await _attempt(request);
    }
    return decode(response);
  }

  Future<http.Response> _attempt(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 60));
    } catch (error) {
      throw ApiException('Network unavailable: $error');
    }
  }

  static Map<String, dynamic> decode(http.Response response) {
    Map<String, dynamic> payload;
    try {
      final body = response.body.trim().isEmpty ? '{}' : response.body;
      final decoded = jsonDecode(body);
      payload = decoded is Map<String, dynamic> ? decoded : {'data': decoded};
    } catch (_) {
      payload = {'error': 'Unexpected response'};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = payload['error'] ?? payload['message'] ?? 'Request failed';
      throw ApiException('$message (${response.statusCode})', status: response.statusCode);
    }
    return payload;
  }

  static Map<String, dynamic> data(Map<String, dynamic> payload) {
    final data = payload['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  /// Field session of the platform account (`/infragis/auth/signin`), independent of the App.
  Future<FieldTokens> signIn(String email, String password, {String? deviceName}) async {
    final payload = await _send(
      () => _client.post(
        uri('/infragis/auth/signin'),
        headers: headers(),
        body: jsonEncode({
          'email': email,
          'password': password,
          'clientKind': kIsWeb ? 'web' : 'native',
          'deviceName': ?deviceName,
        }),
      ),
    );
    return fieldTokens(payload);
  }

  static FieldTokens fieldTokens(Map<String, dynamic> payload) {
    final body = data(payload);
    final access = body['accessToken'];
    if (access is! String || access.trim().isEmpty) {
      throw const ApiException('The API did not return a session token.');
    }
    final refresh = body['refreshToken'];
    return FieldTokens(
      accessToken: access.trim(),
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
    );
  }

  /// Ends the field session on the server (best effort: the device forgets it anyway).
  Future<void> signOut() async {
    try {
      await _send(() => _client.post(uri('/infragis/auth/signout'), headers: headers()));
    } catch (_) {
      // Offline or already ended.
    }
  }

  Future<List<EnvironmentAccess>> listAccess() async {
    final payload = await _send(() => _client.get(uri('/user/access'), headers: headers()));
    final raw = payload['data'];
    final items = raw is Map<String, dynamic>
        ? (raw['items'] ?? raw['environments'] ?? raw['access'] ?? const [])
        : raw;
    return (items is List ? items : const [])
        .whereType<Map>()
        .map((item) {
          String? pick(List<String> keys) {
            for (final key in keys) {
              final value = item[key];
              if (value is String && value.trim().isNotEmpty) return value.trim();
            }
            return null;
          }

          final uuid = pick(['EnvironmentUUID', 'EnvironmentEnvUUID', 'environmentUUID', 'uuid']);
          if (uuid == null) return null;
          final name = pick(['EnvironmentName', 'EnvName', 'environmentName', 'name']);
          return EnvironmentAccess(uuid: uuid, name: name ?? uuid);
        })
        .whereType<EnvironmentAccess>()
        .toList();
  }

  /// Platform map base (style URL, attribution, initial view) for the map screen.
  Future<Map<String, dynamic>> mapConfig() async {
    final payload = await _send(() => _client.get(uri('/infragis/map/config'), headers: headers()));
    final body = data(payload);
    final item = body['item'] ?? body['config'] ?? body;
    return item is Map<String, dynamic> ? item : <String, dynamic>{};
  }

  SyncPage _page(Map<String, dynamic> payload) {
    final body = data(payload);
    final items = (body['items'] is List ? body['items'] as List : const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    Map<String, List<Map<String, dynamic>>>? catalog;
    if (body['catalog'] is Map) {
      catalog = {
        for (final entry in (body['catalog'] as Map).entries)
          '${entry.key}': (entry.value is List ? entry.value as List : const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
      };
    }
    return SyncPage(
      items: items,
      cursor: '${body['cursor'] ?? ''}',
      done: body['done'] == true,
      catalog: catalog,
    );
  }

  @override
  Future<SyncPage> bootstrap(String? cursor) async => _page(
        await _send(
          () => _client.get(
            uri('/infragis/sync/bootstrap', {'cursor': ?cursor}),
            headers: headers(),
          ),
        ),
      );

  @override
  Future<SyncPage> changes(String cursor, {bool catalog = false}) async => _page(
        await _send(
          () => _client.get(
            uri('/infragis/sync/changes', {'cursor': cursor, if (catalog) 'catalog': '1'}),
            headers: headers(),
          ),
        ),
      );

  @override
  Future<List<Map<String, dynamic>>> push(List<Map<String, dynamic>> operations) async {
    final payload = await _send(
      () => _client.post(
        uri('/infragis/sync/push'),
        headers: headers(),
        body: jsonEncode({'operations': operations}),
      ),
    );
    final results = data(payload)['results'];
    return (results is List ? results : const []).whereType<Map<String, dynamic>>().toList();
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> payload) {
    final items = data(payload)['items'];
    return (items is List ? items : const []).whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<List<Map<String, dynamic>>> myWorkOrders() async => _items(
        await _send(
          () => _client.get(
            uri('/workorders/orders', {'mine': '1', 'openOnly': '1', 'limit': '200'}),
            headers: headers(),
          ),
        ),
      );

  @override
  Future<List<Map<String, dynamic>>> workOrderMaterials(String orderUuid) async => _items(
        await _send(() => _client.get(uri('/workorders/orders/$orderUuid/materials'), headers: headers())),
      );

  @override
  Future<List<Map<String, dynamic>>> workOrderChecklist(String orderUuid) async => _items(
        await _send(() => _client.get(uri('/workorders/orders/$orderUuid/checklist'), headers: headers())),
      );

  @override
  Future<List<Map<String, dynamic>>> stockProducts() async => _items(
        await _send(() => _client.get(uri('/sale/products', {'limit': '1000'}), headers: headers())),
      );

  @override
  Future<List<Map<String, dynamic>>> stockLocations() async => _items(
        await _send(() => _client.get(uri('/stock/locations', {'limit': '500'}), headers: headers())),
      );

  @override
  Future<void> sendWorkOrderAction(String kind, String orderUuid, Map<String, dynamic> body) async {
    final path = switch (kind) {
      'status' => '/workorders/orders/$orderUuid/status',
      'note' => '/workorders/orders/$orderUuid/notes',
      'material' => '/workorders/orders/$orderUuid/materials',
      'issue' => '/workorders/orders/$orderUuid/materials/issue',
      'check' => '/workorders/checklist/${body['itemUUID']}',
      _ => throw ApiException('Unknown work order action $kind', status: 400),
    };
    // Checking sets the state of the item (PUT), so a retry is harmless.
    await _send(() => kind == 'check'
        ? _client.put(uri(path), headers: headers(), body: jsonEncode(body))
        : _client.post(uri(path), headers: headers(), body: jsonEncode(body)));
  }

  @override
  Future<Map<String, dynamic>> uploadAttachment({
    required String assetUuid,
    required String attachmentUuid,
    required Uint8List bytes,
    required String fileName,
    required String kind,
    String? caption,
    double? latitude,
    double? longitude,
    DateTime? capturedAt,
  }) async {
    // A new request per attempt: a multipart request can be sent only once (the 401 retry).
    http.MultipartRequest build() {
      final request = http.MultipartRequest('POST', uri('/infragis/assets/$assetUuid/attachments'))
        ..headers.addAll(headers(json: false))
        ..fields['attachmentUUID'] = attachmentUuid
        ..fields['kind'] = kind;
      if (caption != null && caption.isNotEmpty) request.fields['caption'] = caption;
      if (latitude != null && longitude != null) {
        request.fields['latitude'] = '$latitude';
        request.fields['longitude'] = '$longitude';
      }
      if (capturedAt != null) request.fields['capturedAt'] = capturedAt.toUtc().toIso8601String();
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
      return request;
    }

    final payload = await _send(() async => http.Response.fromStream(await _client.send(build())));
    final item = data(payload)['item'];
    return item is Map<String, dynamic> ? item : <String, dynamic>{};
  }
}
