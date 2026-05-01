import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/create_session_defaults_store.dart';
import 'package:sidemesh_mobile/src/screen_awake_settings_store.dart';
import 'package:sidemesh_mobile/src/screens/settings_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';
import 'package:sidemesh_mobile/src/widgets/appearance_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CreateSessionDefaultsStore.instance.resetForTest();
    ScreenAwakeSettingsStore.instance.resetForTest();
  });

  testWidgets('renders core settings sections', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(900, 1800);
    try {
      await CreateSessionDefaultsStore.instance.ensureLoaded();
      final controller = await ThemeController.load();
      final palette = ThemeVariant.codexAmber;

      await tester.pumpWidget(
        ThemeScope(
          notifier: controller,
          child: MaterialApp(
            theme: buildLightTheme(
              palette.light,
              typography: controller.typography,
            ),
            darkTheme: buildDarkTheme(
              palette.dark,
              typography: controller.typography,
            ),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('App preferences'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Display'), findsOneWidget);
      expect(find.text('Keep screen awake while agent runs'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('New session defaults'), findsOneWidget);
      expect(find.text('Storage & recovery'), findsOneWidget);
      expect(find.text('About this build'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('opens desktop settings as an embedded dialog surface', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1440, 1024);
    try {
      await CreateSessionDefaultsStore.instance.ensureLoaded();
      final controller = await ThemeController.load();
      final palette = ThemeVariant.codexAmber;

      await tester.pumpWidget(
        ThemeScope(
          notifier: controller,
          child: MaterialApp(
            theme: buildLightTheme(
              palette.light,
              typography: controller.typography,
            ),
            darkTheme: buildDarkTheme(
              palette.dark,
              typography: controller.typography,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => openSettingsScreen(
                      context,
                      onResetSidebarWidth: () {},
                      onResetInspectorWidth: () {},
                    ),
                    child: const Text('Open settings'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('App preferences'), findsOneWidget);
      expect(find.text('Replay onboarding'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('opens appearance sheet on narrow mobile width without overflow', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 844);
    try {
      await CreateSessionDefaultsStore.instance.ensureLoaded();
      final controller = await ThemeController.load();
      final palette = ThemeVariant.codexAmber;

      await tester.pumpWidget(
        ThemeScope(
          notifier: controller,
          child: MaterialApp(
            theme: buildLightTheme(
              palette.light,
              typography: controller.typography,
            ),
            darkTheme: buildDarkTheme(
              palette.dark,
              typography: controller.typography,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showAppearanceSheet(context),
                    child: const Text('Open appearance'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open appearance'));
      await tester.pumpAndSettle();

      expect(find.text('Appearance'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
