import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/recent_session_view_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/recent_session_controls_menu.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('trailing menu stays below its button on $platform', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(390, 840);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final store = RecentSessionViewStore.forTesting();
      await store.ensureLoaded();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(
            ThemeVariant.codexAmber.light,
            platform: platform,
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topRight,
                child: RecentSessionControlsMenu(store: store),
              ),
            ),
          ),
        ),
      );
      final trigger = tester.getRect(find.byType(IconButton));
      await tester.tap(find.byTooltip('Group sessions'));
      await tester.pumpAndSettle();
      final item = tester.getRect(
        find
            .ancestor(of: find.text('Project'), matching: find.byType(Material))
            .first,
      );
      expect(item.width, 212); // Menu width less its 4 px padding on each side.
      expect(item.right, closeTo(trigger.right, 8));
      expect(item.top, greaterThanOrEqualTo(trigger.bottom));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('menu exposes grouping and filters directly', (tester) async {
    final store = RecentSessionViewStore.forTesting();
    await store.ensureLoaded();
    final palette = ThemeVariant.codexAmber;
    var filters = const RecentSessionFilters();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(palette.light, platform: TargetPlatform.macOS),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: RecentSessionControlsMenu(
                store: store,
                filters: filters,
                onFavoritesOnlyChanged: (value) => setState(
                  () => filters = filters.copyWith(favoritesOnly: value),
                ),
                onRunningOnlyChanged: (value) => setState(
                  () => filters = filters.copyWith(runningOnly: value),
                ),
                onUnreadOnlyChanged: (value) => setState(
                  () => filters = filters.copyWith(unreadOnly: value),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('View and filter'));
    await tester.pumpAndSettle();

    expect(find.text('Group by'), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Single list'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Unread'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(MenuItemButton, 'Project')).height,
      32,
    );
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.tap(find.text('Single list'));
    await tester.pumpAndSettle();
    expect(store.grouping, RecentSessionGrouping.singleList);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();

    expect(filters.favoritesOnly, isTrue);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
    expect(find.text('Filter'), findsOneWidget);
    expect(find.byTooltip('View and filter, filters active'), findsOneWidget);
  });
}
