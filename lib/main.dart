import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/brand/brand.dart';
import 'src/field_controller.dart';
import 'src/ui/account_screen.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/lock_screen.dart';
import 'src/ui/login_screen.dart';
import 'src/version/app_update_overlay.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = FieldController();
  // After some time in the background the encrypted copy closes and the PIN is asked again.
  AppLifecycleListener(onHide: controller.backgrounded, onShow: controller.foregrounded);
  runApp(MnsCloudInfraGisMobileApp(controller: controller));
  controller.restore();
  controller.loadBrand();
}

/// MNSCloud InfraGIS field client: platform login, offline copy of the tenant and sync.
class MnsCloudInfraGisMobileApp extends StatelessWidget {
  const MnsCloudInfraGisMobileApp({super.key, required this.controller});

  final FieldController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale?>(
      valueListenable: controller.locale,
      builder: (context, locale, _) => ValueListenableBuilder<Brand?>(
        valueListenable: controller.brand,
        builder: (context, brand, _) => _app(brand, locale),
      ),
    );
  }

  /// Brand color and light/dark appearance come from Settings › Themes (InfraGIS), like the other
  /// MNSCloud clients; without a theme the MNSCloud InfraGIS color and the system appearance apply.
  Widget _app(Brand? brand, Locale? locale) {
    final seed = brand?.primaryColor ?? const Color(0xFF21D4D4);
    return MaterialApp(
      title: brand?.title ?? 'MNSCloud InfraGIS',
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('pt', 'BR'), Locale('en', 'US'), Locale('es', 'ES')],
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.dark),
      themeMode: switch (brand?.login['appearance']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      // Web: a newer release shows a notice; "Update now" activates the new PWA revision.
      // Installed apps: a critical notice when the client policy or the API no longer accepts them.
      builder: (context, child) => AppUpdateOverlay(
        busy: () => controller.syncing,
        listenable: controller,
        apiBase: controller.apiBase,
        child: child ?? const SizedBox.shrink(),
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.locked
            ? LockScreen(controller: controller)
            : controller.needsAccount
                ? AccountScreen(controller: controller)
                : !controller.signedIn
                ? LoginScreen(controller: controller)
                : controller.needsPin
                    ? PinSetupScreen(controller: controller)
                    : HomeScreen(controller: controller),
      ),
    );
  }
}
