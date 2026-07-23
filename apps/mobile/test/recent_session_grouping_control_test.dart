import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/recent_session_view_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/app_tokens.dart';
import 'package:sidemesh_mobile/src/widgets/recent_session_controls_menu.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('menu exposes grouping and filters directly', (tester) async {
    final store = RecentSessionViewStore.forTesting();
    await store.ensureLoaded();
    final palette = ThemeVariant.codexAmber;
    var filters = const RecentSessionFilters();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(palette.light),
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
      AppSizes.menuItem,
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
