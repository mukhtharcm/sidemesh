import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/terminal_key_models.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/terminal_keybar.dart';

void main() {
  testWidgets('renders explicit shortcut row and more button', (tester) async {
    TerminalKeyAction? firedAction;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: Scaffold(
          body: TerminalKeyBar(onAction: (action) => firedAction = action),
        ),
      ),
    );

    expect(find.text('Ctrl+C'), findsOneWidget);
    expect(find.text('Ctrl+D'), findsOneWidget);
    expect(find.text('Ctrl+Z'), findsOneWidget);
    expect(find.text('Ctrl+L'), findsOneWidget);
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Tab'), findsOneWidget);
    expect(find.text('←'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
    expect(find.text('↓'), findsOneWidget);
    expect(find.text('→'), findsOneWidget);

    await tester.tap(find.text('Ctrl+C'));
    await tester.pump();
    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Ctrl+C');
    expect(firedAction!.ctrl, true);

    await tester.scrollUntilVisible(find.text('More'), 120);
    expect(find.text('More'), findsOneWidget);
  });

  testWidgets('plain keys and ctrl shortcuts fire without modifier state', (
    tester,
  ) async {
    TerminalKeyAction? firedAction;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: Scaffold(
          body: TerminalKeyBar(onAction: (action) => firedAction = action),
        ),
      ),
    );

    await tester.tap(find.text('Tab'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Tab');
    expect(firedAction!.ctrl, false);

    firedAction = null;
    await tester.tap(find.text('Ctrl+D'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Ctrl+D');
    expect(firedAction!.ctrl, true);
  });

  testWidgets('more button opens the key sheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: Scaffold(body: TerminalKeyBar(onAction: (_) {})),
      ),
    );

    await tester.scrollUntilVisible(find.text('More'), 120);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();

    // The sheet should show category labels and additional keys.
    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('Symbols'), findsOneWidget);
    expect(find.text('Function'), findsOneWidget);
    expect(find.text('Ctrl+C'), findsOneWidget);
  });
}
