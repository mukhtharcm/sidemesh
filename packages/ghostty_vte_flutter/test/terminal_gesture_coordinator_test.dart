import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  group('terminal gesture coordinator', () {
    test('begin selection collapses to the resolved position', () {
      final session = GhosttyTerminalSelectionSession<String>();
      final coordinator = GhosttyTerminalGestureCoordinator<int, String>(
        session,
      );

      session.setLineSelectionAnchorRow(4);

      final selection = coordinator.beginSelection(
        position: 7,
        collapsedSelection: (position) => 'collapsed:$position',
      );

      expect(selection, 'collapsed:7');
      expect(session.lineSelectionAnchorRow, isNull);
    });

    test('update selection uses line selection when an anchor row exists', () {
      final session = GhosttyTerminalSelectionSession<String>();
      final coordinator = GhosttyTerminalGestureCoordinator<int, String>(
        session,
      );

      session.setLineSelectionAnchorRow(9);

      final selection = coordinator.updateSelection(
        currentSelection: 'current',
        position: 14,
        extendSelection: (_, position) => 'extend:$position',
        extendLineSelection: (row, position) => 'line:$row->$position',
      );

      expect(selection, 'line:9->14');
    });

    test('word selection arms the tap-clear guard only when it resolves', () {
      final session = GhosttyTerminalSelectionSession<String>();
      final coordinator = GhosttyTerminalGestureCoordinator<int, String>(
        session,
      );

      expect(
        coordinator.selectWord(position: 2, resolveWordSelection: (_) => null),
        isNull,
      );
      expect(session.consumeIgnoreNextTapClear(), isFalse);

      final selection = coordinator.selectWord(
        position: 3,
        resolveWordSelection: (position) => 'word:$position',
      );

      expect(selection, 'word:3');
      expect(session.consumeIgnoreNextTapClear(), isTrue);
    });

    test('line selection stores the resolved anchor row', () {
      final session = GhosttyTerminalSelectionSession<String>();
      final coordinator = GhosttyTerminalGestureCoordinator<int, String>(
        session,
      );

      final selection = coordinator.beginLineSelection(
        position: 11,
        rowOfPosition: (position) => position,
        resolveLineSelection: (position) => 'line:$position',
      );

      expect(selection, 'line:11');
      expect(session.lineSelectionAnchorRow, 11);
    });

    test('complete word selection clears the tap guard first', () {
      final session = GhosttyTerminalSelectionSession<String>();
      final coordinator = GhosttyTerminalGestureCoordinator<int, String>(
        session,
      );

      session.armIgnoreNextTapClear();

      final selection = coordinator.completeWordSelection(
        position: 5,
        resolveWordSelection: (position) => 'done:$position',
      );

      expect(selection, 'done:5');
      expect(session.consumeIgnoreNextTapClear(), isFalse);
    });
  });
}
