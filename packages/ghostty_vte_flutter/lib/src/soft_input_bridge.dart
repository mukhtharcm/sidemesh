import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

import 'terminal_controller.dart';

@immutable
class GhosttyTerminalSoftInputModifiers {
  const GhosttyTerminalSoftInputModifiers({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  static const none = GhosttyTerminalSoftInputModifiers();

  final bool ctrl;
  final bool alt;
  final bool shift;

  bool get hasModifiers => ctrl || alt || shift;

  int get modsMask {
    var mods = 0;
    if (ctrl) {
      mods |= GhosttyModsMask.ctrl;
    }
    if (alt) {
      mods |= GhosttyModsMask.alt;
    }
    if (shift) {
      mods |= GhosttyModsMask.shift;
    }
    return mods;
  }

  GhosttyTerminalSoftInputModifiers copyWith({
    bool? ctrl,
    bool? alt,
    bool? shift,
  }) {
    return GhosttyTerminalSoftInputModifiers(
      ctrl: ctrl ?? this.ctrl,
      alt: alt ?? this.alt,
      shift: shift ?? this.shift,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GhosttyTerminalSoftInputModifiers &&
        other.ctrl == ctrl &&
        other.alt == alt &&
        other.shift == shift;
  }

  @override
  int get hashCode => Object.hash(ctrl, alt, shift);
}

class GhosttyTerminalSoftInputBridge extends StatefulWidget {
  const GhosttyTerminalSoftInputBridge({
    super.key,
    required this.focusNode,
    required this.controller,
    required this.modifiers,
    required this.onModifiersConsumed,
    this.keyboardType = TextInputType.text,
    this.keyboardAppearance = Brightness.dark,
    this.deleteDetection = true,
  });

  final FocusNode focusNode;
  final GhosttyTerminalController controller;
  final GhosttyTerminalSoftInputModifiers modifiers;
  final VoidCallback onModifiersConsumed;
  final TextInputType keyboardType;
  final Brightness keyboardAppearance;
  final bool deleteDetection;

  @override
  State<GhosttyTerminalSoftInputBridge> createState() =>
      _GhosttyTerminalSoftInputBridgeState();
}

class _GhosttyTerminalSoftInputBridgeState
    extends State<GhosttyTerminalSoftInputBridge>
    with TextInputClient {
  TextInputConnection? _connection;

  TextEditingValue get _initialEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late TextEditingValue _currentEditingState = _initialEditingState;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant GhosttyTerminalSoftInputBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChange);
      widget.focusNode.addListener(_handleFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    _closeConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }

  bool get _hasConnection => _connection?.attached == true;

  void _handleFocusChange() {
    if (widget.focusNode.hasFocus) {
      _openConnection();
      return;
    }
    _closeConnectionIfNeeded();
  }

  void _openConnection() {
    if (_hasConnection) {
      _connection!.show();
      return;
    }
    _currentEditingState = _initialEditingState;
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        inputType: widget.keyboardType,
        inputAction: TextInputAction.newline,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    );
    _connection!.setEditingState(_currentEditingState);
    _connection!.show();
  }

  void _closeConnectionIfNeeded() {
    if (!_hasConnection) {
      return;
    }
    _connection!.close();
    _connection = null;
  }

  void _resetEditingState() {
    _currentEditingState = _initialEditingState;
    _connection?.setEditingState(_currentEditingState);
  }

  void _consumeModifiersIfNeeded() {
    if (widget.modifiers.hasModifiers) {
      widget.onModifiersConsumed();
    }
  }

  void _sendSpecialKey(GhosttyKey key) {
    final handled = widget.controller.sendKey(
      key: key,
      mods: widget.modifiers.modsMask,
    );
    _consumeModifiersIfNeeded();
    if (!handled && key == GhosttyKey.GHOSTTY_KEY_ENTER) {
      widget.controller.write('\r');
    }
  }

  void _dispatchInsertedText(String text) {
    if (text.isEmpty) {
      return;
    }

    if (widget.modifiers.hasModifiers) {
      final key = _ghosttyKeyForCharacter(text);
      final mods = widget.modifiers.modsMask;
      _consumeModifiersIfNeeded();
      if (key != null) {
        final handled = widget.controller.sendKey(
          key: key,
          mods: mods,
          utf8Text: text,
          unshiftedCodepoint: text.runes.isEmpty ? 0 : text.runes.first,
        );
        if (handled) {
          return;
        }
      }
    }

    widget.controller.write(text);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _currentEditingState;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentEditingState = value;

    if (!_currentEditingState.composing.isCollapsed) {
      return;
    }

    if (_currentEditingState.text.length < _initialEditingState.text.length) {
      _sendSpecialKey(GhosttyKey.GHOSTTY_KEY_BACKSPACE);
      _resetEditingState();
      return;
    }

    final textDelta = _currentEditingState.text.substring(
      _initialEditingState.text.length,
    );
    if (textDelta.isNotEmpty) {
      _dispatchInsertedText(textDelta);
      _resetEditingState();
    }
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.newline:
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.next:
      case TextInputAction.previous:
      case TextInputAction.search:
      case TextInputAction.send:
        _sendSpecialKey(GhosttyKey.GHOSTTY_KEY_ENTER);
        _resetEditingState();
      default:
        break;
    }
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
}

GhosttyKey? _ghosttyKeyForCharacter(String char) {
  if (char.length != 1) {
    return null;
  }

  switch (char) {
    case 'a':
    case 'A':
      return GhosttyKey.GHOSTTY_KEY_A;
    case 'b':
    case 'B':
      return GhosttyKey.GHOSTTY_KEY_B;
    case 'c':
    case 'C':
      return GhosttyKey.GHOSTTY_KEY_C;
    case 'd':
    case 'D':
      return GhosttyKey.GHOSTTY_KEY_D;
    case 'e':
    case 'E':
      return GhosttyKey.GHOSTTY_KEY_E;
    case 'f':
    case 'F':
      return GhosttyKey.GHOSTTY_KEY_F;
    case 'g':
    case 'G':
      return GhosttyKey.GHOSTTY_KEY_G;
    case 'h':
    case 'H':
      return GhosttyKey.GHOSTTY_KEY_H;
    case 'i':
    case 'I':
      return GhosttyKey.GHOSTTY_KEY_I;
    case 'j':
    case 'J':
      return GhosttyKey.GHOSTTY_KEY_J;
    case 'k':
    case 'K':
      return GhosttyKey.GHOSTTY_KEY_K;
    case 'l':
    case 'L':
      return GhosttyKey.GHOSTTY_KEY_L;
    case 'm':
    case 'M':
      return GhosttyKey.GHOSTTY_KEY_M;
    case 'n':
    case 'N':
      return GhosttyKey.GHOSTTY_KEY_N;
    case 'o':
    case 'O':
      return GhosttyKey.GHOSTTY_KEY_O;
    case 'p':
    case 'P':
      return GhosttyKey.GHOSTTY_KEY_P;
    case 'q':
    case 'Q':
      return GhosttyKey.GHOSTTY_KEY_Q;
    case 'r':
    case 'R':
      return GhosttyKey.GHOSTTY_KEY_R;
    case 's':
    case 'S':
      return GhosttyKey.GHOSTTY_KEY_S;
    case 't':
    case 'T':
      return GhosttyKey.GHOSTTY_KEY_T;
    case 'u':
    case 'U':
      return GhosttyKey.GHOSTTY_KEY_U;
    case 'v':
    case 'V':
      return GhosttyKey.GHOSTTY_KEY_V;
    case 'w':
    case 'W':
      return GhosttyKey.GHOSTTY_KEY_W;
    case 'x':
    case 'X':
      return GhosttyKey.GHOSTTY_KEY_X;
    case 'y':
    case 'Y':
      return GhosttyKey.GHOSTTY_KEY_Y;
    case 'z':
    case 'Z':
      return GhosttyKey.GHOSTTY_KEY_Z;
    case '0':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_0;
    case '1':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_1;
    case '2':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_2;
    case '3':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_3;
    case '4':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_4;
    case '5':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_5;
    case '6':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_6;
    case '7':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_7;
    case '8':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_8;
    case '9':
      return GhosttyKey.GHOSTTY_KEY_DIGIT_9;
    case '-':
    case '_':
      return GhosttyKey.GHOSTTY_KEY_MINUS;
    case '=':
    case '+':
      return GhosttyKey.GHOSTTY_KEY_EQUAL;
    case '[':
    case '{':
      return GhosttyKey.GHOSTTY_KEY_BRACKET_LEFT;
    case ']':
    case '}':
      return GhosttyKey.GHOSTTY_KEY_BRACKET_RIGHT;
    case '\\':
    case '|':
      return GhosttyKey.GHOSTTY_KEY_BACKSLASH;
    case ';':
    case ':':
      return GhosttyKey.GHOSTTY_KEY_SEMICOLON;
    case '\'':
    case '"':
      return GhosttyKey.GHOSTTY_KEY_QUOTE;
    case '`':
    case '~':
      return GhosttyKey.GHOSTTY_KEY_BACKQUOTE;
    case ',':
    case '<':
      return GhosttyKey.GHOSTTY_KEY_COMMA;
    case '.':
    case '>':
      return GhosttyKey.GHOSTTY_KEY_PERIOD;
    case '/':
    case '?':
      return GhosttyKey.GHOSTTY_KEY_SLASH;
    case ' ':
      return GhosttyKey.GHOSTTY_KEY_SPACE;
    default:
      return null;
  }
}
