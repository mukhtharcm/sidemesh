import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/app_tokens.dart';
import 'package:sidemesh_mobile/src/widgets/desktop_sidebar_search_field.dart';

void main() {
  testWidgets('keeps the focused sidebar search compact and aligned', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
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
    final surface = tester.widget<Container>(
      find.descendant(of: field, matching: find.byType(Container)).first,
    );
    final decoration = surface.decoration! as BoxDecoration;
    final border = decoration.border! as Border;

    expect(tester.getSize(field).height, AppSizes.compactControl);
    expect(border.top.width, 1);
    expect(textField.textAlignVertical, TextAlignVertical.center);
    expect(textField.cursorHeight, 16);
    expect(textField.decoration?.contentPadding, EdgeInsets.zero);
    expect(
      (tester.getCenter(icon).dy - tester.getCenter(editable).dy).abs(),
      lessThanOrEqualTo(1),
    );
    expect(
      (tester.getCenter(hint).dy - tester.getCenter(icon).dy).abs(),
      lessThanOrEqualTo(1),
    );
    expect(tester.getTopLeft(hint).dx, tester.getTopLeft(editable).dx);
  });
}
