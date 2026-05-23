import 'package:xterm/xterm.dart' as xterm;

import 'terminal_key_models.dart';

String? encodeTerminalKeyAction(TerminalKeyAction action) {
  final rawText = action.rawText;
  if (rawText != null && rawText.isNotEmpty) {
    return rawText;
  }

  final key = action.key;
  if (key == null) {
    return null;
  }

  if (!action.alt && !action.shift) {
    final control = _controlCodeForKey(key, ctrl: action.ctrl);
    if (control != null) {
      return control;
    }
  }

  return null;
}

String? _controlCodeForKey(xterm.TerminalKey key, {required bool ctrl}) {
  if (ctrl) {
    final codePoint = switch (key) {
      xterm.TerminalKey.keyA => 0x01,
      xterm.TerminalKey.keyB => 0x02,
      xterm.TerminalKey.keyC => 0x03,
      xterm.TerminalKey.keyD => 0x04,
      xterm.TerminalKey.keyE => 0x05,
      xterm.TerminalKey.keyF => 0x06,
      xterm.TerminalKey.keyG => 0x07,
      xterm.TerminalKey.keyH => 0x08,
      xterm.TerminalKey.keyI => 0x09,
      xterm.TerminalKey.keyJ => 0x0A,
      xterm.TerminalKey.keyK => 0x0B,
      xterm.TerminalKey.keyL => 0x0C,
      xterm.TerminalKey.keyM => 0x0D,
      xterm.TerminalKey.keyN => 0x0E,
      xterm.TerminalKey.keyO => 0x0F,
      xterm.TerminalKey.keyP => 0x10,
      xterm.TerminalKey.keyQ => 0x11,
      xterm.TerminalKey.keyR => 0x12,
      xterm.TerminalKey.keyS => 0x13,
      xterm.TerminalKey.keyT => 0x14,
      xterm.TerminalKey.keyU => 0x15,
      xterm.TerminalKey.keyV => 0x16,
      xterm.TerminalKey.keyW => 0x17,
      xterm.TerminalKey.keyX => 0x18,
      xterm.TerminalKey.keyY => 0x19,
      xterm.TerminalKey.keyZ => 0x1A,
      _ => null,
    };
    if (codePoint != null) {
      return String.fromCharCode(codePoint);
    }
  }

  return switch (key) {
    xterm.TerminalKey.enter => '\r',
    xterm.TerminalKey.tab => '\t',
    xterm.TerminalKey.escape => '\u001b',
    xterm.TerminalKey.backspace => '\u007f',
    _ => null,
  };
}
