import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sidemesh_mobile/main.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders app shell', (tester) async {
    final controller = await ThemeController.load();
    await tester.pumpWidget(SidemeshApp(themeController: controller));
    await tester.pump();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('Recent'), findsWidgets);
    expect(find.text('Inbox'), findsWidgets);
    expect(find.text('Hosts'), findsWidgets);
  });
}
