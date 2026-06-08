import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MnsCloudInfraGisMobileApp());
}

class MnsCloudInfraGisMobileApp extends StatelessWidget {
  const MnsCloudInfraGisMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MNSCloud InfraGIS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF21D4D4),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF071111),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}

class ApiSession {
  const ApiSession({
    required this.baseUrl,
    required this.token,
    required this.environmentUuid,
    required this.environmentName,
  });

  final String baseUrl;
  final String token;
  final String environmentUuid;
  final String environmentName;
}

class EnvironmentAccess {
  const EnvironmentAccess({required this.uuid, required this.name});

  final String uuid;
  final String name;
}

class InfraGisApiClient {
  InfraGisApiClient({required this.baseUrl, this.token, this.environmentUuid});

  final String baseUrl;
  final String? token;
  final String? environmentUuid;

  Uri _uri(String path, [Map<String, String>? query]) {
    final root = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$root$normalized').replace(queryParameters: query);
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    if (environmentUuid != null && environmentUuid!.isNotEmpty) {
      headers['X-Environment-UUID'] = environmentUuid!;
    }
    return headers;
  }

  Future<Map<String, dynamic>> signIn(String email, String password) async {
    final response = await http.post(
      _uri('/auth/signin'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    );
    return _decodeResponse(response);
  }

  Future<List<EnvironmentAccess>> listAccess() async {
    final response = await http.get(_uri('/user/access'), headers: _headers);
    final payload = _decodeResponse(response);
    final data = payload['data'];
    final rawItems = data is Map<String, dynamic>
        ? (data['items'] ?? data['environments'] ?? data['access'] ?? const [])
        : data;
    final items = rawItems is List ? rawItems : const [];
    return items
        .whereType<Map>()
        .map((item) {
          final uuid = _firstString(item, const [
            'EnvironmentUUID',
            'EnvironmentEnvUUID',
            'environmentUUID',
            'uuid',
          ]);
          final name = _firstString(item, const [
            'EnvironmentName',
            'EnvName',
            'environmentName',
            'name',
          ]);
          if (uuid == null || uuid.isEmpty) return null;
          return EnvironmentAccess(uuid: uuid, name: name ?? uuid);
        })
        .whereType<EnvironmentAccess>()
        .toList();
  }

  Future<Map<String, dynamic>> dashboard() async {
    final response = await http.get(_uri('/infragis/'), headers: _headers);
    return _decodeResponse(response);
  }

  Future<List<Map<String, dynamic>>> projects() async {
    final response = await http.get(
      _uri('/infragis/projects', {'limit': '1000', 'offset': '0'}),
      headers: _headers,
    );
    final payload = _decodeResponse(response);
    final data = payload['data'];
    final items = data is Map<String, dynamic> ? data['items'] : data;
    return items is List ? items.whereType<Map<String, dynamic>>().toList() : const [];
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final body = response.body.trim().isEmpty ? '{}' : response.body;
    final decoded = jsonDecode(body);
    final payload = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{'data': decoded};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = payload['error'] ?? payload['message'] ?? 'Request failed';
      throw ApiException('$message (${response.statusCode})');
    }
    return payload;
  }

  static String? _firstString(Map item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }
}

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrl = TextEditingController(text: 'https://dev.publichost.cloud/api/v1');
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _baseUrl.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final baseUrl = _baseUrl.text.trim();
      final authClient = InfraGisApiClient(baseUrl: baseUrl);
      final signInPayload = await authClient.signIn(_email.text.trim(), _password.text);
      final token = _extractToken(signInPayload);
      if (token == null || token.isEmpty) {
        throw const ApiException('API did not return a session token.');
      }

      final accessClient = InfraGisApiClient(baseUrl: baseUrl, token: token);
      final environments = await accessClient.listAccess();
      if (!mounted) return;
      if (environments.isEmpty) {
        throw const ApiException('No tenant access returned for this user.');
      }

      if (environments.length == 1) {
        _openDashboard(baseUrl, token, environments.first);
        return;
      }

      final selected = await showModalBottomSheet<EnvironmentAccess>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text('Select environment'),
                subtitle: Text('Choose the tenant that will authorize this session.'),
              ),
              for (final environment in environments)
                ListTile(
                  leading: const Icon(Icons.business_rounded),
                  title: Text(environment.name),
                  subtitle: Text(environment.uuid),
                  onTap: () => Navigator.of(context).pop(environment),
                ),
            ],
          ),
        ),
      );
      if (!mounted || selected == null) return;
      _openDashboard(baseUrl, token, selected);
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _extractToken(Map<String, dynamic> payload) {
    final data = payload['data'];
    final candidates = <dynamic>[
      payload['token'],
      payload['jwt'],
      payload['accessToken'],
      if (data is Map<String, dynamic>) data['token'],
      if (data is Map<String, dynamic>) data['jwt'],
      if (data is Map<String, dynamic>) data['accessToken'],
    ];
    for (final candidate in candidates) {
      if (candidate is String && candidate.trim().isNotEmpty) return candidate.trim();
    }
    return null;
  }

  void _openDashboard(String baseUrl, String token, EnvironmentAccess environment) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DashboardScreen(
          session: ApiSession(
            baseUrl: baseUrl,
            token: token,
            environmentUuid: environment.uuid,
            environmentName: environment.name,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              margin: const EdgeInsets.all(20),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.map_rounded, size: 52, color: Color(0xFF21D4D4)),
                      const SizedBox(height: 16),
                      Text(
                        'MNSCloud InfraGIS',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _baseUrl,
                        decoration: const InputDecoration(
                          labelText: 'API base URL',
                          prefixIcon: Icon(Icons.cloud_rounded),
                        ),
                        validator: (value) =>
                            value == null || !value.startsWith('http') ? 'Enter a valid URL.' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.mail_rounded),
                        ),
                        validator: (value) =>
                            value == null || !value.contains('@') ? 'Enter your email.' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock_rounded),
                        ),
                        validator: (value) =>
                            value == null || value.isEmpty ? 'Enter your password.' : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _loading ? null : _submit,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.login_rounded),
                        label: const Text('Sign in'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({required this.session, super.key});

  final ApiSession session;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final InfraGisApiClient _client;
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _summary = const {};
  List<Map<String, dynamic>> _projects = const [];

  @override
  void initState() {
    super.initState();
    _client = InfraGisApiClient(
      baseUrl: widget.session.baseUrl,
      token: widget.session.token,
      environmentUuid: widget.session.environmentUuid,
    );
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dashboard = await _client.dashboard();
      final projects = await _client.projects();
      final data = dashboard['data'];
      setState(() {
        _summary = data is Map<String, dynamic> ? data : const {};
        _projects = projects;
      });
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Object _metric(String key) {
    final summary = _summary['summary'];
    if (summary is Map<String, dynamic>) return summary[key] ?? 0;
    return _summary[key] ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('InfraGIS'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.session.environmentName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _MetricCard(label: 'Projects', value: _metric('ProjectCount')),
                _MetricCard(label: 'Layers', value: _metric('LayerCount')),
                _MetricCard(label: 'Assets', value: _metric('AssetCount')),
                _MetricCard(label: 'Active', value: _metric('ActiveAssetCount')),
              ],
            ),
            const SizedBox(height: 20),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.error_outline_rounded),
                  title: Text(_error!),
                ),
              ),
            Text(
              'Projects',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (_projects.isEmpty && !_loading)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.layers_clear_rounded),
                  title: Text('No projects available'),
                  subtitle: Text('Create projects in the MNSCloud App before syncing field work.'),
                ),
              ),
            for (final project in _projects)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.map_outlined),
                  title: Text('${project['IprName'] ?? project['name'] ?? 'Project'}'),
                  subtitle: Text('${project['IprCode'] ?? project['IprUUID'] ?? ''}'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final Object value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 156,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(
                '$value',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
