import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_infragis_mobile/main.dart';
import 'package:mnscloud_infragis_mobile/src/field_controller.dart';

void main() {
  testWidgets('renders the platform login', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(MnsCloudInfraGisMobileApp(controller: FieldController()));
    await tester.pumpAndSettle();

    expect(find.text('MNSCloud InfraGIS'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(3));
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('refuses a non-https API address', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(MnsCloudInfraGisMobileApp(controller: FieldController()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'http://example.com/api/v1');
    await tester.enterText(find.byType(TextFormField).at(1), 'tech@example.com');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('https://'), findsWidgets);
  });
}
