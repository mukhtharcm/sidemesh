import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:example/main.dart';

void main() {
  testWidgets('renders terminal studio shell', (WidgetTester tester) async {
    final controller = _StubTerminalController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(autoStart: false, controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Ghostty VT Studio'), findsOneWidget);
    expect(find.text('Send Command'), findsOneWidget);
    expect(find.text('Inject VT Demo'), findsOneWidget);
    expect(find.text('Restart Shell'), findsOneWidget);
    expect(find.text('Snapshots', skipOffstage: false), findsOneWidget);
    expect(find.text('Key Encoder', skipOffstage: false), findsOneWidget);
    expect(find.text('Parsers', skipOffstage: false), findsOneWidget);
    expect(find.text('Session', skipOffstage: false), findsOneWidget);
    expect(find.text('Terminal', skipOffstage: false), findsOneWidget);
    expect(find.text('All Extras', skipOffstage: false), findsOneWidget);
    expect(find.text('Render Semantics', skipOffstage: false), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Formatter Paint'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Render Paint'), findsOneWidget);
    expect(find.text('Auto'), findsWidgets);
    expect(find.text('Selection First'), findsOneWidget);
    expect(find.text('Terminal Mouse'), findsWidgets);
    expect(find.textContaining('Mouse reporting'), findsOneWidget);
    expect(find.text('Mouse Tracking'), findsOneWidget);
    expect(find.text('Mouse Format'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('SGR Pixels'), findsOneWidget);
    expect(find.text('Focus Events'), findsOneWidget);
    expect(find.text('Alt Scroll'), findsOneWidget);
  });

  testWidgets('toggles between renderer modes', (WidgetTester tester) async {
    final controller = _StubTerminalController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(autoStart: false, controller: controller));
    await tester.pumpAndSettle();

    final formatterFinder = find.widgetWithText(ChoiceChip, 'Formatter Paint');
    final renderFinder = find.widgetWithText(ChoiceChip, 'Render Paint');

    expect(tester.widget<ChoiceChip>(formatterFinder).selected, isTrue);
    expect(tester.widget<ChoiceChip>(renderFinder).selected, isFalse);

    await tester.tap(renderFinder);
    await tester.pumpAndSettle();

    expect(tester.widget<ChoiceChip>(formatterFinder).selected, isFalse);
    expect(tester.widget<ChoiceChip>(renderFinder).selected, isTrue);
  });

  testWidgets('toggles interaction policy modes', (WidgetTester tester) async {
    final controller = _StubTerminalController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MyApp(autoStart: false, controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Interaction: auto'), findsOneWidget);

    await tester.tap(find.text('Selection First').first);
    await tester.pumpAndSettle();
    expect(find.text('Interaction: selectionFirst'), findsOneWidget);

    await tester.tap(find.text('Terminal Mouse').first);
    await tester.pumpAndSettle();
    expect(find.text('Interaction: terminalMouseFirst'), findsOneWidget);
  });
}

class _StubTerminalController extends GhosttyTerminalController {
  @override
  void resize({
    required int cols,
    required int rows,
    int cellWidthPx = 0,
    int cellHeightPx = 0,
  }) {}

  @override
  String formatTerminal({
    GhosttyFormatterFormat emit =
        GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
    bool unwrap = false,
    bool trim = true,
    VtFormatterTerminalExtra extra = const VtFormatterTerminalExtra(),
  }) {
    return '';
  }
}
