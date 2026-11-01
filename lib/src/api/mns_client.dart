import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../version/app_build_info.dart';

/// Platform of the running client as the API expects it in `X-Mns-Client-Platform`: `web` on the
/// web build, otherwise `android`, `ios`, `windows`, `macos` or `linux` (no `dart:io` needed).
String clientPlatform({bool? web, TargetPlatform? target}) {
  if (web ?? kIsWeb) return 'web';
  return switch (target ?? defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}

/// Identity headers every MNSCloud API call sends, so the API can refuse unsupported installed
/// versions (HTTP 426 `CLIENT_VERSION_UNSUPPORTED`).
Map<String, String> clientHeaders({bool? web}) => {
      'X-Mns-Client': '${appBuildInfo.product}/${appBuildInfo.version}',
      'X-Mns-Client-Platform': clientPlatform(web: web),
    };

/// Raised once the API refused this app version; the update notice turns critical.
final clientVersionUnsupported = ValueNotifier<bool>(false);

/// HTTP client of the MNSCloud API: adds [clientHeaders] to each request and reports a 426
/// `CLIENT_VERSION_UNSUPPORTED` answer through [clientVersionUnsupported]. Third-party map servers
/// use their own clients and never get these headers.
class MnsApiClient extends http.BaseClient {
  MnsApiClient(this._inner, {ValueNotifier<bool>? unsupported, this.web})
      : _unsupported = unsupported ?? clientVersionUnsupported;

  /// Wraps [client] (a new one when null) unless it is already an API client.
  static http.Client wrap(http.Client? client) =>
      client is MnsApiClient ? client : MnsApiClient(client ?? http.Client());

  final http.Client _inner;
  final ValueNotifier<bool> _unsupported;

  /// Overrides the web/installed detection (tests); null follows the build.
  final bool? web;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers.addAll(clientHeaders(web: web));
    final response = await _inner.send(request);
    if (response.statusCode != 426) return response;
    final bytes = await response.stream.toBytes();
    if (utf8.decode(bytes, allowMalformed: true).contains('CLIENT_VERSION_UNSUPPORTED')) {
      _unsupported.value = true;
    }
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
