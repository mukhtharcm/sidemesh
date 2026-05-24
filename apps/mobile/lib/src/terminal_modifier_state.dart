import 'package:flutter/foundation.dart';

@immutable
class TerminalModifierState {
  const TerminalModifierState({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  static const none = TerminalModifierState();

  final bool ctrl;
  final bool alt;
  final bool shift;

  bool get hasModifiers => ctrl || alt || shift;

  TerminalModifierState copyWith({
    bool? ctrl,
    bool? alt,
    bool? shift,
  }) {
    return TerminalModifierState(
      ctrl: ctrl ?? this.ctrl,
      alt: alt ?? this.alt,
      shift: shift ?? this.shift,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalModifierState &&
        other.ctrl == ctrl &&
        other.alt == alt &&
        other.shift == shift;
  }

  @override
  int get hashCode => Object.hash(ctrl, alt, shift);
}
