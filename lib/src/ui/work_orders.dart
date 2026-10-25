import 'package:flutter/material.dart';

import '../data/local_store.dart';
import '../field_controller.dart';
import 'asset_form.dart';
import 'strings.dart';

/// Status moves offered for an order (the API still decides).
List<String> allowedTransitions(String? status) => switch (status) {
      'OPEN' => ['IN_PROGRESS', 'CANCELLED'],
      'ASSIGNED' => ['IN_PROGRESS', 'ON_HOLD', 'CANCELLED'],
      'IN_PROGRESS' => ['ON_HOLD', 'DONE', 'CANCELLED'],
      'ON_HOLD' => ['IN_PROGRESS', 'CANCELLED'],
      _ => const [],
    };

/// Finishing needs what was done and cancelling needs the reason (the API refuses an empty note).
bool transitionNeedsNote(String status) => status == 'DONE' || status == 'CANCELLED';

String statusLabel(BuildContext context, String? status) => tr(context, 'wo.${status ?? 'OPEN'}');

/// Work orders assigned to the technician, from the offline copy.
class WorkOrdersView extends StatelessWidget {
  const WorkOrdersView({super.key, required this.controller});

  final FieldController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final orders = controller.store?.workOrders() ?? const [];
        if (orders.isEmpty) {
          return Center(
            child: Padding(padding: const EdgeInsets.all(24), child: Text(tr(context, 'noWorkOrders'), textAlign: TextAlign.center)),
          );
        }
        return ListView.builder(
          itemCount: orders.length,
          itemBuilder: (context, index) {
            final order = orders[index];
            final overdue = '${order['Overdue']}' == '1';
            return ListTile(
              leading: Icon(order['pending'] == true ? Icons.cloud_upload_outlined : Icons.assignment_outlined),
              title: Text('#${order['WorID'] ?? ''} ${order['WorTitle'] ?? ''}'),
              subtitle: Text([
                statusLabel(context, order['WorStatus'] as String?),
                if ('${order['AssetName'] ?? ''}'.isNotEmpty) '${order['AssetName']}',
                if ('${order['CustomerName'] ?? ''}'.isNotEmpty) '${order['CustomerName']}',
                if (overdue) tr(context, 'overdue'),
              ].join(' · ')),
              trailing: order['WorPriority'] == 'URGENT' || order['WorPriority'] == 'HIGH'
                  ? const Icon(Icons.priority_high, color: Colors.orangeAccent)
                  : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WorkOrderScreen(controller: controller, orderUuid: '${order['WorUUID']}'),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// One work order: start, hold, finish or cancel with a note, notes, materials, asset photos.
class WorkOrderScreen extends StatelessWidget {
  const WorkOrderScreen({super.key, required this.controller, required this.orderUuid});

  final FieldController controller;
  final String orderUuid;

  Future<String?> _askNote(BuildContext context, String title, {required bool required}) {
    final note = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: note,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(labelText: tr(context, 'note')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'cancel'))),
          FilledButton(
            onPressed: () {
              if (required && note.text.trim().isEmpty) return;
              Navigator.pop(context, note.text.trim());
            },
            child: Text(tr(context, 'save')),
          ),
        ],
      ),
    );
  }

  Future<void> _transition(BuildContext context, String status) async {
    String? note;
    if (transitionNeedsNote(status)) {
      note = await _askNote(context, statusLabel(context, status), required: true);
      if (note == null) return;
    }
    controller.workOrderAction('status', orderUuid, {'status': status, if (note != null) 'note': note});
  }

  Future<void> _addMaterial(BuildContext context) async {
    final store = controller.store!;
    final products = store.catalog('products');
    final locations = store.catalog('locations');
    if (products.isEmpty || locations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'noStockCatalog'))));
      return;
    }
    String? product = '${products.first['SprUUID']}';
    String? location = '${locations.first['StlUUID']}';
    final quantity = TextEditingController(text: '1');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr(context, 'addMaterial')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: product,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr(context, 'product')),
                items: [
                  for (final row in products)
                    DropdownMenuItem(value: '${row['SprUUID']}', child: Text('${row['SprName'] ?? ''}')),
                ],
                onChanged: (value) => setState(() => product = value),
              ),
              DropdownButtonFormField<String>(
                initialValue: location,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr(context, 'stockLocation')),
                items: [
                  for (final row in locations)
                    DropdownMenuItem(value: '${row['StlUUID']}', child: Text('${row['StlName'] ?? ''}')),
                ],
                onChanged: (value) => setState(() => location = value),
              ),
              TextField(
                controller: quantity,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr(context, 'quantity')),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'save'))),
          ],
        ),
      ),
    );
    final amount = double.tryParse(quantity.text.replaceAll(',', '.'));
    if (saved != true || product == null || location == null || amount == null || amount <= 0) return;
    String name(List<Map<String, dynamic>> rows, String key, String value, String label) =>
        '${rows.firstWhere((row) => '${row[key]}' == value, orElse: () => const {})[label] ?? ''}';
    controller.workOrderAction('material', orderUuid, {
      'productUUID': product,
      'locationUUID': location,
      'quantity': amount,
      'productName': name(products, 'SprUUID', product!, 'SprName'),
      'locationName': name(locations, 'StlUUID', location!, 'StlName'),
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final store = controller.store;
        final order = store?.workOrder(orderUuid);
        if (order == null) {
          return Scaffold(appBar: AppBar(), body: Center(child: Text(tr(context, 'noWorkOrders'))));
        }
        final status = order['WorStatus'] as String?;
        final materials = (order['materials'] is List ? order['materials'] as List : const []).whereType<Map>().toList();
        final assetUuid = '${order['InfraGisAssetIgaUUID'] ?? ''}';
        final hasAsset = assetUuid.isNotEmpty && assetUuid != 'null';
        final actions = store!.workOrderActions().where((action) => normalizeUuid(action.orderUuid) == normalizeUuid(orderUuid));
        return Scaffold(
          appBar: AppBar(title: Text('#${order['WorID'] ?? ''}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${order['WorTitle'] ?? ''}', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text([
                statusLabel(context, status),
                if (order['pending'] == true) tr(context, 'notSent'),
              ].join(' · ')),
              if ('${order['WorDescription'] ?? ''}'.isNotEmpty && order['WorDescription'] != null)
                Padding(padding: const EdgeInsets.only(top: 12), child: Text('${order['WorDescription']}')),
              const SizedBox(height: 12),
              for (final (label, key) in [
                ('customer', 'CustomerName'),
                ('asset', 'AssetName'),
                ('address', 'WorAddress'),
                ('due', 'WorDueAt'),
              ])
                if (order[key] != null && '${order[key]}'.isNotEmpty)
                  ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(tr(context, label)), subtitle: Text('${order[key]}')),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final next in allowedTransitions(status))
                    FilledButton.tonal(
                      onPressed: () => _transition(context, next),
                      child: Text(tr(context, 'wo.to.$next')),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final note = await _askNote(context, tr(context, 'addNote'), required: true);
                      if (note != null && note.isNotEmpty) controller.workOrderAction('note', orderUuid, {'note': note});
                    },
                    icon: const Icon(Icons.note_add_outlined),
                    label: Text(tr(context, 'addNote')),
                  ),
                  if (hasAsset)
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => AssetFormScreen(controller: controller, assetUuid: assetUuid)),
                      ),
                      icon: const Icon(Icons.place_outlined),
                      label: Text(tr(context, 'openAsset')),
                    ),
                ],
              ),
              const Divider(height: 32),
              Row(
                children: [
                  Expanded(child: Text(tr(context, 'materials'), style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(onPressed: () => _addMaterial(context), icon: const Icon(Icons.add)),
                ],
              ),
              if (materials.isEmpty) Text(tr(context, 'noMaterials')),
              for (final material in materials)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(material['WomStatus'] == 'ISSUED' ? Icons.check_circle_outline : Icons.inventory_2_outlined),
                  title: Text('${material['ProductName'] ?? ''}'),
                  subtitle: Text('${material['WomQuantity'] ?? ''} · ${material['LocationName'] ?? ''} · ${tr(context, 'mat.${material['WomStatus'] ?? 'PLANNED'}')}'),
                ),
              if (materials.any((material) => material['WomStatus'] != 'ISSUED') && ['IN_PROGRESS', 'ON_HOLD', 'DONE'].contains(status))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.icon(
                    onPressed: () => controller.workOrderAction('issue', orderUuid, const {}),
                    icon: const Icon(Icons.outbox_outlined),
                    label: Text(tr(context, 'issueMaterials')),
                  ),
                ),
              for (final action in actions.where((action) => action.status == 'rejected'))
                Card(
                  child: ListTile(
                    title: Text('${tr(context, 'refused')}: ${action.kind}'),
                    subtitle: Text(action.error ?? ''),
                    trailing: TextButton(
                      onPressed: () {
                        store.discardWorkOrderAction(action.uuid);
                        controller.sync();
                      },
                      child: Text(tr(context, 'discard')),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
