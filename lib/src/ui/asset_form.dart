import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../core/ids.dart';
import '../data/local_store.dart';
import '../field_controller.dart';
import 'strings.dart';

/// Current GPS position, or null when the device has no fix or the user refused the permission.
Future<Position?> currentPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
    );
  } catch (_) {
    return null;
  }
}

String? _same(Iterable<Map<String, dynamic>> rows, String key, Object? value) {
  if (value == null) return null;
  final wanted = normalizeUuid('$value');
  for (final row in rows) {
    if (normalizeUuid('${row[key]}') == wanted) return '${row[key]}';
  }
  return null;
}

Map<String, dynamic> _object(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Shown as no properties.
    }
  }
  return {};
}

/// Point asset form of the field app: catalogs from the offline copy, GPS position, properties of
/// the asset type and photos. Saving queues the write; the API validates it on the next sync.
class AssetFormScreen extends StatefulWidget {
  const AssetFormScreen({super.key, required this.controller, this.assetUuid, this.latitude, this.longitude});

  final FieldController controller;
  final String? assetUuid;
  final double? latitude;
  final double? longitude;

  @override
  State<AssetFormScreen> createState() => _AssetFormScreenState();
}

class _AssetFormScreenState extends State<AssetFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _externalId = TextEditingController();
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  final Map<String, TextEditingController> _text = {};
  final Map<String, bool> _flags = {};
  String? _project;
  String? _layer;
  String? _type;
  String? _status;
  bool _locating = false;

  LocalStore get _store => widget.controller.store!;

  /// Lines and polygons keep their geometry: the field app edits only their data.
  bool get _point {
    final type = '${_asset?['IgmGeometryType'] ?? ''}'.toUpperCase();
    return type.isEmpty || type == 'NULL' || type == 'POINT';
  }
  Map<String, dynamic>? get _asset => widget.assetUuid == null ? null : _store.asset(widget.assetUuid!);

  @override
  void initState() {
    super.initState();
    final asset = _asset;
    if (asset != null) {
      _name.text = '${asset['IgaName'] ?? ''}';
      _externalId.text = '${asset['IgaExternalID'] ?? ''}';
      _latitude.text = '${asset['IgmLatitude'] ?? ''}';
      _longitude.text = '${asset['IgmLongitude'] ?? ''}';
      _project = _same(_store.catalog('projects'), 'IprUUID', asset['InfraGisProjectIprUUID']);
      _layer = _same(_store.catalog('layers'), 'IglUUID', asset['InfraGisLayerIglUUID']);
      _type = _same(_store.catalog('asset-types'), 'IgtUUID', asset['InfraGisAssetTypeIgtUUID']);
      _status = _same(_store.catalog('statuses'), 'IgsUUID', asset['InfraGisAssetStatusIgsUUID']);
      for (final entry in _object(asset['IgaPropertiesJson']).entries) {
        if (entry.value is bool) {
          _flags[entry.key] = entry.value as bool;
        } else {
          _text[entry.key] = TextEditingController(text: '${entry.value ?? ''}');
        }
      }
    } else {
      if (widget.latitude != null) _latitude.text = widget.latitude!.toStringAsFixed(7);
      if (widget.longitude != null) _longitude.text = widget.longitude!.toStringAsFixed(7);
      final projects = _store.catalog('projects');
      if (projects.length == 1) _project = '${projects.first['IprUUID']}';
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _externalId, _latitude, _longitude, ..._text.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Layers of the project that accept points.
  List<Map<String, dynamic>> get _layers => _store
      .catalog('layers')
      .where((layer) =>
          _project != null &&
          normalizeUuid('${layer['InfraGisProjectIprUUID']}') == normalizeUuid(_project!) &&
          ['POINT', 'MIXED'].contains('${layer['IglGeometryType']}'.toUpperCase()))
      .toList();

  /// Properties declared by the asset type schema: name → JSON type (string, number, boolean).
  Map<String, String> get _schema {
    final type = _store.catalog('asset-types').where((row) => '${row['IgtUUID']}' == _type).firstOrNull;
    final properties = _object(_object(type?['IgtPropertiesSchemaJson'])['properties']);
    return {
      for (final entry in properties.entries) entry.key: '${_object(entry.value)['type'] ?? 'string'}',
    };
  }

  Future<void> _gps() async {
    setState(() => _locating = true);
    final position = await currentPosition();
    if (!mounted) return;
    setState(() => _locating = false);
    if (position == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'gpsUnavailable'))));
      return;
    }
    _latitude.text = position.latitude.toStringAsFixed(7);
    _longitude.text = position.longitude.toStringAsFixed(7);
  }

  Map<String, dynamic> _properties() {
    final schema = _schema;
    final values = <String, dynamic>{};
    for (final key in {...schema.keys, ..._text.keys, ..._flags.keys}) {
      final kind = schema[key] ?? (_flags.containsKey(key) ? 'boolean' : 'string');
      if (kind == 'boolean') {
        if (_flags.containsKey(key)) values[key] = _flags[key];
        continue;
      }
      final text = _text[key]?.text.trim() ?? '';
      if (text.isEmpty) continue;
      values[key] = kind == 'number' ? (num.tryParse(text.replaceAll(',', '.')) ?? text) : text;
    }
    return values;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final point = _point;
    final latitude = point ? double.parse(_latitude.text.replaceAll(',', '.')) : null;
    final longitude = point ? double.parse(_longitude.text.replaceAll(',', '.')) : null;
    final properties = _properties();
    final data = <String, dynamic>{
      'projectUUID': _project,
      'layerUUID': _layer,
      'assetTypeUUID': _type ?? '',
      'assetStatusUUID': _status ?? '',
      'name': _name.text.trim(),
      'externalID': _externalId.text.trim(),
      'propertiesJson': properties.isEmpty ? '' : properties,
      if (point) 'geometryType': 'POINT',
      if (point) 'latitude': latitude,
      if (point) 'longitude': longitude,
    };
    final local = <String, dynamic>{
      'IgaName': _name.text.trim().toUpperCase(),
      'IgaExternalID': _externalId.text.trim(),
      'InfraGisProjectIprUUID': _project,
      'InfraGisLayerIglUUID': _layer,
      'InfraGisAssetTypeIgtUUID': _type,
      'InfraGisAssetStatusIgsUUID': _status,
      'IgaPropertiesJson': jsonEncode(properties),
      if (point) 'IgmGeometryType': 'POINT',
      if (point) 'IgmLatitude': latitude,
      if (point) 'IgmLongitude': longitude,
    };
    widget.controller.saveAsset(assetUuid: widget.assetUuid, data: data, localItem: local);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'savedOffline'))));
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'deleteConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'delete'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.controller.deleteAsset(widget.assetUuid!);
    Navigator.of(context).pop();
  }

  Future<void> _photo() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 80, maxWidth: 2560);
    if (picked == null || !mounted) return;
    final position = await currentPosition();
    final directory = await widget.controller.photoDirectory();
    final path = '$directory/${newUuid()}.jpg';
    await File(picked.path).copy(path);
    widget.controller.queuePhoto(
      assetUuid: widget.assetUuid!,
      path: path,
      latitude: position?.latitude,
      longitude: position?.longitude,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'photoQueued'))));
    }
  }

  DropdownButtonFormField<String> _select(
    String label,
    String? value,
    List<Map<String, dynamic>> rows,
    String uuidKey,
    String nameKey,
    ValueChanged<String?> onChanged, {
    bool required = false,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: rows.any((row) => '${row[uuidKey]}' == value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          if (!required) const DropdownMenuItem<String>(value: null, child: Text('—')),
          for (final row in rows)
            DropdownMenuItem<String>(value: '${row[uuidKey]}', child: Text('${row[nameKey] ?? ''}')),
        ],
        onChanged: (selected) => setState(() => onChanged(selected)),
        validator: required ? (selected) => selected == null ? tr(context, 'required') : null : null,
      );

  @override
  Widget build(BuildContext context) {
    final editing = widget.assetUuid != null;
    String? number(String? value, double min, double max) {
      final parsed = double.tryParse((value ?? '').trim().replaceAll(',', '.'));
      return parsed == null || parsed < min || parsed > max ? '$min … $max' : null;
    }

    final schema = _schema;
    final propertyKeys = {...schema.keys, ..._text.keys, ..._flags.keys}.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, editing ? 'editAsset' : 'newAsset')),
        actions: [
          if (editing) IconButton(icon: const Icon(Icons.photo_camera_outlined), tooltip: tr(context, 'takePhoto'), onPressed: _photo),
          if (editing) IconButton(icon: const Icon(Icons.delete_outline), tooltip: tr(context, 'delete'), onPressed: _delete),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: InputDecoration(labelText: tr(context, 'name')),
              validator: (value) => value == null || value.trim().isEmpty ? tr(context, 'required') : null,
            ),
            const SizedBox(height: 12),
            _select(tr(context, 'project'), _project, _store.catalog('projects'), 'IprUUID', 'IprName', (value) {
              _project = value;
              _layer = null;
            }, required: true),
            const SizedBox(height: 12),
            _select(tr(context, 'layer'), _layer, _layers, 'IglUUID', 'IglName', (value) => _layer = value, required: true),
            const SizedBox(height: 12),
            _select(tr(context, 'type'), _type, _store.catalog('asset-types'), 'IgtUUID', 'IgtName', (value) => _type = value),
            const SizedBox(height: 12),
            _select(tr(context, 'status'), _status, _store.catalog('statuses'), 'IgsUUID', 'IgsName', (value) => _status = value),
            const SizedBox(height: 12),
            TextFormField(controller: _externalId, decoration: InputDecoration(labelText: tr(context, 'externalId'))),
            const SizedBox(height: 12),
            if (_point) Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _latitude,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: InputDecoration(labelText: tr(context, 'latitude')),
                    validator: (value) => number(value, -90, 90),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _longitude,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: InputDecoration(labelText: tr(context, 'longitude')),
                    validator: (value) => number(value, -180, 180),
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'useGps'),
                  onPressed: _locating ? null : _gps,
                  icon: _locating
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.my_location),
                ),
              ],
            ),
            if (propertyKeys.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(tr(context, 'properties'), style: Theme.of(context).textTheme.titleMedium),
              for (final key in propertyKeys)
                if ((schema[key] ?? (_flags.containsKey(key) ? 'boolean' : 'string')) == 'boolean')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(key),
                    value: _flags[key] ?? false,
                    onChanged: (value) => setState(() => _flags[key] = value),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextFormField(
                      controller: _text.putIfAbsent(key, TextEditingController.new),
                      keyboardType: schema[key] == 'number'
                          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                          : TextInputType.text,
                      decoration: InputDecoration(labelText: key),
                    ),
                  ),
            ],
            const SizedBox(height: 12),
            Text(tr(context, 'onlyPoints'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined), label: Text(tr(context, 'save'))),
          ],
        ),
      ),
    );
  }
}
