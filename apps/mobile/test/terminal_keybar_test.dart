import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/terminal_key_models.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/terminal_keybar.dart';

void main() {
  testWidgets('renders modifier pills, category tabs, and keys', (
    tester,
  ) async {
    TerminalKeyAction? firedAction;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: Scaffold(
          body: TerminalKeyBar(
            onAction: (action) => firedAction = action,
          ),
        ),
      ),
    );

    // Modifier pills should appear on the left.
    expect(find.text('Ctrl'), findsWidgets);
    expect(find.text('Alt'), findsOneWidget);
    expect(find.text('Shift'), findsOneWidget);

    // Default category tab should appear.
    expect(find.text('Nav'), findsOneWidget);

    // Keys for the default Nav category should appear.
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);

    // Tapping a key should fire the callback.
    await tester.tap(find.text('Esc'));
    await tester.pump();
    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Esc');
    expect(firedAction!.key, isNotNull);
  });

  testWidgets('modifier is one-shot and auto-clears after key tap', (
    tester,
  ) async {
    TerminalKeyAction? firedAction;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: Scaffold(
          body: TerminalKeyBar(
            onAction: (action) => firedAction = action,
          ),
        ),
      ),
    );

    // Tap the Ctrl modifier pill (first occurrence on the left).
    await tester.tap(find.text('Ctrl').first);
    await tester.pumpAndSettle();

    // Tap a plain key in the default Nav category.
    await tester.tap(find.text('Tab'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Tab');
    expect(firedAction!.ctrl, true);

    // After the key was sent the modifier should have auto-cleared.
    // Tapping another key should NOT have Ctrl set.
    firedAction = null;
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Esc');
    expect(firedAction!.ctrl, false);
  });
}
