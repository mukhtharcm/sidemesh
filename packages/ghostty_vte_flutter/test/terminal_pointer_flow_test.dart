import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  group('terminal pointer flow helpers', () {
    test('hover helper normalizes and stores the resolved hyperlink', () {
      final session = GhosttyTerminalSelectionSession<String>();

      final changed = ghosttyTerminalUpdateHoveredLink<int, String>(
        session: session,
        position: 4,
        resolveUri: (position) => 'https://example.com/$position',
      );

      expect(changed, isTrue);
      expect(session.hoveredHyperlink, 'https://example.com/4');
    });

    test('clear hover helper reports whether state changed', () {
      final session = GhosttyTerminalSelectionSession<String>();
      session.updateHoveredHyperlink('https://example.com');

      expect(ghosttyTerminalClearHoveredLink<String>(session: session), isTrue);
      expect(
        ghosttyTerminalClearHoveredLink<String>(session: session),
        isFalse,
      );
    });

    test('tap helper ignores tap clear when armed by word selection', () {
      final session = GhosttyTerminalSelectionSession<String>();
      session.armIgnoreNextTapClear();

      final resolution = ghosttyTerminalResolveTap<int, String>(
        session: session,
        selection: 'selected',
        position: 2,
        resolveUri: (position) => 'https://example.com/$position',
      );

      expect(resolution.hyperlink, isNull);
      expect(resolution.clearSelection, isFalse);
    });

    test('tap helper prefers hyperlinks over clearing selection', () {
      final session = GhosttyTerminalSelectionSession<String>();

      final resolution = ghosttyTerminalResolveTap<int, String>(
        session: session,
        selection: 'selected',
        position: 7,
        resolveUri: (position) => 'https://example.com/$position',
      );

      expect(resolution.hyperlink, 'https://example.com/7');
      expect(resolution.clearSelection, isFalse);
    });

    test('tap helper clears selection when no hyperlink resolves', () {
      final session = GhosttyTerminalSelectionSession<String>();

      final resolution = ghosttyTerminalResolveTap<int, String>(
        session: session,
        selection: 'selected',
        position: 3,
        resolveUri: (_) => null,
      );

      expect(resolution.hyperlink, isNull);
      expect(resolution.clearSelection, isTrue);
    });
  });
}
