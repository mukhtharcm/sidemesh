import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  test('printable helper keeps platform character payloads', () {
    final text = ghosttyTerminalPrintableText(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'A',
        timeStamp: Duration.zero,
      ),
      modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
    );

    expect(text, 'A');
  });

  test(
    'printable helper infers shifted underscore without character metadata',
    () {
      final text = ghosttyTerminalPrintableText(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.minus,
          logicalKey: LogicalKeyboardKey.minus,
          timeStamp: Duration.zero,
        ),
        modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
      );

      expect(text, '_');
    },
  );

  test('printable helper infers shifted plus without character metadata', () {
    final text = ghosttyTerminalPrintableText(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.equal,
        logicalKey: LogicalKeyboardKey.equal,
        timeStamp: Duration.zero,
      ),
      modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
    );

    expect(text, '+');
  });

  test(
    'printable helper infers shifted backslash without character metadata',
    () {
      final text = ghosttyTerminalPrintableText(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.backslash,
          logicalKey: LogicalKeyboardKey.backslash,
          timeStamp: Duration.zero,
        ),
        modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
      );

      expect(text, '|');
    },
  );

  test(
    'printable helper infers shifted numpad add without character metadata',
    () {
      final text = ghosttyTerminalPrintableText(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.numpadAdd,
          logicalKey: LogicalKeyboardKey.numpadAdd,
          timeStamp: Duration.zero,
        ),
        modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
      );

      expect(text, '+');
    },
  );

  test(
    'printable helper infers unshifted numpad add without character metadata',
    () {
      final text = ghosttyTerminalPrintableText(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.numpadAdd,
          logicalKey: LogicalKeyboardKey.numpadAdd,
          timeStamp: Duration.zero,
        ),
        modifiers: const GhosttyTerminalModifierState(),
      );

      expect(text, '+');
    },
  );

  test(
    'printable helper infers unshifted numpad subtract without character metadata',
    () {
      final text = ghosttyTerminalPrintableText(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.numpadSubtract,
          logicalKey: LogicalKeyboardKey.numpadSubtract,
          timeStamp: Duration.zero,
        ),
        modifiers: const GhosttyTerminalModifierState(),
      );

      expect(text, '-');
    },
  );

  test('printable helper respects direct printable logical labels', () {
    final text = ghosttyTerminalPrintableText(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.minus,
        logicalKey: LogicalKeyboardKey.underscore,
        timeStamp: Duration.zero,
      ),
      modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
    );

    expect(text, '_');
  });

  test('printable helper blocks ctrl-modified text dispatch', () {
    final text = ghosttyTerminalPrintableText(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.equal,
        logicalKey: LogicalKeyboardKey.equal,
        timeStamp: Duration.zero,
      ),
      modifiers: const GhosttyTerminalModifierState(
        shiftPressed: true,
        controlPressed: true,
      ),
    );

    expect(text, isEmpty);
  });

  test('copy shortcut matches ctrl-shift-c on non-macos', () {
    expect(
      ghosttyTerminalMatchesCopyShortcut(
        LogicalKeyboardKey.keyC,
        modifiers: const GhosttyTerminalModifierState(
          controlPressed: true,
          shiftPressed: true,
        ),
        platform: TargetPlatform.linux,
      ),
      isTrue,
    );
  });

  test('paste shortcut matches shift-insert on non-macos', () {
    expect(
      ghosttyTerminalMatchesPasteShortcut(
        LogicalKeyboardKey.insert,
        modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
        platform: TargetPlatform.linux,
      ),
      isTrue,
    );
  });

  test('select-all shortcut matches meta-a on macos', () {
    expect(
      ghosttyTerminalMatchesSelectAllShortcut(
        LogicalKeyboardKey.keyA,
        modifiers: const GhosttyTerminalModifierState(metaPressed: true),
        platform: TargetPlatform.macOS,
      ),
      isTrue,
    );
  });

  test('clear-selection shortcut only matches bare escape', () {
    expect(
      ghosttyTerminalMatchesClearSelectionShortcut(
        LogicalKeyboardKey.escape,
        modifiers: const GhosttyTerminalModifierState(),
      ),
      isTrue,
    );
    expect(
      ghosttyTerminalMatchesClearSelectionShortcut(
        LogicalKeyboardKey.escape,
        modifiers: const GhosttyTerminalModifierState(controlPressed: true),
      ),
      isFalse,
    );
  });

  test('half-page scroll shortcut matches bare shift-pageUp and pageDown', () {
    expect(
      ghosttyTerminalMatchesHalfPageScrollShortcut(
        LogicalKeyboardKey.pageUp,
        modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
        upward: true,
      ),
      isTrue,
    );
    expect(
      ghosttyTerminalMatchesHalfPageScrollShortcut(
        LogicalKeyboardKey.pageDown,
        modifiers: const GhosttyTerminalModifierState(shiftPressed: true),
        upward: false,
      ),
      isTrue,
    );
    expect(
      ghosttyTerminalMatchesHalfPageScrollShortcut(
        LogicalKeyboardKey.pageUp,
        modifiers: const GhosttyTerminalModifierState(
          shiftPressed: true,
          controlPressed: true,
        ),
        upward: true,
      ),
      isFalse,
    );
  });
}
