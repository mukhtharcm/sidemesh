import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  testWidgets('host editor groups setup into clear sections on mobile', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 844);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(ThemeVariant.codexAmber.light),
          home: const Scaffold(body: HostEditorSheet()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Add host'), findsOneWidget);
      expect(find.text('Pairing'), findsOneWidget);
      expect(find.text('About this machine'), findsOneWidget);
      expect(find.text('Connection'), findsOneWidget);
      expect(find.text('Availability'), findsOneWidget);
      expect(find.text('Scan code'), findsOneWidget);
      expect(find.text('Check connection'), findsOneWidget);
      expect(find.text('Save host'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
