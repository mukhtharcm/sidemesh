import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  testWidgets('host editor groups setup into clear sections on mobile', (
    tester,
  ) async {
    try {
      await _pumpHostEditor(tester);

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
      _resetHostEditorTestView(tester);
    }
  });

  testWidgets('host editor keeps actions visible on a small phone', (
    tester,
  ) async {
    try {
      await _pumpHostEditor(tester, size: const Size(320, 568));

      expect(find.text('Add host'), findsOneWidget);
      expect(find.text('Save host'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      _resetHostEditorTestView(tester);
    }
  });

  testWidgets('host editor stays above the keyboard in edit mode', (
    tester,
  ) async {
    const keyboardInset = 260.0;
    try {
      await _pumpHostEditor(
        tester,
        size: const Size(320, 568),
        keyboardInset: keyboardInset,
        initialHost: HostProfile(
          id: 'mac',
          label: 'Kitchen MacBook',
          baseUrl: 'http://kitchen-macbook.tailnet.ts.net:8787',
          token: 'test-token',
          enabled: false,
        ),
      );

      expect(find.text('Edit host'), findsOneWidget);
      expect(find.text('Availability'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      expect(find.byTooltip('Show token'), findsOneWidget);

      final saveRect = tester.getRect(find.text('Save changes'));
      expect(saveRect.bottom, lessThanOrEqualTo(568 - keyboardInset + 1));
      expect(tester.takeException(), isNull);
    } finally {
      _resetHostEditorTestView(tester);
    }
  });
}

Future<void> _pumpHostEditor(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double keyboardInset = 0,
  HostProfile? initialHost,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size
    ..viewInsets = FakeViewPadding(bottom: keyboardInset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(ThemeVariant.codexAmber.light),
      home: Scaffold(body: HostEditorSheet(initialHost: initialHost)),
    ),
  );
  await tester.pumpAndSettle();
}

void _resetHostEditorTestView(WidgetTester tester) {
  debugDefaultTargetPlatformOverride = null;
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  tester.view.resetViewInsets();
}
