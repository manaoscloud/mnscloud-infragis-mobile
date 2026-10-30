import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/infragis_api.dart';
import '../api/web_api_base.dart';
import '../data/session_vault.dart';
import '../field_controller.dart';
import 'access_shell.dart';
import 'strings.dart';

/// Platform login (the MNSCloud API account) and tenant choice. No separate field credentials.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});

  final FieldController controller;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrl = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.vault.lastBaseUrl().then((value) {
      if (value != null && mounted && _baseUrl.text.isEmpty) _baseUrl.text = value;
    });
  }

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
      final baseUrl = kIsWeb ? webApiBaseUrl() : _baseUrl.text.trim();
      final auth = InfraGisApi(baseUrl: baseUrl);
      final token = await auth.signIn(_email.text.trim(), _password.text);
      final environments = await InfraGisApi(baseUrl: baseUrl, token: token).listAccess();
      if (!mounted) return;
      if (environments.isEmpty) throw ApiException(tr(context, 'noEnvironment'));
      final selected = environments.length == 1 ? environments.first : await _choose(environments);
      if (selected == null || !mounted) return;
      await widget.controller.signIn(
        FieldSession(
          baseUrl: baseUrl,
          token: token,
          environmentUuid: selected.uuid,
          environmentName: selected.name,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<EnvironmentAccess?> _choose(List<EnvironmentAccess> environments) =>
      showModalBottomSheet<EnvironmentAccess>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(tr(context, 'chooseEnvironment'))),
              for (final environment in environments)
                ListTile(
                  leading: const Icon(Icons.business_rounded),
                  title: Text(environment.name),
                  onTap: () => Navigator.of(context).pop(environment),
                ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final notice = widget.controller.notice;
    String? required(String? value) =>
        value == null || value.trim().isEmpty ? tr(context, 'required') : null;
    final brand = widget.controller.brand.value;
    // Same themed access screen as POS, Pulse and PhoneWeb (Settings › Themes › Login do InfraGIS).
    return Scaffold(
      body: SafeArea(
        child: AccessShell(
          controller: widget.controller,
          child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AccessHeading(
                      eyebrow: accessText(context, brand, 'eyebrow'),
                      title: accessText(context, brand, 'title'),
                      subtitle: accessText(context, brand, 'subtitle'),
                    ),
                    if (notice != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          tr(context, notice),
                          style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
                        ),
                      ),
                    // The web app is served by the platform: its API is the same origin.
                    if (!kIsWeb)
                      TextFormField(
                        controller: _baseUrl,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: tr(context, 'apiUrl'),
                          hintText: tr(context, 'apiUrlHint'),
                        ),
                        validator: (value) {
                          final uri = Uri.tryParse(value?.trim() ?? '');
                          return uri == null || uri.scheme != 'https' || uri.host.isEmpty
                              ? tr(context, 'apiUrlHint')
                              : null;
                        },
                      ),
                    if (!kIsWeb) const SizedBox(height: 12),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(labelText: tr(context, 'email')),
                      validator: required,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(labelText: tr(context, 'password')),
                      validator: required,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    // Same platform account as the App: recovery is the App page of the domain (web).
                    if (kIsWeb)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const Key('forgotPassword'),
                          onPressed: () => openAccessLink(context, Uri.base.resolve('/auth/forgot-password').toString()),
                          child: Text(tr(context, 'forgotPassword')),
                        ),
                      )
                    else
                      const SizedBox(height: 20),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(tr(context, 'signIn')),
                    ),
                  ],
                ),
              ),
        ),
      ),
    );
  }
}
