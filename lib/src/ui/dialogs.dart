import 'package:flutter/material.dart';

import 'strings.dart';

/// Asks before a destructive action: [messageKey] explains it, [actionKey] labels the button.
Future<bool> confirmAction(BuildContext context, String messageKey, String actionKey) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(tr(context, messageKey)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, actionKey))),
      ],
    ),
  );
  return confirmed == true;
}
