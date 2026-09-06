import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/app_control_styles.dart';
import 'package:sidemesh_mobile/src/theme/app_tokens.dart';
import 'package:sidemesh_mobile/src/widgets/desktop_sidebar_search_field.dart';

void main() {
  testWidgets('uses the shared search style and keeps text aligned', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(
          ThemeVariant.codexAmber.light,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: DesktopSidebarSearchField(
                controller: controller,
                focusNode: focusNode,
                onClear: controller.clear,
              ),
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final field = find.byType(DesktopSidebarSearchField);
    final icon = find.byIcon(Icons.search_rounded);
    final editable = find.byType(EditableText);
    final hint = find.text('Search (⌘F)');
    final textField = tester.widget<TextField>(find.byType(TextField));
    final shared = AppControlStyles.search(
      tester.element(find.byType(TextField)),
    );
    expect(textField.decoration?.focusedBorder, shared.focusedBorder);
    expect(textField.decoration?.fillColor, shared.fillColor);
    expect(tester.getSize(field).height, AppSizes.compactControl);
    expect(
      (tester.getCenter(icon).dy - tester.getCenter(editable).dy).abs(),
      lessThanOrEqualTo(1),
    );
    expect(
      (tester.getCenter(hint).dy - tester.getCenter(icon).dy).abs(),
      lessThanOrEqualTo(1),
    );
    expect(tester.getTopLeft(hint).dx, tester.getTopLeft(editable).dx);
    await tester.enterText(find.byType(TextField), 'test');
    await tester.pump();
    expect(tester.getSize(field).height, AppSizes.compactControl);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
