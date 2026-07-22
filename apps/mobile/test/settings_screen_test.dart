import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/app_version_store.dart';
import 'package:sidemesh_mobile/src/create_session_defaults_store.dart';
import 'package:sidemesh_mobile/src/screen_awake_settings_store.dart';
import 'package:sidemesh_mobile/src/screens/settings_screen.dart';
import 'package:sidemesh_mobile/src/session_policy_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';
import 'package:sidemesh_mobile/src/widgets/appearance_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppVersionStore.instance.resetForTest();
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
      expect(find.text('Appearance & device'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Keep screen awake while agent runs'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('New session defaults'), findsOneWidget);
      expect(find.text('Local data'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
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
      expect(find.text('Appearance & device'), findsOneWidget);
      expect(find.text('Replay onboarding'), findsNothing);

      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, 'Edit'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Edit'));
      await tester.pumpAndSettle();

      expect(find.byType(DropdownButton<ApprovalPolicy>), findsOneWidget);
      expect(find.byType(DropdownButton<SandboxMode>), findsOneWidget);
      expect(find.text('Used when you start a new session.'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'opens appearance sheet on narrow mobile width without overflow',
    (tester) async {
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
        expect(find.text('Changes the app look only.'), findsOneWidget);
        expect(find.text('Color mode'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('opens compact session defaults and enables save after changes', (
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
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('New session defaults'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Fast mode'), findsOneWidget);
      expect(find.text('Approval policy'), findsOneWidget);
      expect(find.text('File access'), findsOneWidget);
      expect(find.text('Web search'), findsOneWidget);
      expect(find.text('Used every time you open New session.'), findsNothing);
      expect(find.text('Starting point'), findsNothing);
      final save = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Save'),
      );
      expect(save.onPressed, isNull);

      await tester.tap(find.text('Approval policy'));
      await tester.pumpAndSettle();
      expect(find.text('Ask when untrusted'), findsOneWidget);
      await tester.tap(find.text('Ask when untrusted'));
      await tester.pumpAndSettle();
      final changedSave = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Save'),
      );
      expect(changedSave.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
