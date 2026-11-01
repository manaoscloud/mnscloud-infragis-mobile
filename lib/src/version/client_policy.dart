import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/mns_client.dart';
import 'runtime_version.dart';

/// Name of this app in `GET /public/clients/{app}/policy`.
const clientPolicyApp = 'infragis-mobile';

/// Version policy of the installed apps: the latest release and the minimum accepted per platform.
class ClientPolicy {
  const ClientPolicy({this.latest, this.minimum = const {}});

  final String? latest;

  /// Minimum version per platform (`android`, `ios`, `windows`, `macos`, `linux`); absent when unset.
  final Map<String, String> minimum;

  /// `data` of the policy answer; null when it is not this app's policy.
  static ClientPolicy? fromData(Object? data) {
    if (data is! Map || data['app'] != clientPolicyApp) return null;
    String? version(Object? value) {
      final normalized = normalizeVersion(value?.toString());
      return isReleaseVersion(normalized) ? normalized : null;
    }

    final raw = data['minimum'];
    return ClientPolicy(
      latest: version(data['latest']),
      minimum: {
        if (raw is Map)
          for (final entry in raw.entries)
            '${entry.key}': ?version(entry.value),
      },
    );
  }
}

/// Reads the policy from the API base [apiBase] returns; null without a base or on any failure.
Future<ClientPolicy?> fetchClientPolicy(Future<String?> Function()? apiBase, {http.Client? client}) async {
  final base = (await apiBase?.call())?.trim();
  if (base == null || base.isEmpty) return null;
  final api = MnsApiClient.wrap(client);
  try {
    final root = base.replaceAll(RegExp(r'/+$'), '');
    final response = await api
        .get(Uri.parse('$root/public/clients/$clientPolicyApp/policy'), headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body);
    return ClientPolicy.fromData(body is Map ? body['data'] : null);
  } catch (_) {
    return null;
  } finally {
    if (client == null) api.close();
  }
}
