import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/terminal_key_models.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/terminal_keybar.dart';

void main() {
  testWidgets('renders category chips, modifier chips, and keys', (
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

    // Default categories should appear.
    expect(find.text('Nav'), findsOneWidget);
    expect(find.text('Ctrl'), findsWidgets);
    expect(find.text('Alt'), findsOneWidget);
    expect(find.text('Shift'), findsOneWidget);

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
}
