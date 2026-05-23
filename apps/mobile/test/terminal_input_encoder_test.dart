import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/terminal_input_encoder.dart';
import 'package:sidemesh_mobile/src/terminal_key_models.dart';
import 'package:xterm/xterm.dart' as xterm;

void main() {
  test('encodes ctrl letter shortcuts into control bytes', () {
    expect(
      encodeTerminalKeyAction(
        const TerminalKeyAction(
          label: 'Ctrl+C',
          key: xterm.TerminalKey.keyC,
          ctrl: true,
        ),
      ),
      '\u0003',
    );
    expect(
      encodeTerminalKeyAction(
        const TerminalKeyAction(
          label: 'Ctrl+D',
          key: xterm.TerminalKey.keyD,
          ctrl: true,
        ),
      ),
      '\u0004',
    );
  });

  test('encodes common direct keys and leaves unsupported keys to xterm', () {
    expect(
      encodeTerminalKeyAction(
        const TerminalKeyAction(label: 'Esc', key: xterm.TerminalKey.escape),
      ),
      '\u001b',
    );
    expect(
      encodeTerminalKeyAction(
        const TerminalKeyAction(label: 'Tab', key: xterm.TerminalKey.tab),
      ),
      '\t',
    );
    expect(
      encodeTerminalKeyAction(
        const TerminalKeyAction(
          label: 'Arrow',
          key: xterm.TerminalKey.arrowLeft,
        ),
      ),
      isNull,
    );
  });

  test('passes raw text through unchanged', () {
    expect(
      encodeTerminalKeyAction(
        const TerminalKeyAction(label: '|', rawText: '|'),
      ),
      '|',
    );
  });
}
