library;

import 'package:flutter/services.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

/// Normalized hardware modifier state for terminal input dispatch.
final class GhosttyTerminalModifierState {
  const GhosttyTerminalModifierState({
    this.shiftPressed = false,
    this.controlPressed = false,
    this.altPressed = false,
    this.metaPressed = false,
  });

  factory GhosttyTerminalModifierState.fromHardwareKeyboard() {
    final keyboard = HardwareKeyboard.instance;
    return GhosttyTerminalModifierState(
      shiftPressed: keyboard.isShiftPressed,
      controlPressed: keyboard.isControlPressed,
      altPressed: keyboard.isAltPressed,
      metaPressed: keyboard.isMetaPressed,
    );
  }

  final bool shiftPressed;
  final bool controlPressed;
  final bool altPressed;
  final bool metaPressed;

  int get ghosttyMask {
    var mods = 0;
    if (shiftPressed) {
      mods |= GhosttyModsMask.shift;
    }
    if (controlPressed) {
      mods |= GhosttyModsMask.ctrl;
    }
    if (altPressed) {
      mods |= GhosttyModsMask.alt;
    }
    if (metaPressed) {
      mods |= GhosttyModsMask.superKey;
    }
    return mods;
  }

  bool get blocksPrintableText {
    return controlPressed || altPressed || metaPressed;
  }
}

final Map<LogicalKeyboardKey, GhosttyKey> ghosttyTerminalLogicalKeyMap =
    <LogicalKeyboardKey, GhosttyKey>{
      LogicalKeyboardKey.enter: GhosttyKey.GHOSTTY_KEY_ENTER,
      LogicalKeyboardKey.numpadEnter: GhosttyKey.GHOSTTY_KEY_ENTER,
      LogicalKeyboardKey.tab: GhosttyKey.GHOSTTY_KEY_TAB,
      LogicalKeyboardKey.escape: GhosttyKey.GHOSTTY_KEY_ESCAPE,
      LogicalKeyboardKey.backspace: GhosttyKey.GHOSTTY_KEY_BACKSPACE,
      LogicalKeyboardKey.delete: GhosttyKey.GHOSTTY_KEY_DELETE,
      LogicalKeyboardKey.insert: GhosttyKey.GHOSTTY_KEY_INSERT,
      LogicalKeyboardKey.home: GhosttyKey.GHOSTTY_KEY_HOME,
      LogicalKeyboardKey.end: GhosttyKey.GHOSTTY_KEY_END,
      LogicalKeyboardKey.pageUp: GhosttyKey.GHOSTTY_KEY_PAGE_UP,
      LogicalKeyboardKey.pageDown: GhosttyKey.GHOSTTY_KEY_PAGE_DOWN,
      LogicalKeyboardKey.arrowUp: GhosttyKey.GHOSTTY_KEY_ARROW_UP,
      LogicalKeyboardKey.arrowDown: GhosttyKey.GHOSTTY_KEY_ARROW_DOWN,
      LogicalKeyboardKey.arrowLeft: GhosttyKey.GHOSTTY_KEY_ARROW_LEFT,
      LogicalKeyboardKey.arrowRight: GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT,
      LogicalKeyboardKey.f1: GhosttyKey.GHOSTTY_KEY_F1,
      LogicalKeyboardKey.f2: GhosttyKey.GHOSTTY_KEY_F2,
      LogicalKeyboardKey.f3: GhosttyKey.GHOSTTY_KEY_F3,
      LogicalKeyboardKey.f4: GhosttyKey.GHOSTTY_KEY_F4,
      LogicalKeyboardKey.f5: GhosttyKey.GHOSTTY_KEY_F5,
      LogicalKeyboardKey.f6: GhosttyKey.GHOSTTY_KEY_F6,
      LogicalKeyboardKey.f7: GhosttyKey.GHOSTTY_KEY_F7,
      LogicalKeyboardKey.f8: GhosttyKey.GHOSTTY_KEY_F8,
      LogicalKeyboardKey.f9: GhosttyKey.GHOSTTY_KEY_F9,
      LogicalKeyboardKey.f10: GhosttyKey.GHOSTTY_KEY_F10,
      LogicalKeyboardKey.f11: GhosttyKey.GHOSTTY_KEY_F11,
      LogicalKeyboardKey.f12: GhosttyKey.GHOSTTY_KEY_F12,
    };

final Map<LogicalKeyboardKey, String> _shiftedPrintableFallbacks =
    <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.digit1: '!',
      LogicalKeyboardKey.digit2: '@',
      LogicalKeyboardKey.digit3: '#',
      LogicalKeyboardKey.digit4: r'$',
      LogicalKeyboardKey.digit5: '%',
      LogicalKeyboardKey.digit6: '^',
      LogicalKeyboardKey.digit7: '&',
      LogicalKeyboardKey.digit8: '*',
      LogicalKeyboardKey.digit9: '(',
      LogicalKeyboardKey.digit0: ')',
      LogicalKeyboardKey.minus: '_',
      LogicalKeyboardKey.underscore: '_',
      LogicalKeyboardKey.equal: '+',
      LogicalKeyboardKey.braceLeft: '{',
      LogicalKeyboardKey.braceRight: '}',
      LogicalKeyboardKey.bracketLeft: '[',
      LogicalKeyboardKey.bracketRight: ']',
      LogicalKeyboardKey.backslash: '|',
      LogicalKeyboardKey.semicolon: ':',
      LogicalKeyboardKey.quote: '"',
      LogicalKeyboardKey.backquote: '~',
      LogicalKeyboardKey.comma: '<',
      LogicalKeyboardKey.period: '>',
      LogicalKeyboardKey.slash: '?',
      LogicalKeyboardKey.numpadAdd: '+',
    };

final Map<LogicalKeyboardKey, String> _printableFallbacks =
    <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.numpadAdd: '+',
      LogicalKeyboardKey.numpadSubtract: '-',
      LogicalKeyboardKey.numpadMultiply: '*',
      LogicalKeyboardKey.numpadDivide: '/',
      LogicalKeyboardKey.numpadDecimal: '.',
    };

final Map<PhysicalKeyboardKey, String> _shiftedPhysicalPrintableFallbacks =
    <PhysicalKeyboardKey, String>{
      PhysicalKeyboardKey.digit1: '!',
      PhysicalKeyboardKey.digit2: '@',
      PhysicalKeyboardKey.digit3: '#',
      PhysicalKeyboardKey.digit4: r'$',
      PhysicalKeyboardKey.digit5: '%',
      PhysicalKeyboardKey.digit6: '^',
      PhysicalKeyboardKey.digit7: '&',
      PhysicalKeyboardKey.digit8: '*',
      PhysicalKeyboardKey.digit9: '(',
      PhysicalKeyboardKey.digit0: ')',
      PhysicalKeyboardKey.minus: '_',
      PhysicalKeyboardKey.equal: '+',
      PhysicalKeyboardKey.bracketLeft: '{',
      PhysicalKeyboardKey.bracketRight: '}',
      PhysicalKeyboardKey.backslash: '|',
      PhysicalKeyboardKey.semicolon: ':',
      PhysicalKeyboardKey.quote: '"',
      PhysicalKeyboardKey.backquote: '~',
      PhysicalKeyboardKey.comma: '<',
      PhysicalKeyboardKey.period: '>',
      PhysicalKeyboardKey.slash: '?',
      PhysicalKeyboardKey.numpadAdd: '+',
    };

final Map<PhysicalKeyboardKey, String> _printablePhysicalFallbacks =
    <PhysicalKeyboardKey, String>{
      PhysicalKeyboardKey.numpadAdd: '+',
      PhysicalKeyboardKey.numpadSubtract: '-',
      PhysicalKeyboardKey.numpadMultiply: '*',
      PhysicalKeyboardKey.numpadDivide: '/',
      PhysicalKeyboardKey.numpadDecimal: '.',
    };

/// Resolves a Flutter logical key to a Ghostty key enum when it should be
/// encoded as a terminal special key.
GhosttyKey? ghosttyTerminalLogicalKey(LogicalKeyboardKey key) {
  return ghosttyTerminalLogicalKeyMap[key];
}

/// Whether the current key chord should trigger terminal copy.
bool ghosttyTerminalMatchesCopyShortcut(
  LogicalKeyboardKey key, {
  required GhosttyTerminalModifierState modifiers,
  required TargetPlatform platform,
}) {
  if (platform == TargetPlatform.macOS) {
    return modifiers.metaPressed && key == LogicalKeyboardKey.keyC;
  }
  return modifiers.controlPressed &&
      modifiers.shiftPressed &&
      key == LogicalKeyboardKey.keyC;
}

/// Whether the current key chord should trigger terminal paste.
bool ghosttyTerminalMatchesPasteShortcut(
  LogicalKeyboardKey key, {
  required GhosttyTerminalModifierState modifiers,
  required TargetPlatform platform,
}) {
  if (platform == TargetPlatform.macOS) {
    return modifiers.metaPressed && key == LogicalKeyboardKey.keyV;
  }
  return (modifiers.controlPressed &&
          modifiers.shiftPressed &&
          key == LogicalKeyboardKey.keyV) ||
      (modifiers.shiftPressed && key == LogicalKeyboardKey.insert);
}

/// Whether the current key chord should trigger terminal select-all.
bool ghosttyTerminalMatchesSelectAllShortcut(
  LogicalKeyboardKey key, {
  required GhosttyTerminalModifierState modifiers,
  required TargetPlatform platform,
}) {
  if (platform == TargetPlatform.macOS) {
    return modifiers.metaPressed && key == LogicalKeyboardKey.keyA;
  }
  return modifiers.controlPressed &&
      modifiers.shiftPressed &&
      key == LogicalKeyboardKey.keyA;
}

/// Whether the current key press should clear terminal selection state.
bool ghosttyTerminalMatchesClearSelectionShortcut(
  LogicalKeyboardKey key, {
  required GhosttyTerminalModifierState modifiers,
}) {
  return !modifiers.controlPressed &&
      !modifiers.metaPressed &&
      !modifiers.altPressed &&
      !modifiers.shiftPressed &&
      key == LogicalKeyboardKey.escape;
}

/// Whether the current key press should scroll the terminal by half a page.
bool ghosttyTerminalMatchesHalfPageScrollShortcut(
  LogicalKeyboardKey key, {
  required GhosttyTerminalModifierState modifiers,
  required bool upward,
}) {
  return modifiers.shiftPressed &&
      !modifiers.controlPressed &&
      !modifiers.metaPressed &&
      !modifiers.altPressed &&
      key == (upward ? LogicalKeyboardKey.pageUp : LogicalKeyboardKey.pageDown);
}

/// Resolves printable terminal text for a Flutter key event.
///
/// This prefers the platform-provided character, but falls back to
/// logical-key-based punctuation inference when the event omitted character
/// metadata for shifted symbol keys.
String ghosttyTerminalPrintableText(
  KeyEvent event, {
  required GhosttyTerminalModifierState modifiers,
}) {
  final character = event.character ?? '';

  if (modifiers.blocksPrintableText) {
    return '';
  }

  if (modifiers.shiftPressed) {
    final shifted =
        _shiftedPhysicalPrintableFallbacks[event.physicalKey] ??
        _shiftedPrintableFallbacks[event.logicalKey];
    if (shifted != null) {
      return shifted;
    }
  }
  if (character.isNotEmpty) {
    return character;
  }
  final fallback =
      _printablePhysicalFallbacks[event.physicalKey] ??
      _printableFallbacks[event.logicalKey];
  if (fallback != null) {
    return fallback;
  }
  if (modifiers.shiftPressed) {
    final shifted =
        _shiftedPhysicalPrintableFallbacks[event.physicalKey] ??
        _shiftedPrintableFallbacks[event.logicalKey];
    if (shifted != null) {
      return shifted;
    }
  }
  final keyLabel = event.logicalKey.keyLabel;
  if (keyLabel.runes.length == 1 &&
      !ghosttyTerminalLogicalKeyMap.containsKey(event.logicalKey)) {
    return keyLabel;
  }
  return '';
}

/// Resolves ASCII control characters for Ctrl-based key chords such as
/// `Ctrl+C`, `Ctrl+D`, and `Ctrl+L`.
String? ghosttyTerminalControlText(
  KeyEvent event, {
  required GhosttyTerminalModifierState modifiers,
}) {
  if (!modifiers.controlPressed ||
      modifiers.altPressed ||
      modifiers.metaPressed) {
    return null;
  }

  final keyLabel = event.logicalKey.keyLabel;
  if (keyLabel.isEmpty) {
    return null;
  }

  final upper = keyLabel.toUpperCase();
  if (upper.runes.length == 1) {
    final code = upper.runes.first;
    if (code >= 0x41 && code <= 0x5A) {
      return String.fromCharCode(code - 0x40);
    }
  }

  return switch (keyLabel) {
    ' ' => String.fromCharCode(0x00),
    '[' => String.fromCharCode(0x1B),
    '\\' => String.fromCharCode(0x1C),
    ']' => String.fromCharCode(0x1D),
    '^' => String.fromCharCode(0x1E),
    '/' || '_' => String.fromCharCode(0x1F),
    _ => null,
  };
}
