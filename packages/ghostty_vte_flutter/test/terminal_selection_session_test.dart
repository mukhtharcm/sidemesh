import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  group('terminal selection session', () {
    test('tracks selection changes and resets cleanly', () {
      final session = GhosttyTerminalSelectionSession<int>();

      expect(session.selection, isNull);
      expect(session.updateSelection(3), isTrue);
      expect(session.selection, 3);
      expect(session.updateSelection(3), isFalse);

      session.reset();
      expect(session.selection, isNull);
    });

    test('normalizes hovered hyperlinks and can clear them', () {
      final session = GhosttyTerminalSelectionSession<int>();

      expect(session.updateHoveredHyperlink('https://example.com'), isTrue);
      expect(session.hoveredHyperlink, 'https://example.com');
      expect(session.updateHoveredHyperlink(''), isTrue);
      expect(session.hoveredHyperlink, isNull);
      expect(session.clearHoveredHyperlink(), isFalse);
    });

    test('tracks line selection anchor rows', () {
      final session = GhosttyTerminalSelectionSession<int>();

      session.setLineSelectionAnchorRow(12);
      expect(session.lineSelectionAnchorRow, 12);
      session.clearLineSelectionAnchorRow();
      expect(session.lineSelectionAnchorRow, isNull);
    });

    test('consumes the tap-clear guard once', () {
      final session = GhosttyTerminalSelectionSession<int>();

      session.armIgnoreNextTapClear();
      expect(session.consumeIgnoreNextTapClear(), isTrue);
      expect(session.consumeIgnoreNextTapClear(), isFalse);

      session.armIgnoreNextTapClear();
      session.resetIgnoreNextTapClear();
      expect(session.consumeIgnoreNextTapClear(), isFalse);
    });
  });
}
