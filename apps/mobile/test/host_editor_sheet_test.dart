import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('desktop machine editor fits its content: $dark', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(1180, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme(
              ThemeVariant.nord.light,
              platform: TargetPlatform.macOS,
            ),
            darkTheme: buildDarkTheme(
              ThemeVariant.nord.dark,
              platform: TargetPlatform.macOS,
            ),
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            home: const HostEditorSheet(
              initialHost: HostProfile(
                id: 'test',
                label: 'Test machine',
                baseUrl: 'http://localhost:4001',
                token: 'test',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final surface = find
            .ancestor(
              of: find.text('Edit machine'),
              matching: find.byType(Material),
            )
            .first;
        expect(tester.getSize(surface).height, lessThan(600));
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          tester.widget<TextField>(find.byType(TextField).last).obscureText,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('host editor presents one focused setup page on mobile', (
    tester,
  ) async {
    try {
      await _pumpHostEditor(tester);

      expect(find.text('Add machine'), findsOneWidget);
      expect(find.text('Pairing'), findsNothing);
      expect(find.text('About this machine'), findsNothing);
      expect(find.text('Connection'), findsNothing);
      expect(find.text('Availability'), findsNothing);
      expect(find.text('Scan'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Address'), findsOneWidget);
      expect(find.text('Token'), findsOneWidget);
      expect(find.text('Check connection'), findsOneWidget);
      expect(find.text('Save machine'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
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

      expect(find.text('Add machine'), findsOneWidget);
      expect(find.text('Save machine'), findsOneWidget);
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

      expect(find.text('Edit machine'), findsOneWidget);
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
      home: HostEditorSheet(initialHost: initialHost, fullPage: true),
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
