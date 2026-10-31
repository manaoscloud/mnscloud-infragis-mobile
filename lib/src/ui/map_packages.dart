import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;

import '../data/local_store.dart';
import '../field_controller.dart';
import '../map/offline_map.dart';
import 'strings.dart';

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Asks for a name and shows the tile count and estimated size of the visible area before the
/// download, then copies it with a progress bar into a new offline package.
Future<void> downloadMapArea({
  required BuildContext context,
  required FieldController controller,
  required Map<String, vt.VectorTileProvider> sources,
  required MapBox box,
  required int zoom,
}) async {
  final maxZoom = sources.values.map((source) => math.min(source.maximumZoom, 15)).reduce(math.max);
  final minZoom = math.max(0, math.min(zoom, maxZoom) - 3);
  final total = sources.values.fold<int>(
    0,
    (sum, source) => sum + tileCount(box, math.max(minZoom, source.minimumZoom), math.min(maxZoom, source.maximumZoom)),
  );
  if (total > mapPackageMaxTiles) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'mapAreaTooLarge'))));
    return;
  }
  final name = TextEditingController(
    text: '${tr(context, 'mapArea')} ${controller.store!.mapPackages().length + 1}',
  );
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr(context, 'mapDownload')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(controller: name, decoration: InputDecoration(labelText: tr(context, 'mapAreaName'))),
          const SizedBox(height: 16),
          Text('${tr(context, 'mapTiles')}: $total · ${tr(context, 'mapEstimate')} ${formatBytes(total * mapTileEstimateBytes)}'),
          Text('${tr(context, 'mapZooms')}: $minZoom-$maxZoom · ${tr(context, 'mapValidity')} $mapPackageValidityDays ${tr(context, 'days')}'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'download'))),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final progress = ValueNotifier(MapDownloadProgress(0, total, 0));
  var cancelled = false;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(tr(context, 'mapDownloading')),
      content: ValueListenableBuilder(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: value.total == 0 ? null : value.done / value.total),
            const SizedBox(height: 12),
            Text('${value.done} / ${value.total} · ${formatBytes(value.bytes)}'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
          },
          child: Text(tr(context, 'cancel')),
        ),
      ],
    ),
  );
  String message;
  try {
    final package = await downloadMapPackage(
      store: controller.store!,
      sources: sources,
      name: name.text.trim().isEmpty ? tr(context, 'mapArea') : name.text.trim(),
      box: box,
      minZoom: minZoom,
      maxZoom: maxZoom,
      onProgress: (value) => progress.value = value,
      cancelled: () => cancelled,
    );
    await controller.store!.persist();
    message = package.complete ? 'mapDownloaded' : 'mapDownloadIncomplete';
  } on MapDownloadException {
    await controller.store?.persist();
    message = 'mapDownloadIncomplete';
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  progress.dispose();
  name.dispose();
  controller.changed();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, message))));
}

/// Offline map areas of the tenant with size and validity; removing one keeps the pending changes.
class MapPackagesCard extends StatelessWidget {
  const MapPackagesCard({super.key, required this.controller});

  final FieldController controller;

  Future<void> _remove(BuildContext context, MapPackage package) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'mapRemoveConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'remove'))),
        ],
      ),
    );
    if (confirmed == true) await controller.removeMapPackage(package.uuid);
  }

  @override
  Widget build(BuildContext context) {
    final packages = controller.store?.mapPackages() ?? const <MapPackage>[];
    final now = DateTime.now();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: Text(tr(context, 'mapPackages')),
            subtitle: Text(packages.isEmpty ? tr(context, 'mapPackagesEmpty') : tr(context, 'mapPackagesHelp')),
          ),
          for (final package in packages)
            ListTile(
              key: ValueKey('map-package-${package.uuid}'),
              title: Text(package.name),
              subtitle: Text([
                formatBytes(package.bytes),
                '${package.tiles} ${tr(context, 'mapTiles').toLowerCase()}',
                if (!package.complete) tr(context, 'mapIncomplete'),
                if (package.expired(now))
                  tr(context, 'mapExpired')
                else
                  '${tr(context, 'mapValidUntil')} ${MaterialLocalizations.of(context).formatShortDate(package.expiresAt.toLocal())}',
              ].join(' · ')),
              trailing: IconButton(
                tooltip: tr(context, 'remove'),
                onPressed: () => _remove(context, package),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
        ],
      ),
    );
  }
}
