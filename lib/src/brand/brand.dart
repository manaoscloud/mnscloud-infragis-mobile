import 'package:flutter/material.dart';

/// Brand of the host for InfraGIS (Settings › Themes › InfraGIS tab of the tenant domain); every
/// field the InfraGIS tab leaves empty comes from the App brand. Null fields keep the MNSCloud defaults.
class Brand {
  const Brand({this.title, this.logoUrl, this.faviconUrl, this.primaryColor, this.login = const {}});

  final String? title;
  final String? logoUrl;
  final String? faviconUrl;
  final Color? primaryColor;

  /// `LoginAppearance` of the InfraGIS login (Settings › Themes › Login do InfraGIS): layout,
  /// appearance, panel image, support/privacy/terms links and PT/EN/ES copy. Empty keeps the defaults.
  final Map<String, dynamic> login;

  /// Copy configured for [locale] (`pt-BR`, `en-US`, `es-ES`); null keeps the built-in text.
  String? loginText(String locale, String key) {
    final texts = login['texts'];
    final value = texts is Map && texts[locale] is Map ? texts[locale][key] : null;
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  /// Links of the login are https only, never with credentials.
  static String? safeLink(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty ? value : null;
  }

  /// `data` of `GET /public/theme/context?app=infragis`: `{ context: {...} | null }`.
  static Brand? fromContext(dynamic data) {
    final context = data is Map ? data['context'] : null;
    if (context is! Map) return null;
    String? text(Object? value) {
      final result = value?.toString().trim();
      return result == null || result.isEmpty ? null : result;
    }

    return Brand(
      title: text(context['PageTitle']),
      login: context['LoginAppearance'] is Map ? Map<String, dynamic>.from(context['LoginAppearance']) : const {},
      logoUrl: safeImageUrl(text(context['LogoUrl'])),
      faviconUrl: safeImageUrl(text(context['FaviconUrl'])),
      primaryColor: parseHexColor(text(context['PrimaryColor'])),
    );
  }

  /// Only images uploaded to the theme (same origin) or https addresses are shown.
  static String? safeImageUrl(String? url) {
    if (url == null) return null;
    if (RegExp(r'^/api/v1/public/theme/assets/[0-9a-f]{32}$').hasMatch(url)) {
      return url;
    }
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? url
        : null;
  }

  static Color? parseHexColor(String? value) {
    final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value ?? '');
    return match == null
        ? null
        : Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
  }
}
