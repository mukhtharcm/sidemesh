import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sidemesh_mobile/main.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';
import 'package:sidemesh_mobile/src/windowing.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('first-run onboarding fits a small phone viewport', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = await ThemeController.load();
    await tester.pumpWidget(
      SidemeshApp(
        themeController: controller,
        onboardingCompleted: false,
        launchState: const SidemeshWindowLaunchState(
          arguments: SidemeshWindowArguments.mainWindow(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Keep your coding agents\nwithin reach.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('onboarding pages can advance on a small phone viewport', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = await ThemeController.load();
    await tester.pumpWidget(
      SidemeshApp(
        themeController: controller,
        onboardingCompleted: false,
        launchState: const SidemeshWindowLaunchState(
          arguments: SidemeshWindowArguments.mainWindow(),
        ),
      ),
    );

    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(PageView), const Offset(-360, 0));
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(find.text('Set up your daemon'), findsOneWidget);
  });
}
