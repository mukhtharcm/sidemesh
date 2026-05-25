import 'terminal_modifier_state.dart';

class TerminalSoftInputTransformResult {
  const TerminalSoftInputTransformResult({
    required this.output,
    required this.nextModifierState,
    required this.modifiersConsumed,
  });

  final String output;
  final TerminalModifierState nextModifierState;
  final bool modifiersConsumed;
}

TerminalSoftInputTransformResult transformTerminalSoftInput({
  required String input,
  required TerminalModifierState modifiers,
}) {
  if (input.isEmpty || !modifiers.hasModifiers) {
    return TerminalSoftInputTransformResult(
      output: input,
      nextModifierState: modifiers,
      modifiersConsumed: false,
    );
  }

  final cleared = modifiers.cleared();

  if (input.runes.length != 1) {
    return TerminalSoftInputTransformResult(
      output: input,
      nextModifierState: cleared,
      modifiersConsumed: true,
    );
  }

  final rune = input.runes.first;
  final ctrlOutput = modifiers.ctrl ? _ctrlCharForRune(rune) : null;
  if (ctrlOutput != null) {
    final output = modifiers.alt ? '\x1b$ctrlOutput' : ctrlOutput;
    return TerminalSoftInputTransformResult(
      output: output,
      nextModifierState: cleared,
      modifiersConsumed: true,
    );
  }

  if (modifiers.alt) {
    return TerminalSoftInputTransformResult(
      output: '\x1b$input',
      nextModifierState: cleared,
      modifiersConsumed: true,
    );
  }

  if (modifiers.shift) {
    return TerminalSoftInputTransformResult(
      output: _shiftedInput(input),
      nextModifierState: cleared,
      modifiersConsumed: true,
    );
  }

  return TerminalSoftInputTransformResult(
    output: input,
    nextModifierState: cleared,
    modifiersConsumed: true,
  );
}

String? _ctrlCharForRune(int rune) {
  final char = String.fromCharCode(rune);
  final upper = char.toUpperCase();
  if (upper.runes.length != 1) return null;
  final code = upper.runes.first;
  if (code >= 0x40 && code <= 0x5F) {
    return String.fromCharCode(code & 0x1F);
  }
  if (code == 0x3F) {
    return String.fromCharCode(0x7F);
  }
  if (code == 0x20) {
    return String.fromCharCode(0x00);
  }
  return null;
}

String _shiftedInput(String input) {
  if (input.runes.length != 1) return input;
  final rune = input.runes.first;
  if (rune >= 0x61 && rune <= 0x7A) {
    return String.fromCharCode(rune - 0x20);
  }
  return input;
}
