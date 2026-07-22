import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/recent_session_view_store.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('picker switches between project grouping and a single list', (
    tester,
  ) async {
    final store = RecentSessionViewStore.forTesting();
    await store.ensureLoaded();
    final palette = ThemeVariant.codexAmber;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(palette.light),
        home: Scaffold(body: RecentSessionGroupingControl(store: store)),
      ),
    );

    expect(find.text('By project'), findsOneWidget);

    await tester.tap(find.text('By project'));
    await tester.pumpAndSettle();

    final items = tester
        .widgetList<CheckedPopupMenuItem<RecentSessionGrouping>>(
          find.byType(CheckedPopupMenuItem<RecentSessionGrouping>),
        )
        .toList();
    expect(items, hasLength(2));
    expect(items[0].checked, isTrue);
    expect(items[1].checked, isFalse);

    await tester.tap(
      find.byType(CheckedPopupMenuItem<RecentSessionGrouping>).at(1),
    );
    await tester.pumpAndSettle();

    expect(store.grouping, RecentSessionGrouping.singleList);
    expect(find.text('Single list'), findsOneWidget);
  });
}
