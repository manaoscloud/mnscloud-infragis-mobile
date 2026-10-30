import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:latlong2/latlong.dart';

import '../data/local_store.dart';
import '../field_controller.dart';
import '../pwa/install_app_button.dart';
import 'asset_form.dart';
import 'strings.dart';
import 'work_orders.dart';

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
    final orders = _controller.workOrdersAvailable;
    final pages = [
      FieldMapView(controller: _controller, onOpen: (uuid) => _open(assetUuid: uuid)),
      AssetListView(controller: _controller, onOpen: (uuid) => _open(assetUuid: uuid)),
      if (orders) WorkOrdersView(controller: _controller),
      SyncView(controller: _controller),
    ];
    // The orders tab comes and goes with the Work orders module.
    final tab = _tab.clamp(0, pages.length - 1);
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
          const InstallAppButton(),
          IconButton(tooltip: tr(context, 'signOut'), onPressed: _controller.signOut, icon: const Icon(Icons.logout)),
        ],
      ),
      body: IndexedStack(index: tab, children: pages),
      floatingActionButton: tab >= 2
          ? null
          : FloatingActionButton.extended(
              onPressed: _collectHere,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(tr(context, 'collectHere')),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.map_outlined), label: tr(context, 'map')),
          NavigationDestination(icon: const Icon(Icons.list_alt), label: tr(context, 'assets')),
          if (orders)
            NavigationDestination(icon: const Icon(Icons.assignment_outlined), label: tr(context, 'workOrders')),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _controller.store!.operations().isNotEmpty ||
                  _controller.store!.photos().isNotEmpty ||
                  _controller.store!.workOrderActions().isNotEmpty,
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

/// Field map on every platform (flutter_map + MapLibre-style vector tiles): the platform base map
/// from `/infragis/map/config` and the local assets on top; pending ones are orange until the
/// server accepts them. Same providers as the App (`style` URL, own `pmtiles` archive with the
/// Protomaps light flavor, `none`); Mapbox is refused. Without a base map the assets still show.
class FieldMapView extends StatefulWidget {
  const FieldMapView({super.key, required this.controller, required this.onOpen});

  final FieldController controller;
  final ValueChanged<String> onOpen;

  @override
  State<FieldMapView> createState() => _FieldMapViewState();
}

class _FieldMapViewState extends State<FieldMapView> {
  static const _protomapsStyle = 'asset://assets/map/protomaps-light.json';
  final _hits = LayerHitNotifier<String>(null);
  Map<String, dynamic>? _config;
  vt.Style? _style;
  LatLng? _me;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _hits.addListener(_tapped);
    widget.controller.api?.mapConfig().then(_loaded).catchError((_) => _loaded(const {}));
    currentPosition().then((position) {
      if (mounted && position != null) setState(() => _me = LatLng(position.latitude, position.longitude));
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _hits.dispose();
    _style?.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _tapped() {
    final uuid = _hits.value?.hitValues.firstOrNull;
    if (uuid != null) widget.onOpen(uuid);
  }

  Future<void> _loaded(Map<String, dynamic> config) async {
    if (!mounted) return;
    setState(() => _config = config);
    final style = await _readStyle(config);
    if (!mounted) {
      style?.dispose();
      return;
    }
    setState(() => _style = style);
  }

  Future<vt.Style?> _readStyle(Map<String, dynamic> config) async {
    final provider = '${config['provider'] ?? 'style'}';
    final pmtiles = '${config['pmtilesUrl'] ?? ''}';
    final styleUrl = '${config['styleUrl'] ?? ''}';
    try {
      if (provider == 'pmtiles' && pmtiles.startsWith('https://')) {
        return await vt.StyleReader(
          uri: _protomapsStyle,
          language: 'pt',
          resolveProvider: (id) async => id == 'protomaps' ? vt.PmTilesVectorTileProvider.open(pmtiles) : null,
        ).read();
      }
      if (provider == 'style' && styleUrl.startsWith('https://')) {
        return await vt.StyleReader(uri: styleUrl, language: 'pt').read();
      }
    } catch (_) {
      // No base map (offline before the first load, or an unreachable style): assets only.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config == null) return const Center(child: CircularProgressIndicator());
    final store = widget.controller.store;
    final assets = store?.assets() ?? const <Map<String, dynamic>>[];
    final points = <Marker>[];
    final lines = <Polyline<String>>[];
    for (final asset in assets) {
      final geometry = _geometry(asset);
      if (geometry == null) continue;
      final uuid = '${asset['IgaUUID']}';
      final color = asset['pending'] == true ? const Color(0xFFF59E0B) : const Color(0xFF22C55E);
      switch (geometry['type']) {
        case 'Point':
          final position = _latLng(geometry['coordinates']);
          if (position == null) continue;
          points.add(Marker(
            point: position,
            width: 18,
            height: 18,
            child: GestureDetector(
              onTap: () => widget.onOpen(uuid),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF071111), width: 2),
                ),
              ),
            ),
          ));
        case 'LineString':
          lines.add(_line(geometry['coordinates'], uuid));
        case 'MultiLineString' || 'Polygon':
          for (final part in geometry['coordinates'] as List? ?? const []) {
            lines.add(_line(part, uuid));
          }
        case 'MultiPolygon':
          for (final polygon in geometry['coordinates'] as List? ?? const []) {
            for (final ring in polygon as List? ?? const []) {
              lines.add(_line(ring, uuid));
            }
          }
      }
    }
    final style = _style;
    final latitude = double.tryParse('${config['centerLatitude'] ?? ''}') ?? -14.235;
    final longitude = double.tryParse('${config['centerLongitude'] ?? ''}') ?? -51.9253;
    final zoom = double.tryParse('${config['zoom'] ?? ''}') ?? 3.5;
    final first = points.firstOrNull?.point;
    final attribution = [
      ...?style?.attributions.map((item) => item.text),
      if ('${config['attribution'] ?? ''}'.isNotEmpty) '${config['attribution']}',
    ].join(' · ');
    return FlutterMap(
      options: MapOptions(
        initialCenter: first ?? LatLng(latitude, longitude),
        initialZoom: first == null ? zoom : 15,
        maxZoom: 21,
        backgroundColor: const Color(0xFFEEF1F4),
      ),
      children: [
        if (style != null)
          vt.VectorTileLayer(
            theme: style.theme,
            tileProviders: style.providers,
            rasterSources: style.rasterSources,
            sprites: style.sprites,
          ),
        PolylineLayer<String>(polylines: lines, hitNotifier: _hits),
        MarkerLayer(markers: points),
        if (_me case final me?)
          MarkerLayer(markers: [
            Marker(
              point: me,
              width: 16,
              height: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ]),
        if (attribution.isNotEmpty) SimpleAttributionWidget(source: Text(attribution)),
      ],
    );
  }

  Polyline<String> _line(Object? coordinates, String uuid) => Polyline<String>(
        points: [
          for (final point in coordinates as List? ?? const []) ?_latLng(point),
        ],
        color: const Color(0xFF21D4D4),
        strokeWidth: 3,
        hitValue: uuid,
      );
}

LatLng? _latLng(Object? coordinates) {
  if (coordinates is! List || coordinates.length < 2) return null;
  final longitude = coordinates[0];
  final latitude = coordinates[1];
  if (longitude is! num || latitude is! num) return null;
  return LatLng(latitude.toDouble(), longitude.toDouble());
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
