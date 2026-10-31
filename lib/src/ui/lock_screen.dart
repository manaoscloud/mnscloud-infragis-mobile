import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../field_controller.dart';
import '../security/app_lock.dart';
import 'strings.dart';

/// First screen after a sign-in without a PIN: the field copy is protected by a local PIN (and
/// biometrics when the device has them) before it is used.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key, required this.controller});

  final FieldController controller;

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool _biometricsAvailable = false;
  bool _biometrics = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.controller.lock.biometricsAvailable().then((value) {
      if (mounted) setState(() => _biometricsAvailable = value);
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    await widget.controller.createPin(_pin.text, biometrics: _biometricsAvailable && _biometrics);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) => _LockScaffold(
        title: tr(context, 'pinCreateTitle'),
        subtitle: tr(context, 'pinCreateHelp'),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PinField(
                key: const Key('pinNew'),
                controller: _pin,
                label: tr(context, 'pinNew'),
                validator: (value) => AppLock.validPin(value ?? '') ? null : tr(context, 'pinInvalid'),
              ),
              const SizedBox(height: 12),
              _PinField(
                key: const Key('pinConfirm'),
                controller: _confirm,
                label: tr(context, 'pinConfirm'),
                validator: (value) => value == _pin.text ? null : tr(context, 'pinMismatch'),
                onSubmitted: (_) => _save(),
              ),
              if (_biometricsAvailable)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _biometrics,
                  onChanged: (value) => setState(() => _biometrics = value),
                  title: Text(tr(context, 'pinBiometrics')),
                ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _saving ? null : _save, child: Text(tr(context, 'pinSave'))),
            ],
          ),
        ),
      );
}

/// Asked when the app opens with a saved session, and after [AppLock.idle] in the background.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});

  final FieldController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pin = TextEditingController();
  bool _biometrics = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.lock.biometricsEnabled().then((value) {
      if (!mounted || !value) return;
      setState(() => _biometrics = true);
      _useBiometrics();
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _useBiometrics() async {
    setState(() => _busy = true);
    final ok = await widget.controller.unlockWithBiometrics(tr(context, 'pinBiometricsReason'));
    if (mounted && !ok) setState(() => _busy = false);
  }

  Future<void> _unlock() async {
    if (_busy || _pin.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final left = await widget.controller.unlock(_pin.text);
    if (!mounted || left == null) return;
    _pin.clear();
    setState(() {
      _busy = false;
      _error = '${tr(context, 'pinWrong')} ${tr(context, 'pinAttemptsLeft')}: $left';
    });
  }

  @override
  Widget build(BuildContext context) => _LockScaffold(
        title: tr(context, 'pinUnlockTitle'),
        subtitle: tr(context, 'pinUnlockHelp'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PinField(
              key: const Key('pinUnlock'),
              controller: _pin,
              label: tr(context, 'pin'),
              autofocus: true,
              onSubmitted: (_) => _unlock(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _unlock, child: Text(tr(context, 'pinUnlock'))),
            if (_biometrics)
              TextButton.icon(
                onPressed: _busy ? null : _useBiometrics,
                icon: const Icon(Icons.fingerprint),
                label: Text(tr(context, 'pinUseBiometrics')),
              ),
            TextButton(onPressed: widget.controller.signOut, child: Text(tr(context, 'signOut'))),
          ],
        ),
      );
}

class _PinField extends StatelessWidget {
  const _PinField({
    super.key,
    required this.controller,
    required this.label,
    this.validator,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        autofocus: autofocus,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: AppLock.maxLength,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label, counterText: ''),
        validator: validator,
        onFieldSubmitted: onSubmitted,
      );
}

class _LockScaffold extends StatelessWidget {
  const _LockScaffold({required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 16),
                    Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(subtitle, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
