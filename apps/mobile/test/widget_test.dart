import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sidemesh_mobile/main.dart';
import 'package:sidemesh_mobile/src/app_version_store.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';
import 'package:sidemesh_mobile/src/windowing.dart';

import 'test_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await configureTestDatabaseFactory();
  });

  setUp(() {
    SessionLocalStore.instance.resetMigrationState();
    AppVersionStore.instance.resetForTest();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await SidemeshDb.close();
  });

  testWidgets('renders app shell', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1280, 2200);
    final controller = await ThemeController.load();
    await tester.pumpWidget(
      SidemeshApp(
        themeController: controller,
        onboardingCompleted: true,
        launchState: const SidemeshWindowLaunchState(
          arguments: SidemeshWindowArguments.mainWindow(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('Recent'), findsWidgets);
    expect(find.text('Actions'), findsWidgets);
    expect(find.text('Hosts'), findsWidgets);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
