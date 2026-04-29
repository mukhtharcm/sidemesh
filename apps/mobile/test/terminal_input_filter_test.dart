import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/terminal_input_filter.dart';

void main() {
  test('strips generated terminal device and size responses', () {
    const data =
        '\x1b[?1;2c'
        '\x1b[>0;0;0c'
        '\x1b[0n'
        '\x1b[12;34R'
        '\x1b[8;33;45t'
        '\x1bP!|00000000\x1b\\';

    expect(stripGeneratedTerminalResponses(data), isEmpty);
  });

  test('preserves normal terminal input', () {
    expect(stripGeneratedTerminalResponses('ls -la\n'), 'ls -la\n');
    expect(stripGeneratedTerminalResponses('\x03'), '\x03');
    expect(stripGeneratedTerminalResponses('\x04'), '\x04');
    expect(stripGeneratedTerminalResponses('\x1b[A'), '\x1b[A');
    expect(stripGeneratedTerminalResponses('\x1b[B'), '\x1b[B');
    expect(
      stripGeneratedTerminalResponses('\x1b[200~hello\x1b[201~'),
      '\x1b[200~hello\x1b[201~',
    );
  });

  test('strips generated responses from mixed input', () {
    expect(stripGeneratedTerminalResponses('echo hi\x1b[?1;2c\n'), 'echo hi\n');
  });
}
