import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/terminal_key_models.dart';
import 'package:sidemesh_mobile/src/terminal_modifier_state.dart';
import 'package:sidemesh_mobile/src/terminal_keybar_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/terminal_keybar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TerminalKeyBarStore.instance.resetForTest();
  });

  testWidgets('renders essential row with modifiers and more button', (
    tester,
  ) async {
    TerminalKeyAction? firedAction;
    TerminalModifierState modifierState = const TerminalModifierState();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: TerminalKeyBar(
              modifierState: modifierState,
              onModifierStateChanged: (value) =>
                  setState(() => modifierState = value),
              onAction: (action) => firedAction = action,
            ),
          ),
        ),
      ),
    );

    // Essential keys should always be visible.
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Tab'), findsOneWidget);
    expect(find.text('←'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
    expect(find.text('↓'), findsOneWidget);
    expect(find.text('→'), findsOneWidget);

    // Modifier pills should appear.
    expect(find.text('Ctrl'), findsOneWidget);
    expect(find.text('Alt'), findsOneWidget);
    expect(find.text('Shift'), findsOneWidget);

    // More button (icon) should appear.
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

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
    TerminalModifierState modifierState = const TerminalModifierState();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: TerminalKeyBar(
              modifierState: modifierState,
              onModifierStateChanged: (value) =>
                  setState(() => modifierState = value),
              onAction: (action) => firedAction = action,
            ),
          ),
        ),
      ),
    );

    // Tap the Ctrl modifier pill.
    await tester.tap(find.text('Ctrl'));
    await tester.pumpAndSettle();

    // Tap a plain key.
    await tester.tap(find.text('Tab'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Tab');
    expect(firedAction!.ctrl, true);

    // After the key was sent the modifier should have auto-cleared.
    firedAction = null;
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Esc');
    expect(firedAction!.ctrl, false);
  });

  testWidgets('modifier also applies to actions from the more sheet', (
    tester,
  ) async {
    TerminalKeyAction? firedAction;
    TerminalModifierState modifierState = const TerminalModifierState();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: TerminalKeyBar(
              modifierState: modifierState,
              onModifierStateChanged: (value) =>
                  setState(() => modifierState = value),
              onAction: (action) => firedAction = action,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Ctrl'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Enter');
    expect(firedAction!.ctrl, true);

    firedAction = null;
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(firedAction, isNotNull);
    expect(firedAction!.label, 'Esc');
    expect(firedAction!.ctrl, false);
  });

  testWidgets('more button opens the key sheet', (tester) async {
    TerminalModifierState modifierState = const TerminalModifierState();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: TerminalKeyBar(
              modifierState: modifierState,
              onModifierStateChanged: (value) =>
                  setState(() => modifierState = value),
              onAction: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    // The sheet should open with the extra-keys content visible.
    expect(find.text('Extra keys'), findsOneWidget);
    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('Enter'), findsOneWidget);
  });
}
