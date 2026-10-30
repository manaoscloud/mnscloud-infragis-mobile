import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../brand/brand.dart';
import '../field_controller.dart';
import '../pwa/install_app_button.dart';
import 'strings.dart';

const _defaultBrandColor = Color(0xFF1264ED);

/// Login copy: the text of Settings › Themes › Login do InfraGIS for the screen language, else the
/// built-in translation. Same access screen as POS, Pulse and PhoneWeb.
String accessText(BuildContext context, Brand? brand, String key) {
  final configured = brand?.loginText(themeLocale(context), key);
  return configured ?? tr(context, 'access${key[0].toUpperCase()}${key.substring(1)}');
}

/// Opens a Themes link in a new tab (web) or the system browser (installed apps).
Future<void> openAccessLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final error = tr(context, 'linkError');
  try {
    final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
    if (!opened) messenger?.showSnackBar(SnackBar(content: Text(error)));
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(error)));
  }
}

/// Language of the access screens, kept in memory by the controller.
class AccessLanguageButton extends StatelessWidget {
  const AccessLanguageButton({super.key, required this.controller});
  final FieldController controller;

  static const _names = {'pt': 'Português (BR)', 'en': 'English (US)', 'es': 'Español (ES)'};
  static const _locales = {'pt': Locale('pt', 'BR'), 'en': Locale('en', 'US'), 'es': Locale('es', 'ES')};

  @override
  Widget build(BuildContext context) {
    final language = Localizations.maybeLocaleOf(context)?.languageCode ?? 'pt';
    return PopupMenuButton<String>(
      key: const Key('accessLanguage'),
      tooltip: tr(context, 'language'),
      initialValue: controller.locale.value?.languageCode ?? 'auto',
      onSelected: (value) => controller.locale.value = _locales[value],
      itemBuilder: (_) => [
        PopupMenuItem(value: 'auto', child: Text(tr(context, 'systemLanguage'))),
        for (final entry in _names.entries) PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 19),
            const SizedBox(width: 8),
            Text(_names[language] ?? _names['pt']!),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Logo (or the MNSCloud mark on the brand color) and the InfraGIS title of the domain.
class AccessBrand extends StatelessWidget {
  const AccessBrand({super.key, required this.brand, this.onDark = false});
  final Brand? brand;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final color = brand?.primaryColor ?? _defaultBrandColor;
    final mark = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: Text(
        'M',
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w900,
          color: color.computeLuminance() > .179 ? Colors.black : Colors.white,
        ),
      ),
    );
    final logo = brand?.logoUrl;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (logo != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120, maxHeight: 48),
            child: Image.network(
              logo,
              key: const Key('brandLogo'),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => mark,
            ),
          )
        else
          mark,
        const SizedBox(width: 14),
        Flexible(
          child: Text(
            brand?.title ?? 'MNSCloud InfraGIS',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: onDark ? Colors.white : null),
          ),
        ),
      ],
    );
  }
}

/// Sign-in screen: brand panel beside the form on wide screens (unless
/// Themes asks for the compact layout), the form alone with the brand on top on phones.
class AccessShell extends StatelessWidget {
  const AccessShell({super.key, required this.controller, required this.child, this.onSignOut});
  final FieldController controller;
  final Widget child;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final brand = controller.brand.value;
    final color = brand?.primaryColor ?? _defaultBrandColor;
    final theme = Theme.of(context);
    // Fields and the main button look the same as in Pulse and PhoneWeb.
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: color.computeLuminance() > .179 ? Colors.black : Colors.white,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final split = constraints.maxWidth >= 900 && brand?.login['layout'] != 'compact';
          final main = SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: EdgeInsets.all(split ? 40 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Same toolbar as Pulse: brand (phones only), language, sign-out.
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        if (!split)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 270),
                            child: AccessBrand(brand: brand),
                          ),
                        AccessLanguageButton(controller: controller),
                        const InstallAppButton(labeled: true),
                        if (onSignOut != null)
                          IconButton(
                            key: const Key('signOut'),
                            tooltip: tr(context, 'signOut'),
                            onPressed: onSignOut,
                            icon: const Icon(Icons.logout),
                          ),
                      ],
                    ),
                    SizedBox(height: split ? 76 : 48),
                    Center(
                      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: child),
                    ),
                    const SizedBox(height: 36),
                    _footer(context, brand),
                  ],
                ),
              ),
            ),
          );
          if (!split) return main;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [const Color(0xFF071A37), Color.lerp(const Color(0xFF06142B), color, .35)!],
                    ),
                  ),
                  child: Stack(
                    children: [
                      if (Brand.safeLink(brand?.login['heroImageUrl']) case final String image)
                        Positioned.fill(
                          child: Opacity(
                            opacity: .16,
                            child: Image.network(
                              image,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      const Positioned.fill(child: CustomPaint(painter: _Orbits())),
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(56),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AccessBrand(brand: brand, onDark: true),
                            const SizedBox(height: 110),
                            Text(
                              accessText(context, brand, 'eyebrow').toUpperCase(),
                              style: const TextStyle(color: Colors.white, fontSize: 12, letterSpacing: 2),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              accessText(context, brand, 'heroTitle'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 52,
                                fontWeight: FontWeight.w800,
                                height: 1.12,
                                letterSpacing: -2,
                              ),
                            ),
                            const SizedBox(height: 28),
                            Text(
                              accessText(context, brand, 'heroText'),
                              style: const TextStyle(color: Colors.white, fontSize: 19, height: 1.6),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: main),
            ],
          );
        },
      ),
    );
  }

  Widget _footer(BuildContext context, Brand? brand) {
    Widget? link(String key, String label) {
      final url = Brand.safeLink(brand?.login[key]);
      return url == null
          ? null
          : TextButton(
              onPressed: () => openAccessLink(context, url),
              child: Text(label, textAlign: TextAlign.center),
            );
    }

    return Column(
      children: [
        if (link('supportUrl', accessText(context, brand, 'supportLabel')) case final Widget support) support,
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          children: [
            if (link('privacyUrl', tr(context, 'privacy')) case final Widget privacy) privacy,
            if (link('termsUrl', tr(context, 'terms')) case final Widget terms) terms,
          ],
        ),
      ],
    );
  }
}

/// Heading of an access screen: section label, title and instructions.
class AccessHeading extends StatelessWidget {
  const AccessHeading({super.key, required this.eyebrow, required this.title, required this.subtitle});
  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: TextStyle(fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w700, color: scheme.primary),
        ),
        const SizedBox(height: 18),
        Text(title, style: const TextStyle(fontSize: 34, height: 1.15, fontWeight: FontWeight.w800, letterSpacing: -1)),
        const SizedBox(height: 12),
        Text(subtitle, style: TextStyle(fontSize: 16, height: 1.6, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 28),
      ],
    );
  }
}

class _Orbits extends CustomPainter {
  const _Orbits();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final scale in [1.0, 1.3, 1.6]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width * .2, size.height * 1.2),
          width: size.width * 1.7 * scale,
          height: size.height * .8 * scale,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
