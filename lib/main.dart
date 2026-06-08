import 'package:flutter/material.dart';

void main() {
  runApp(const MnsCloudInfraGisMobileApp());
}

class MnsCloudInfraGisMobileApp extends StatelessWidget {
  const MnsCloudInfraGisMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MNSCloud InfraGIS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF21D4D4)),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text('MNSCloud InfraGIS Mobile'),
        ),
      ),
    );
  }
}
