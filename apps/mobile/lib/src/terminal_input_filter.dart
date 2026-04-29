final _generatedTerminalResponsePattern = RegExp(
  '\x1B(?:'
  r'\[(?:\?[\d;]*|>[\d;]*|[\d;]*)[cRn]|'
  r'\[[\d;]*t|'
  r'P!\|[0-9A-Fa-f]*'
  '\x1B'
  r'\\'
  ')',
);

String stripGeneratedTerminalResponses(String data) {
  if (data.isEmpty) return data;

  // xterm.dart uses onOutput for keyboard input and automatic terminal query
  // replies. Those replies can leak into interactive shells as prompt text.
  return data.replaceAll(_generatedTerminalResponsePattern, '');
}
