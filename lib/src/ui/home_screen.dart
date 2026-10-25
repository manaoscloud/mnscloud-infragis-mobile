import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../data/local_store.dart';
import '../field_controller.dart';
import 'asset_form.dart';
import 'strings.dart';

/// Map, asset list and sync status of the signed-in tenant.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final FieldController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  FieldController get _controller => widget.controller;

  Future<void> _open({String? assetUuid, double? latitude, double? longitude}) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AssetFormScreen(
            controller: _controller,
            assetUuid: assetUuid,
            latitude: latitude,
            longitude: longitude,
          ),
        ),
      );

  Future<void> _collectHere() async {
    final position = await currentPosition();
    if (!mounted) return;
    if (position == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'gpsUnavailable'))));
    }
    await _open(latitude: position?.latitude, longitude: position?.longitude);
  }

  @override
  Widget build(BuildContext context) {
    final session = _controller.session!;
    final pages = [
      FieldMapView(controller: _controller, onOpen: (uuid) => _open(assetUuid: uuid)),
      AssetListView(controller: _controller, onOpen: (uuid) => _open(assetUuid: uuid)),
      SyncView(controller: _controller),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(session.environmentName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: tr(context, 'syncNow'),
            onPressed: _controller.syncing ? null : _controller.sync,
            icon: _controller.syncing
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          IconButton(tooltip: tr(context, 'signOut'), onPressed: _controller.signOut, icon: const Icon(Icons.logout)),
        ],
      ),
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: _tab == 2
          ? null
          : FloatingActionButton.extended(
              onPressed: _collectHere,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(tr(context, 'collectHere')),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.map_outlined), label: tr(context, 'map')),
          NavigationDestination(icon: const Icon(Icons.list_alt), label: tr(context, 'assets')),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _controller.store!.operations().isNotEmpty || _controller.store!.photos().isNotEmpty,
              child: const Icon(Icons.cloud_sync_outlined),
            ),
            label: tr(context, 'sync'),
          ),
        ],
      ),
    );
  }
}

/// GeoJSON of the point assets of the offline copy (lines and polygons as their stored GeoJSON).
Map<String, dynamic> assetFeatures(List<Map<String, dynamic>> assets) => {
      'type': 'FeatureCollection',
      'features': [
        for (final asset in assets)
          if (_geometry(asset) case final geometry?)
            {
              'type': 'Feature',
              'id': asset['IgaUUID'],
              'geometry': geometry,
              'properties': {
                'uuid': asset['IgaUUID'],
                'name': asset['IgaName'],
                'pending': asset['pending'] == true,
              },
            },
      ],
    };

Map<String, dynamic>? _geometry(Map<String, dynamic> asset) {
  final raw = asset['IgmGeoJson'];
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['type'] != null) {
        return decoded['type'] == 'Feature' ? decoded['geometry'] as Map<String, dynamic>? : decoded;
      }
    } catch (_) {
      // Falls back to the point.
    }
  }
  final lat = double.tryParse('${asset['IgmLatitude'] ?? ''}');
  final lng = double.tryParse('${asset['IgmLongitude'] ?? ''}');
  if (lat == null || lng == null) return null;
  return {
    'type': 'Point',
    'coordinates': [lng, lat],
  };
}

/// MapLibre map with the platform base map (style URL from `/infragis/map/config`) and the local
/// assets; pending ones are orange until the server accepts them.
class FieldMapView extends StatefulWidget {
  const FieldMapView({super.key, required this.controller, required this.onOpen});

  final FieldController controller;
  final ValueChanged<String> onOpen;

  @override
  State<FieldMapView> createState() => _FieldMapViewState();
}

class _FieldMapViewState extends State<FieldMapView> {
  static const _fallbackStyle = 'https://tiles.openfreemap.org/styles/liberty';
  MapLibreMapController? _map;
  Map<String, dynamic>? _config;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    widget.controller.api?.mapConfig().then((value) {
      if (mounted) setState(() => _config = value);
    }).catchError((_) {
      if (mounted) setState(() => _config = const {});
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  String get _style {
    final config = _config ?? const {};
    final provider = '${config['provider'] ?? 'style'}';
    if (provider == 'pmtiles' && '${config['pmtilesUrl'] ?? ''}'.startsWith('https://')) {
      return 'pmtiles://${config['pmtilesUrl']}';
    }
    final url = '${config['styleUrl'] ?? ''}';
    return url.startsWith('https://') && provider != 'mapbox' ? url : _fallbackStyle;
  }

  Future<void> _refresh() async {
    final map = _map;
    final store = widget.controller.store;
    if (!_ready || map == null || store == null) return;
    await map.setGeoJsonSource('assets', assetFeatures(store.assets()));
  }

  Future<void> _styleLoaded() async {
    final map = _map!;
    final store = widget.controller.store!;
    await map.addGeoJsonSource('assets', assetFeatures(store.assets()));
    await map.addLineLayer('assets', 'assets-lines', const LineLayerProperties(lineColor: '#21D4D4', lineWidth: 3));
    await map.addCircleLayer(
      'assets',
      'assets-points',
      const CircleLayerProperties(
        circleRadius: 7,
        circleColor: [
          'case',
          ['==', ['get', 'pending'], true],
          '#F59E0B',
          '#22C55E',
        ],
        circleStrokeColor: '#071111',
        circleStrokeWidth: 2,
      ),
      filter: ['==', ['geometry-type'], 'Point'],
    );
    map.onFeatureTapped.add((Point<double> _, LatLng __, String id, String layerId, Annotation? ___) {
      if (layerId.startsWith('assets')) widget.onOpen(id);
    });
    _ready = true;
  }

  @override
  Widget build(BuildContext context) {
    if (_config == null) return const Center(child: CircularProgressIndicator());
    final latitude = double.tryParse('${_config!['centerLatitude'] ?? ''}') ?? -14.235;
    final longitude = double.tryParse('${_config!['centerLongitude'] ?? ''}') ?? -51.9253;
    final zoom = double.tryParse('${_config!['zoom'] ?? ''}') ?? 3.5;
    final first = widget.controller.store?.assets().map(_geometry).whereType<Map<String, dynamic>>().where((g) => g['type'] == 'Point').firstOrNull;
    final coordinates = first?['coordinates'] as List?;
    return MapLibreMap(
      styleString: _style,
      myLocationEnabled: true,
      initialCameraPosition: CameraPosition(
        target: coordinates == null
            ? LatLng(latitude, longitude)
            : LatLng((coordinates[1] as num).toDouble(), (coordinates[0] as num).toDouble()),
        zoom: coordinates == null ? zoom : 15,
      ),
      onMapCreated: (map) => _map = map,
      onStyleLoadedCallback: _styleLoaded,
      attributionButtonMargins: const Point(8, 8),
    );
  }
}

/// Offline asset list with search; a cloud mark shows changes not sent yet.
class AssetListView extends StatefulWidget {
  const AssetListView({super.key, required this.controller, required this.onOpen});

  final FieldController controller;
  final ValueChanged<String> onOpen;

  @override
  State<AssetListView> createState() => _AssetListViewState();
}

class _AssetListViewState extends State<AssetListView> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final store = widget.controller.store;
        if (store == null) return const SizedBox.shrink();
        final layers = {for (final layer in store.catalog('layers')) normalizeUuid('${layer['IglUUID']}'): layer['IglName']};
        final assets = store
            .assets()
            .where((asset) => _search.isEmpty || '${asset['IgaName']}'.toLowerCase().contains(_search.toLowerCase()))
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), labelText: tr(context, 'search')),
                onChanged: (value) => setState(() => _search = value.trim()),
              ),
            ),
            Expanded(
              child: assets.isEmpty
                  ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(tr(context, 'noAssets'), textAlign: TextAlign.center)))
                  : ListView.builder(
                      itemCount: assets.length,
                      itemBuilder: (context, index) {
                        final asset = assets[index];
                        return ListTile(
                          leading: Icon(asset['pending'] == true ? Icons.cloud_upload_outlined : Icons.place_outlined),
                          title: Text('${asset['IgaName'] ?? ''}'),
                          subtitle: Text([
                            layers[normalizeUuid('${asset['InfraGisLayerIglUUID']}')] ?? '',
                            if (asset['pending'] == true) tr(context, 'notSent'),
                          ].where((part) => '$part'.isNotEmpty).join(' · ')),
                          onTap: () => widget.onOpen('${asset['IgaUUID']}'),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Queue, photos and conflicts: the user decides each conflict (keep mine or take the server).
class SyncView extends StatelessWidget {
  const SyncView({super.key, required this.controller});

  final FieldController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final store = controller.store;
        if (store == null) return const SizedBox.shrink();
        final operations = store.operations();
        final open = operations.where((operation) => operation.status != QueueStatus.pending).toList();
        final last = store.meta('lastSyncAt');
        final report = controller.lastReport;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr(context, 'lastSync')),
              subtitle: Text(last == null ? tr(context, 'never') : DateTime.parse(last).toLocal().toString().substring(0, 19)),
              trailing: FilledButton.icon(
                onPressed: controller.syncing ? null : controller.sync,
                icon: const Icon(Icons.sync),
                label: Text(tr(context, controller.syncing ? 'syncing' : 'syncNow')),
              ),
            ),
            if (report?.error != null) Text(report!.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.outbox_outlined),
              title: Text(tr(context, 'pending')),
              trailing: Text('${operations.where((operation) => operation.status == QueueStatus.pending).length}'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr(context, 'photosPending')),
              trailing: Text('${store.photos().length}'),
            ),
            const Divider(),
            Text(tr(context, 'conflicts'), style: Theme.of(context).textTheme.titleMedium),
            if (open.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(tr(context, 'noConflicts'))),
            for (final operation in open)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${operation.data['name'] ?? store.asset(operation.assetUuid)?['IgaName'] ?? operation.assetUuid}',
                          style: Theme.of(context).textTheme.titleSmall),
                      Text('${operation.kind} · ${operation.error ?? ''}'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (operation.status == QueueStatus.conflict && operation.serverItem != null)
                            FilledButton(
                              onPressed: () => controller.resolve(operation.uuid, keepMine: true),
                              child: Text(tr(context, 'keepMine')),
                            ),
                          OutlinedButton(
                            onPressed: () => controller.resolve(operation.uuid, keepMine: false),
                            child: Text(tr(context, operation.status == QueueStatus.conflict ? 'useServer' : 'discard')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
