import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sidemesh_mobile/main.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';
import 'package:sidemesh_mobile/src/windowing.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => '/tmp/sidemesh_test';
  @override
  Future<String?> getApplicationSupportPath() async => '/tmp/sidemesh_test';
  @override
  Future<String?> getTemporaryPath() async => '/tmp/sidemesh_test';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  PathProviderPlatform.instance = _FakePathProvider();

  setUp(() {
    SessionLocalStore.instance.resetMigrationState();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await SidemeshDb.close();
  });

  testWidgets('renders app shell', (tester) async {
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
    expect(find.text('Inbox'), findsWidgets);
    expect(find.text('Hosts'), findsWidgets);
  });
}
