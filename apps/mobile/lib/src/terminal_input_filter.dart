final _generatedTerminalResponsePattern = RegExp(
  '\x1B(?:'
  r'\[(?:\?[\d;]*|>[\d;]*|[\d;]*)c|'
  r'\[[\d;]*t|'
  r'P!\|[0-9A-Fa-f]*'
  '\x1B'
  r'\\'
  ')',
);

String stripGeneratedTerminalResponses(String data) {
  if (data.isEmpty) return data;

  // xterm.dart uses onOutput for keyboard input and automatic terminal query
  // replies. Device/window replies can leak into shells as prompt text, but
  // cursor/status reports must pass through because TUIs and CLIs such as gh
  // can block while waiting for them.
  return data.replaceAll(_generatedTerminalResponsePattern, '');
}
