import 'package:flutter/material.dart';

import '../api/infragis_api.dart';
import '../field_controller.dart';
import 'access_shell.dart';
import 'strings.dart';

/// Label of an InfraGIS account: the legacy internal account (named by the server) is the own network.
String accountLabel(BuildContext context, AccountOption account) =>
    account.legacy ? tr(context, 'ownNetwork') : account.name;

/// After the tenant, the operator chooses the InfraGIS account whose encrypted copy opens.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.controller});

  final FieldController controller;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _opening = false;

  Future<void> _select(AccountOption account) async {
    setState(() => _opening = true);
    try {
      await widget.controller.selectAccount(account);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final notice = controller.notice;
    return Scaffold(
      body: SafeArea(
        child: AccessShell(
          controller: controller,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AccessHeading(
                eyebrow: tr(context, 'accessEyebrow'),
                title: tr(context, 'chooseAccount'),
                subtitle: tr(context, 'chooseAccountText'),
              ),
              if (notice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    tr(context, notice),
                    style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
                  ),
                ),
              if (_opening)
                const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
              else
                for (final account in controller.accountChoices)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      key: Key('account-${account.uuid}'),
                      leading: Icon(account.customer == null ? Icons.hub_outlined : Icons.business_outlined),
                      title: Text(accountLabel(context, account), overflow: TextOverflow.ellipsis),
                      subtitle: account.customer == null ? null : Text(account.customer!),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _select(account),
                    ),
                  ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _opening ? null : controller.signOut,
                icon: const Icon(Icons.logout),
                label: Text(tr(context, 'signOut')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
