import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  testWidgets('renders terminal widget', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: GhosttyTerminalWidget(
          sampleInput: 'echo hello',
          isPasteSafe: _alwaysSafe,
        ),
      ),
    );

    expect(find.textContaining('ghostty_vte_flutter'), findsOneWidget);
    expect(find.textContaining('paste safe: true'), findsOneWidget);
  });
}

bool _alwaysSafe(String _) => true;
