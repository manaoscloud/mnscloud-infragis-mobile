import 'dart:convert';
import 'dart:typed_data';

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
  /// Stock products and locations for the material picker.
  Future<List<Map<String, dynamic>>> stockProducts();
  Future<List<Map<String, dynamic>>> stockLocations();
  /// One queued field action: `status`, `note`, `material` or `issue`.
  Future<void> sendWorkOrderAction(String kind, String orderUuid, Map<String, dynamic> body);
}

/// MNSCloud API client: the platform login, tenant access and the InfraGIS field routes.
class InfraGisApi implements FieldApi {
  InfraGisApi({
    required this.baseUrl,
    this.token,
    this.environmentUuid,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String? token;
  final String? environmentUuid;
  final http.Client _client;

  InfraGisApi forTenant(String token, String environmentUuid) => InfraGisApi(
        baseUrl: baseUrl,
        token: token,
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
    http.Response response;
    try {
      response = await request().timeout(const Duration(seconds: 60));
    } catch (error) {
      throw ApiException('Network unavailable: $error');
    }
    return decode(response);
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

  Future<String> signIn(String email, String password) async {
    final payload = await _send(
      () => _client.post(
        uri('/auth/signin'),
        headers: headers(),
        body: jsonEncode({'email': email, 'password': password}),
      ),
    );
    final body = data(payload);
    for (final candidate in [
      payload['token'],
      payload['accessToken'],
      body['token'],
      body['accessToken'],
      body['jwt'],
    ]) {
      if (candidate is String && candidate.trim().isNotEmpty) return candidate.trim();
    }
    throw const ApiException('The API did not return a session token.');
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
            uri('/infragis/sync/bootstrap', {if (cursor != null) 'cursor': cursor}),
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
      _ => throw ApiException('Unknown work order action $kind', status: 400),
    };
    await _send(() => _client.post(uri(path), headers: headers(), body: jsonEncode(body)));
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
    final payload = await _send(() async => http.Response.fromStream(await _client.send(request)));
    final item = data(payload)['item'];
    return item is Map<String, dynamic> ? item : <String, dynamic>{};
  }
}
