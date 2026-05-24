// ignore_for_file: avoid_print

import 'package:ghostty_vte/ghostty_vte.dart';

void main() {
  final terminal = GhosttyVt.newTerminal(cols: 10, rows: 3, maxScrollback: 100);
  for (var i = 1; i <= 5; i++) {
    terminal.write('L$i\r\n');
  }
  final vt = terminal.createFormatter(
    const VtFormatterTerminalOptions(
      emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
      trim: false,
      extra: VtFormatterTerminalExtra(
        screen: VtFormatterScreenExtra(cursor: true, style: true),
      ),
    ),
  );
  final plain = terminal.createFormatter(
    const VtFormatterTerminalOptions(trim: false),
  );
  print('PLAIN>>>');
  print(plain.formatText().replaceAll(' ', '.').replaceAll('\x1b', '<ESC>'));
  print('VT>>>');
  print(vt.formatText().replaceAll(' ', '.').replaceAll('\x1b', '<ESC>'));
  plain.close();
  vt.close();
  terminal.close();
}
