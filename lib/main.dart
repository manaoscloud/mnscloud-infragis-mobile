import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/field_controller.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/login_screen.dart';
import 'src/version/app_update_overlay.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = FieldController();
  runApp(MnsCloudInfraGisMobileApp(controller: controller));
  controller.restore();
}

/// MNSCloud InfraGIS field client: platform login, offline copy of the tenant and sync.
class MnsCloudInfraGisMobileApp extends StatelessWidget {
  const MnsCloudInfraGisMobileApp({super.key, required this.controller});

  final FieldController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MNSCloud InfraGIS',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('pt', 'BR'), Locale('en'), Locale('es')],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF21D4D4), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF071111),
        useMaterial3: true,
      ),
      // Web only: a newer release shows a notice; "Update now" activates the new PWA revision.
      builder: (context, child) => AppUpdateOverlay(
        busy: () => controller.syncing,
        listenable: controller,
        child: child ?? const SizedBox.shrink(),
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) =>
            controller.signedIn ? HomeScreen(controller: controller) : LoginScreen(controller: controller),
      ),
    );
  }
}
