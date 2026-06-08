import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_infragis_mobile/main.dart';

void main() {
  testWidgets('renders login shell', (tester) async {
    await tester.pumpWidget(const MnsCloudInfraGisMobileApp());

    expect(find.text('MNSCloud InfraGIS'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(3));
    expect(find.text('Sign in'), findsOneWidget);
  });
}
