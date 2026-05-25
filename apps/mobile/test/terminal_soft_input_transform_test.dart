import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/terminal_modifier_state.dart';
import 'package:sidemesh_mobile/src/terminal_soft_input_transform.dart';

void main() {
  test('passes through plain input when no modifiers are latched', () {
    final result = transformTerminalSoftInput(
      input: 'd',
      modifiers: const TerminalModifierState(),
    );

    expect(result.output, 'd');
    expect(result.modifiersConsumed, isFalse);
    expect(result.nextModifierState, const TerminalModifierState());
  });

  test('maps ctrl plus letter to the control byte', () {
    final result = transformTerminalSoftInput(
      input: 'd',
      modifiers: const TerminalModifierState(ctrl: true),
    );

    expect(result.output, '\x04');
    expect(result.modifiersConsumed, isTrue);
    expect(result.nextModifierState, const TerminalModifierState());
  });

  test('maps ctrl plus bracket to escape', () {
    final result = transformTerminalSoftInput(
      input: '[',
      modifiers: const TerminalModifierState(ctrl: true),
    );

    expect(result.output, '\x1b');
    expect(result.modifiersConsumed, isTrue);
    expect(result.nextModifierState, const TerminalModifierState());
  });

  test('prefixes alt with escape', () {
    final result = transformTerminalSoftInput(
      input: 'x',
      modifiers: const TerminalModifierState(alt: true),
    );

    expect(result.output, '\x1bx');
    expect(result.modifiersConsumed, isTrue);
    expect(result.nextModifierState, const TerminalModifierState());
  });

  test('uppercases lowercase ascii when shift is latched', () {
    final result = transformTerminalSoftInput(
      input: 'd',
      modifiers: const TerminalModifierState(shift: true),
    );

    expect(result.output, 'D');
    expect(result.modifiersConsumed, isTrue);
    expect(result.nextModifierState, const TerminalModifierState());
  });

  test('clears modifiers after multi-character soft input commits', () {
    final result = transformTerminalSoftInput(
      input: 'dd',
      modifiers: const TerminalModifierState(ctrl: true),
    );

    expect(result.output, 'dd');
    expect(result.modifiersConsumed, isTrue);
    expect(result.nextModifierState, const TerminalModifierState());
  });
}
