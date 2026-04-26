import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/create_session_defaults_store.dart';
import 'package:sidemesh_mobile/src/screens/settings_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CreateSessionDefaultsStore.instance.resetForTest();
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
}
