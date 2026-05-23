import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/terminal_link_detector.dart';
import 'package:xterm/xterm.dart' as xterm;

void main() {
  test('finds wrapped urls at tapped cells', () {
    final terminal = xterm.Terminal(maxLines: 100);
    terminal.resize(8, 6);
    terminal.write('https://example.com/path');

    final match = terminalUrlAtCell(terminal, const xterm.CellOffset(2, 1));

    expect(match, isNotNull);
    expect(match!.href, 'https://example.com/path');
    expect(match.displayText, 'https://example.com/path');
  });

  test('expands a partial wrapped selection to the full url', () {
    final terminal = xterm.Terminal(maxLines: 100);
    terminal.resize(8, 6);
    terminal.write('https://example.com/path');

    final expanded = terminalUrlRangeContainingSelection(
      terminal,
      xterm.BufferRangeLine(
        const xterm.CellOffset(1, 1),
        const xterm.CellOffset(5, 1),
      ),
    );

    expect(expanded, isNotNull);
    expect(terminal.buffer.getText(expanded!), 'https://example.com/path');
  });

  test('trims trailing punctuation from copied links', () {
    final match = firstTerminalUrl('open https://example.com/path), next');

    expect(match, isNotNull);
    expect(match!.displayText, 'https://example.com/path');
    expect(match.href, 'https://example.com/path');
  });
}
