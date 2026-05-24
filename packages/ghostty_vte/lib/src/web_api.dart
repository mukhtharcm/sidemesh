// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// Result status codes used by the web runtime shims.
enum GhosttyResult {
  GHOSTTY_SUCCESS(0),
  GHOSTTY_OUT_OF_MEMORY(-1),
  GHOSTTY_INVALID_VALUE(-2),
  GHOSTTY_OUT_OF_SPACE(-3),
  GHOSTTY_NO_VALUE(-4);

  const GhosttyResult(this.value);
  final int value;

  static GhosttyResult fromValue(int value) => switch (value) {
    0 => GHOSTTY_SUCCESS,
    -1 => GHOSTTY_OUT_OF_MEMORY,
    -2 => GHOSTTY_INVALID_VALUE,
    -3 => GHOSTTY_OUT_OF_SPACE,
    -4 => GHOSTTY_NO_VALUE,
    _ => throw ArgumentError('Unknown value for GhosttyResult: $value'),
  };
}

/// Build optimization mode.
enum GhosttyOptimizeMode {
  GHOSTTY_OPTIMIZE_DEBUG(0),
  GHOSTTY_OPTIMIZE_RELEASE_SAFE(1),
  GHOSTTY_OPTIMIZE_RELEASE_SMALL(2),
  GHOSTTY_OPTIMIZE_RELEASE_FAST(3);

  const GhosttyOptimizeMode(this.value);
  final int value;

  static GhosttyOptimizeMode fromValue(int value) => switch (value) {
    0 => GHOSTTY_OPTIMIZE_DEBUG,
    1 => GHOSTTY_OPTIMIZE_RELEASE_SAFE,
    2 => GHOSTTY_OPTIMIZE_RELEASE_SMALL,
    3 => GHOSTTY_OPTIMIZE_RELEASE_FAST,
    _ => throw ArgumentError('Unknown value for GhosttyOptimizeMode: $value'),
  };
}

/// OSC command types recognized by the terminal parser runtime.
enum GhosttyOscCommandType {
  GHOSTTY_OSC_COMMAND_INVALID(0),
  GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE(1),
  GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON(2),
  GHOSTTY_OSC_COMMAND_SEMANTIC_PROMPT(3),
  GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS(4),
  GHOSTTY_OSC_COMMAND_REPORT_PWD(5),
  GHOSTTY_OSC_COMMAND_MOUSE_SHAPE(6),
  GHOSTTY_OSC_COMMAND_COLOR_OPERATION(7),
  GHOSTTY_OSC_COMMAND_KITTY_COLOR_PROTOCOL(8),
  GHOSTTY_OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION(9),
  GHOSTTY_OSC_COMMAND_HYPERLINK_START(10),
  GHOSTTY_OSC_COMMAND_HYPERLINK_END(11),
  GHOSTTY_OSC_COMMAND_CONEMU_SLEEP(12),
  GHOSTTY_OSC_COMMAND_CONEMU_SHOW_MESSAGE_BOX(13),
  GHOSTTY_OSC_COMMAND_CONEMU_CHANGE_TAB_TITLE(14),
  GHOSTTY_OSC_COMMAND_CONEMU_PROGRESS_REPORT(15),
  GHOSTTY_OSC_COMMAND_CONEMU_WAIT_INPUT(16),
  GHOSTTY_OSC_COMMAND_CONEMU_GUIMACRO(17),
  GHOSTTY_OSC_COMMAND_CONEMU_RUN_PROCESS(18),
  GHOSTTY_OSC_COMMAND_CONEMU_OUTPUT_ENVIRONMENT_VARIABLE(19),
  GHOSTTY_OSC_COMMAND_CONEMU_XTERM_EMULATION(20),
  GHOSTTY_OSC_COMMAND_CONEMU_COMMENT(21),
  GHOSTTY_OSC_COMMAND_KITTY_TEXT_SIZING(22);

  const GhosttyOscCommandType(this.value);
  final int value;

  static GhosttyOscCommandType fromValue(int value) {
    for (final item in GhosttyOscCommandType.values) {
      if (item.value == value) {
        return item;
      }
    }
    throw ArgumentError('Unknown value for GhosttyOscCommandType: $value');
  }
}

/// OSC payload selectors returned by command helpers.
enum GhosttyOscCommandData {
  GHOSTTY_OSC_DATA_INVALID(0),
  GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR(1);

  const GhosttyOscCommandData(this.value);
  final int value;

  static GhosttyOscCommandData fromValue(int value) => switch (value) {
    0 => GHOSTTY_OSC_DATA_INVALID,
    1 => GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR,
    _ => throw ArgumentError('Unknown value for GhosttyOscCommandData: $value'),
  };
}

/// Tags produced by ANSI SGR parsing.
enum GhosttySgrAttributeTag {
  GHOSTTY_SGR_ATTR_UNSET(0),
  GHOSTTY_SGR_ATTR_UNKNOWN(1),
  GHOSTTY_SGR_ATTR_BOLD(2),
  GHOSTTY_SGR_ATTR_RESET_BOLD(3),
  GHOSTTY_SGR_ATTR_ITALIC(4),
  GHOSTTY_SGR_ATTR_RESET_ITALIC(5),
  GHOSTTY_SGR_ATTR_FAINT(6),
  GHOSTTY_SGR_ATTR_UNDERLINE(7),
  GHOSTTY_SGR_ATTR_UNDERLINE_COLOR(8),
  GHOSTTY_SGR_ATTR_UNDERLINE_COLOR_256(9),
  GHOSTTY_SGR_ATTR_RESET_UNDERLINE_COLOR(10),
  GHOSTTY_SGR_ATTR_OVERLINE(11),
  GHOSTTY_SGR_ATTR_RESET_OVERLINE(12),
  GHOSTTY_SGR_ATTR_BLINK(13),
  GHOSTTY_SGR_ATTR_RESET_BLINK(14),
  GHOSTTY_SGR_ATTR_INVERSE(15),
  GHOSTTY_SGR_ATTR_RESET_INVERSE(16),
  GHOSTTY_SGR_ATTR_INVISIBLE(17),
  GHOSTTY_SGR_ATTR_RESET_INVISIBLE(18),
  GHOSTTY_SGR_ATTR_STRIKETHROUGH(19),
  GHOSTTY_SGR_ATTR_RESET_STRIKETHROUGH(20),
  GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG(21),
  GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG(22),
  GHOSTTY_SGR_ATTR_BG_8(23),
  GHOSTTY_SGR_ATTR_FG_8(24),
  GHOSTTY_SGR_ATTR_RESET_FG(25),
  GHOSTTY_SGR_ATTR_RESET_BG(26),
  GHOSTTY_SGR_ATTR_BRIGHT_BG_8(27),
  GHOSTTY_SGR_ATTR_BRIGHT_FG_8(28),
  GHOSTTY_SGR_ATTR_BG_256(29),
  GHOSTTY_SGR_ATTR_FG_256(30);

  const GhosttySgrAttributeTag(this.value);
  final int value;

  static GhosttySgrAttributeTag fromValue(int value) {
    for (final item in GhosttySgrAttributeTag.values) {
      if (item.value == value) {
        return item;
      }
    }
    throw ArgumentError('Unknown value for GhosttySgrAttributeTag: $value');
  }
}

/// Underline styles in SGR parser output.
enum GhosttySgrUnderline {
  GHOSTTY_SGR_UNDERLINE_NONE(0),
  GHOSTTY_SGR_UNDERLINE_SINGLE(1),
  GHOSTTY_SGR_UNDERLINE_DOUBLE(2),
  GHOSTTY_SGR_UNDERLINE_CURLY(3),
  GHOSTTY_SGR_UNDERLINE_DOTTED(4),
  GHOSTTY_SGR_UNDERLINE_DASHED(5);

  const GhosttySgrUnderline(this.value);
  final int value;

  static GhosttySgrUnderline fromValue(int value) {
    for (final item in GhosttySgrUnderline.values) {
      if (item.value == value) {
        return item;
      }
    }
    throw ArgumentError('Unknown value for GhosttySgrUnderline: $value');
  }
}

/// Focus event types for focus reporting mode (mode 1004).
enum GhosttyFocusEvent {
  GHOSTTY_FOCUS_GAINED(0),
  GHOSTTY_FOCUS_LOST(1);

  const GhosttyFocusEvent(this.value);
  final int value;

  static GhosttyFocusEvent fromValue(int value) => switch (value) {
    0 => GHOSTTY_FOCUS_GAINED,
    1 => GHOSTTY_FOCUS_LOST,
    _ => throw ArgumentError('Unknown value for GhosttyFocusEvent: $value'),
  };
}

/// DECRPM report state values.
enum GhosttyModeReportState {
  GHOSTTY_MODE_REPORT_NOT_RECOGNIZED(0),
  GHOSTTY_MODE_REPORT_SET(1),
  GHOSTTY_MODE_REPORT_RESET(2),
  GHOSTTY_MODE_REPORT_PERMANENTLY_SET(3),
  GHOSTTY_MODE_REPORT_PERMANENTLY_RESET(4);

  const GhosttyModeReportState(this.value);
  final int value;

  static GhosttyModeReportState fromValue(int value) => switch (value) {
    0 => GHOSTTY_MODE_REPORT_NOT_RECOGNIZED,
    1 => GHOSTTY_MODE_REPORT_SET,
    2 => GHOSTTY_MODE_REPORT_RESET,
    3 => GHOSTTY_MODE_REPORT_PERMANENTLY_SET,
    4 => GHOSTTY_MODE_REPORT_PERMANENTLY_RESET,
    _ => throw ArgumentError(
      'Unknown value for GhosttyModeReportState: $value',
    ),
  };
}

/// Cell content tag.
enum GhosttyCellContentTag {
  GHOSTTY_CELL_CONTENT_CODEPOINT(0),
  GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME(1),
  GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE(2),
  GHOSTTY_CELL_CONTENT_BG_COLOR_RGB(3);

  const GhosttyCellContentTag(this.value);
  final int value;

  static GhosttyCellContentTag fromValue(int value) => switch (value) {
    0 => GHOSTTY_CELL_CONTENT_CODEPOINT,
    1 => GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME,
    2 => GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE,
    3 => GHOSTTY_CELL_CONTENT_BG_COLOR_RGB,
    _ => throw ArgumentError('Unknown value for GhosttyCellContentTag: $value'),
  };
}

/// Cell wide property.
enum GhosttyCellWide {
  GHOSTTY_CELL_WIDE_NARROW(0),
  GHOSTTY_CELL_WIDE_WIDE(1),
  GHOSTTY_CELL_WIDE_SPACER_TAIL(2),
  GHOSTTY_CELL_WIDE_SPACER_HEAD(3);

  const GhosttyCellWide(this.value);
  final int value;

  static GhosttyCellWide fromValue(int value) => switch (value) {
    0 => GHOSTTY_CELL_WIDE_NARROW,
    1 => GHOSTTY_CELL_WIDE_WIDE,
    2 => GHOSTTY_CELL_WIDE_SPACER_TAIL,
    3 => GHOSTTY_CELL_WIDE_SPACER_HEAD,
    _ => throw ArgumentError('Unknown value for GhosttyCellWide: $value'),
  };
}

/// Semantic content type of a cell.
enum GhosttyCellSemanticContent {
  GHOSTTY_CELL_SEMANTIC_OUTPUT(0),
  GHOSTTY_CELL_SEMANTIC_INPUT(1),
  GHOSTTY_CELL_SEMANTIC_PROMPT(2);

  const GhosttyCellSemanticContent(this.value);
  final int value;

  static GhosttyCellSemanticContent fromValue(int value) => switch (value) {
    0 => GHOSTTY_CELL_SEMANTIC_OUTPUT,
    1 => GHOSTTY_CELL_SEMANTIC_INPUT,
    2 => GHOSTTY_CELL_SEMANTIC_PROMPT,
    _ => throw ArgumentError(
      'Unknown value for GhosttyCellSemanticContent: $value',
    ),
  };
}

/// Row semantic prompt state.
enum GhosttyRowSemanticPrompt {
  GHOSTTY_ROW_SEMANTIC_NONE(0),
  GHOSTTY_ROW_SEMANTIC_PROMPT(1),
  GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION(2);

  const GhosttyRowSemanticPrompt(this.value);
  final int value;

  static GhosttyRowSemanticPrompt fromValue(int value) => switch (value) {
    0 => GHOSTTY_ROW_SEMANTIC_NONE,
    1 => GHOSTTY_ROW_SEMANTIC_PROMPT,
    2 => GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION,
    _ => throw ArgumentError(
      'Unknown value for GhosttyRowSemanticPrompt: $value',
    ),
  };
}

/// Style color tags.
enum GhosttyStyleColorTag {
  GHOSTTY_STYLE_COLOR_NONE(0),
  GHOSTTY_STYLE_COLOR_PALETTE(1),
  GHOSTTY_STYLE_COLOR_RGB(2);

  const GhosttyStyleColorTag(this.value);
  final int value;

  static GhosttyStyleColorTag fromValue(int value) => switch (value) {
    0 => GHOSTTY_STYLE_COLOR_NONE,
    1 => GHOSTTY_STYLE_COLOR_PALETTE,
    2 => GHOSTTY_STYLE_COLOR_RGB,
    _ => throw ArgumentError('Unknown value for GhosttyStyleColorTag: $value'),
  };
}

/// Point reference tag.
enum GhosttyPointTag {
  GHOSTTY_POINT_TAG_ACTIVE(0),
  GHOSTTY_POINT_TAG_VIEWPORT(1),
  GHOSTTY_POINT_TAG_SCREEN(2),
  GHOSTTY_POINT_TAG_HISTORY(3);

  const GhosttyPointTag(this.value);
  final int value;

  static GhosttyPointTag fromValue(int value) => switch (value) {
    0 => GHOSTTY_POINT_TAG_ACTIVE,
    1 => GHOSTTY_POINT_TAG_VIEWPORT,
    2 => GHOSTTY_POINT_TAG_SCREEN,
    3 => GHOSTTY_POINT_TAG_HISTORY,
    _ => throw ArgumentError('Unknown value for GhosttyPointTag: $value'),
  };
}

/// Terminal screen identifier.
enum GhosttyTerminalScreen {
  GHOSTTY_TERMINAL_SCREEN_PRIMARY(0),
  GHOSTTY_TERMINAL_SCREEN_ALTERNATE(1);

  const GhosttyTerminalScreen(this.value);
  final int value;

  static GhosttyTerminalScreen fromValue(int value) => switch (value) {
    0 => GHOSTTY_TERMINAL_SCREEN_PRIMARY,
    1 => GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
    _ => throw ArgumentError('Unknown value for GhosttyTerminalScreen: $value'),
  };
}

/// Dirty state of a render state after update.
enum GhosttyRenderStateDirty {
  GHOSTTY_RENDER_STATE_DIRTY_FALSE(0),
  GHOSTTY_RENDER_STATE_DIRTY_PARTIAL(1),
  GHOSTTY_RENDER_STATE_DIRTY_FULL(2);

  const GhosttyRenderStateDirty(this.value);
  final int value;

  static GhosttyRenderStateDirty fromValue(int value) => switch (value) {
    0 => GHOSTTY_RENDER_STATE_DIRTY_FALSE,
    1 => GHOSTTY_RENDER_STATE_DIRTY_PARTIAL,
    2 => GHOSTTY_RENDER_STATE_DIRTY_FULL,
    _ => throw ArgumentError(
      'Unknown value for GhosttyRenderStateDirty: $value',
    ),
  };
}

/// Visual style of the cursor.
enum GhosttyRenderStateCursorVisualStyle {
  GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR(0),
  GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK(1),
  GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE(2),
  GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW(3);

  const GhosttyRenderStateCursorVisualStyle(this.value);
  final int value;

  static GhosttyRenderStateCursorVisualStyle fromValue(int value) =>
      switch (value) {
        0 => GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR,
        1 => GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK,
        2 => GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE,
        3 => GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW,
        _ => throw ArgumentError(
          'Unknown value for GhosttyRenderStateCursorVisualStyle: $value',
        ),
      };
}

/// Mouse event action type.
enum GhosttyMouseAction {
  GHOSTTY_MOUSE_ACTION_PRESS(0),
  GHOSTTY_MOUSE_ACTION_RELEASE(1),
  GHOSTTY_MOUSE_ACTION_MOTION(2);

  const GhosttyMouseAction(this.value);
  final int value;

  static GhosttyMouseAction fromValue(int value) => switch (value) {
    0 => GHOSTTY_MOUSE_ACTION_PRESS,
    1 => GHOSTTY_MOUSE_ACTION_RELEASE,
    2 => GHOSTTY_MOUSE_ACTION_MOTION,
    _ => throw ArgumentError('Unknown value for GhosttyMouseAction: $value'),
  };
}

/// Mouse button identity.
enum GhosttyMouseButton {
  GHOSTTY_MOUSE_BUTTON_UNKNOWN(0),
  GHOSTTY_MOUSE_BUTTON_LEFT(1),
  GHOSTTY_MOUSE_BUTTON_RIGHT(2),
  GHOSTTY_MOUSE_BUTTON_MIDDLE(3),
  GHOSTTY_MOUSE_BUTTON_FOUR(4),
  GHOSTTY_MOUSE_BUTTON_FIVE(5),
  GHOSTTY_MOUSE_BUTTON_SIX(6),
  GHOSTTY_MOUSE_BUTTON_SEVEN(7),
  GHOSTTY_MOUSE_BUTTON_EIGHT(8),
  GHOSTTY_MOUSE_BUTTON_NINE(9),
  GHOSTTY_MOUSE_BUTTON_TEN(10),
  GHOSTTY_MOUSE_BUTTON_ELEVEN(11);

  const GhosttyMouseButton(this.value);
  final int value;

  static GhosttyMouseButton fromValue(int value) => switch (value) {
    0 => GHOSTTY_MOUSE_BUTTON_UNKNOWN,
    1 => GHOSTTY_MOUSE_BUTTON_LEFT,
    2 => GHOSTTY_MOUSE_BUTTON_RIGHT,
    3 => GHOSTTY_MOUSE_BUTTON_MIDDLE,
    4 => GHOSTTY_MOUSE_BUTTON_FOUR,
    5 => GHOSTTY_MOUSE_BUTTON_FIVE,
    6 => GHOSTTY_MOUSE_BUTTON_SIX,
    7 => GHOSTTY_MOUSE_BUTTON_SEVEN,
    8 => GHOSTTY_MOUSE_BUTTON_EIGHT,
    9 => GHOSTTY_MOUSE_BUTTON_NINE,
    10 => GHOSTTY_MOUSE_BUTTON_TEN,
    11 => GHOSTTY_MOUSE_BUTTON_ELEVEN,
    _ => throw ArgumentError('Unknown value for GhosttyMouseButton: $value'),
  };
}

/// Mouse tracking mode.
enum GhosttyMouseTrackingMode {
  GHOSTTY_MOUSE_TRACKING_NONE(0),
  GHOSTTY_MOUSE_TRACKING_X10(1),
  GHOSTTY_MOUSE_TRACKING_NORMAL(2),
  GHOSTTY_MOUSE_TRACKING_BUTTON(3),
  GHOSTTY_MOUSE_TRACKING_ANY(4);

  const GhosttyMouseTrackingMode(this.value);
  final int value;

  static GhosttyMouseTrackingMode fromValue(int value) => switch (value) {
    0 => GHOSTTY_MOUSE_TRACKING_NONE,
    1 => GHOSTTY_MOUSE_TRACKING_X10,
    2 => GHOSTTY_MOUSE_TRACKING_NORMAL,
    3 => GHOSTTY_MOUSE_TRACKING_BUTTON,
    4 => GHOSTTY_MOUSE_TRACKING_ANY,
    _ => throw ArgumentError(
      'Unknown value for GhosttyMouseTrackingMode: $value',
    ),
  };
}

/// Mouse output format.
enum GhosttyMouseFormat {
  GHOSTTY_MOUSE_FORMAT_X10(0),
  GHOSTTY_MOUSE_FORMAT_UTF8(1),
  GHOSTTY_MOUSE_FORMAT_SGR(2),
  GHOSTTY_MOUSE_FORMAT_URXVT(3),
  GHOSTTY_MOUSE_FORMAT_SGR_PIXELS(4);

  const GhosttyMouseFormat(this.value);
  final int value;

  static GhosttyMouseFormat fromValue(int value) => switch (value) {
    0 => GHOSTTY_MOUSE_FORMAT_X10,
    1 => GHOSTTY_MOUSE_FORMAT_UTF8,
    2 => GHOSTTY_MOUSE_FORMAT_SGR,
    3 => GHOSTTY_MOUSE_FORMAT_URXVT,
    4 => GHOSTTY_MOUSE_FORMAT_SGR_PIXELS,
    _ => throw ArgumentError('Unknown value for GhosttyMouseFormat: $value'),
  };
}

/// Size report style.
enum GhosttySizeReportStyle {
  GHOSTTY_SIZE_REPORT_MODE_2048(0),
  GHOSTTY_SIZE_REPORT_CSI_14_T(1),
  GHOSTTY_SIZE_REPORT_CSI_16_T(2),
  GHOSTTY_SIZE_REPORT_CSI_18_T(3);

  const GhosttySizeReportStyle(this.value);
  final int value;

  static GhosttySizeReportStyle fromValue(int value) => switch (value) {
    0 => GHOSTTY_SIZE_REPORT_MODE_2048,
    1 => GHOSTTY_SIZE_REPORT_CSI_14_T,
    2 => GHOSTTY_SIZE_REPORT_CSI_16_T,
    3 => GHOSTTY_SIZE_REPORT_CSI_18_T,
    _ => throw ArgumentError(
      'Unknown value for GhosttySizeReportStyle: $value',
    ),
  };
}

/// Key event action enum used by the key encoder.
enum GhosttyKeyAction {
  GHOSTTY_KEY_ACTION_RELEASE(0),
  GHOSTTY_KEY_ACTION_PRESS(1),
  GHOSTTY_KEY_ACTION_REPEAT(2);

  const GhosttyKeyAction(this.value);
  final int value;

  static GhosttyKeyAction fromValue(int value) => switch (value) {
    0 => GHOSTTY_KEY_ACTION_RELEASE,
    1 => GHOSTTY_KEY_ACTION_PRESS,
    2 => GHOSTTY_KEY_ACTION_REPEAT,
    _ => throw ArgumentError('Unknown value for GhosttyKeyAction: $value'),
  };
}

/// Stable keyboard key identifiers for cross-platform terminal input.
enum GhosttyKey {
  GHOSTTY_KEY_UNIDENTIFIED(0),
  GHOSTTY_KEY_BACKQUOTE(1),
  GHOSTTY_KEY_BACKSLASH(2),
  GHOSTTY_KEY_BRACKET_LEFT(3),
  GHOSTTY_KEY_BRACKET_RIGHT(4),
  GHOSTTY_KEY_COMMA(5),
  GHOSTTY_KEY_DIGIT_0(6),
  GHOSTTY_KEY_DIGIT_1(7),
  GHOSTTY_KEY_DIGIT_2(8),
  GHOSTTY_KEY_DIGIT_3(9),
  GHOSTTY_KEY_DIGIT_4(10),
  GHOSTTY_KEY_DIGIT_5(11),
  GHOSTTY_KEY_DIGIT_6(12),
  GHOSTTY_KEY_DIGIT_7(13),
  GHOSTTY_KEY_DIGIT_8(14),
  GHOSTTY_KEY_DIGIT_9(15),
  GHOSTTY_KEY_EQUAL(16),
  GHOSTTY_KEY_A(20),
  GHOSTTY_KEY_B(21),
  GHOSTTY_KEY_C(22),
  GHOSTTY_KEY_D(23),
  GHOSTTY_KEY_E(24),
  GHOSTTY_KEY_F(25),
  GHOSTTY_KEY_G(26),
  GHOSTTY_KEY_H(27),
  GHOSTTY_KEY_I(28),
  GHOSTTY_KEY_J(29),
  GHOSTTY_KEY_K(30),
  GHOSTTY_KEY_L(31),
  GHOSTTY_KEY_M(32),
  GHOSTTY_KEY_N(33),
  GHOSTTY_KEY_O(34),
  GHOSTTY_KEY_P(35),
  GHOSTTY_KEY_Q(36),
  GHOSTTY_KEY_R(37),
  GHOSTTY_KEY_S(38),
  GHOSTTY_KEY_T(39),
  GHOSTTY_KEY_U(40),
  GHOSTTY_KEY_V(41),
  GHOSTTY_KEY_W(42),
  GHOSTTY_KEY_X(43),
  GHOSTTY_KEY_Y(44),
  GHOSTTY_KEY_Z(45),
  GHOSTTY_KEY_MINUS(46),
  GHOSTTY_KEY_PERIOD(47),
  GHOSTTY_KEY_QUOTE(48),
  GHOSTTY_KEY_SEMICOLON(49),
  GHOSTTY_KEY_SLASH(50),
  GHOSTTY_KEY_BACKSPACE(53),
  GHOSTTY_KEY_ENTER(58),
  GHOSTTY_KEY_SPACE(63),
  GHOSTTY_KEY_TAB(64),
  GHOSTTY_KEY_DELETE(68),
  GHOSTTY_KEY_END(69),
  GHOSTTY_KEY_HOME(71),
  GHOSTTY_KEY_INSERT(72),
  GHOSTTY_KEY_PAGE_DOWN(73),
  GHOSTTY_KEY_PAGE_UP(74),
  GHOSTTY_KEY_ARROW_DOWN(75),
  GHOSTTY_KEY_ARROW_LEFT(76),
  GHOSTTY_KEY_ARROW_RIGHT(77),
  GHOSTTY_KEY_ARROW_UP(78),
  GHOSTTY_KEY_ESCAPE(120),
  GHOSTTY_KEY_F1(121),
  GHOSTTY_KEY_F2(122),
  GHOSTTY_KEY_F3(123),
  GHOSTTY_KEY_F4(124),
  GHOSTTY_KEY_F5(125),
  GHOSTTY_KEY_F6(126),
  GHOSTTY_KEY_F7(127),
  GHOSTTY_KEY_F8(128),
  GHOSTTY_KEY_F9(129),
  GHOSTTY_KEY_F10(130),
  GHOSTTY_KEY_F11(131),
  GHOSTTY_KEY_F12(132);

  const GhosttyKey(this.value);
  final int value;

  static GhosttyKey fromValue(int value) {
    for (final item in GhosttyKey.values) {
      if (item.value == value) {
        return item;
      }
    }
    throw ArgumentError('Unknown value for GhosttyKey: $value');
  }
}

/// Option handling for Alt/meta key behavior.
enum GhosttyOptionAsAlt {
  GHOSTTY_OPTION_AS_ALT_FALSE(0),
  GHOSTTY_OPTION_AS_ALT_TRUE(1),
  GHOSTTY_OPTION_AS_ALT_LEFT(2),
  GHOSTTY_OPTION_AS_ALT_RIGHT(3);

  const GhosttyOptionAsAlt(this.value);
  final int value;
}

/// Output format emitted by a terminal formatter.
enum GhosttyFormatterFormat {
  GHOSTTY_FORMATTER_FORMAT_PLAIN(0),
  GHOSTTY_FORMATTER_FORMAT_VT(1),
  GHOSTTY_FORMATTER_FORMAT_HTML(2);

  const GhosttyFormatterFormat(this.value);
  final int value;
}

/// Key encoder feature flags.
enum GhosttyKeyEncoderOption {
  GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION(0),
  GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION(1),
  GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK(2),
  GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX(3),
  GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2(4),
  GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS(5),
  GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT(6);

  const GhosttyKeyEncoderOption(this.value);
  final int value;
}

/// Named ANSI color constants.
const int GHOSTTY_COLOR_NAMED_BLACK = 0;
const int GHOSTTY_COLOR_NAMED_RED = 1;
const int GHOSTTY_COLOR_NAMED_GREEN = 2;
const int GHOSTTY_COLOR_NAMED_YELLOW = 3;
const int GHOSTTY_COLOR_NAMED_BLUE = 4;
const int GHOSTTY_COLOR_NAMED_MAGENTA = 5;
const int GHOSTTY_COLOR_NAMED_CYAN = 6;
const int GHOSTTY_COLOR_NAMED_WHITE = 7;
const int GHOSTTY_COLOR_NAMED_BRIGHT_BLACK = 8;
const int GHOSTTY_COLOR_NAMED_BRIGHT_RED = 9;
const int GHOSTTY_COLOR_NAMED_BRIGHT_GREEN = 10;
const int GHOSTTY_COLOR_NAMED_BRIGHT_YELLOW = 11;
const int GHOSTTY_COLOR_NAMED_BRIGHT_BLUE = 12;
const int GHOSTTY_COLOR_NAMED_BRIGHT_MAGENTA = 13;
const int GHOSTTY_COLOR_NAMED_BRIGHT_CYAN = 14;
const int GHOSTTY_COLOR_NAMED_BRIGHT_WHITE = 15;

/// Keyboard modifier mask constants for key events.
const int GHOSTTY_MODS_SHIFT = 1;
const int GHOSTTY_MODS_CTRL = 2;
const int GHOSTTY_MODS_ALT = 4;
const int GHOSTTY_MODS_SUPER = 8;
const int GHOSTTY_MODS_CAPS_LOCK = 16;
const int GHOSTTY_MODS_NUM_LOCK = 32;
const int GHOSTTY_MODS_SHIFT_SIDE = 64;
const int GHOSTTY_MODS_CTRL_SIDE = 128;
const int GHOSTTY_MODS_ALT_SIDE = 256;
const int GHOSTTY_MODS_SUPER_SIDE = 512;

/// Kitty keyboard feature mask constants.
const int GHOSTTY_KITTY_KEY_DISABLED = 0;
const int GHOSTTY_KITTY_KEY_DISAMBIGUATE = 1;
const int GHOSTTY_KITTY_KEY_REPORT_EVENTS = 2;
const int GHOSTTY_KITTY_KEY_REPORT_ALTERNATES = 4;
const int GHOSTTY_KITTY_KEY_REPORT_ALL = 8;
const int GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED = 16;
const int GHOSTTY_KITTY_KEY_ALL = 31;

final class GhosttyVtWasm {
  const GhosttyVtWasm._();

  static _GhosttyWasmRuntime? _runtime;

  static bool get isInitialized => _runtime != null;

  static Future<void> initializeFromBytes(Uint8List wasmBytes) async {
    if (_runtime != null) {
      return;
    }
    _runtime = await _GhosttyWasmRuntime.fromBytes(wasmBytes);
  }
}

final class _GhosttyWasmRuntime {
  _GhosttyWasmRuntime(this._exports, this._memory);

  final JSObject _exports;
  final JSObject _memory;

  static Future<_GhosttyWasmRuntime> fromBytes(Uint8List wasmBytes) async {
    final imports =
        <String, Object?>{
              'env': <String, Object?>{
                // Ghostty imports this symbol for logging in wasm builds.
                'log': ((JSAny? _, JSAny? _) {}).toJS,
              },
            }.jsify()!
            as JSObject;

    final webAssembly = globalContext['WebAssembly']! as JSObject;
    final instantiate = webAssembly['instantiate']! as JSFunction;
    final result =
        await (instantiate.callAsFunction(webAssembly, wasmBytes.toJS, imports)!
                as JSPromise<JSAny?>)
            .toDart;
    final resultObject = result! as JSObject;
    final instance = resultObject['instance']! as JSObject;
    final exports = instance['exports']! as JSObject;
    final memory = exports['memory']! as JSObject;
    return _GhosttyWasmRuntime(exports, memory);
  }

  int callInt(String fn, [List<Object?> args = const <Object?>[]]) {
    final result = _exports.callMethodVarArgs<JSAny?>(
      fn.toJS,
      args.map(_dartToJSAny).toList(growable: false),
    );
    if (result == null) {
      return 0;
    }
    final dartResult = result.dartify();
    if (dartResult is num) {
      return dartResult.toInt();
    }
    if (dartResult is bool) {
      return dartResult ? 1 : 0;
    }
    throw StateError('Unexpected return type from $fn');
  }

  bool callBool(String fn, [List<Object?> args = const <Object?>[]]) {
    return callInt(fn, args) != 0;
  }

  ByteBuffer get _buffer => (_memory['buffer']! as JSArrayBuffer).toDart;

  ByteData get _data => ByteData.view(_buffer);

  Uint8List u8View(int ptr, int len) => Uint8List.view(_buffer, ptr, len);

  int readPtr(int ptr) => _data.getUint32(ptr, Endian.little);

  int readU8(int ptr) => _data.getUint8(ptr);

  int readU16(int ptr) => _data.getUint16(ptr, Endian.little);

  int readUsize(int ptr) => _data.getUint32(ptr, Endian.little);

  int readI32(int ptr) => _data.getInt32(ptr, Endian.little);

  void writeU8(int ptr, int value) {
    _data.setUint8(ptr, value & 0xFF);
  }

  void writeU16(int ptr, int value) {
    _data.setUint16(ptr, value & 0xFFFF, Endian.little);
  }

  void writeU32(int ptr, int value) {
    _data.setUint32(ptr, value, Endian.little);
  }

  void writeI32(int ptr, int value) {
    _data.setInt32(ptr, value, Endian.little);
  }

  String readCString(int ptr) {
    if (ptr == 0) {
      return '';
    }
    final bytes = <int>[];
    var cursor = ptr;
    while (true) {
      final b = readU8(cursor++);
      if (b == 0) {
        break;
      }
      bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  List<int> readU16List(int ptr, int len) {
    if (ptr == 0 || len == 0) {
      return const <int>[];
    }
    final out = List<int>.filled(len, 0, growable: false);
    for (var i = 0; i < len; i++) {
      out[i] = readU16(ptr + (i * 2));
    }
    return out;
  }

  int allocOpaque() => callInt('ghostty_wasm_alloc_opaque');

  void freeOpaque(int ptr) =>
      callInt('ghostty_wasm_free_opaque', <Object>[ptr]);

  int allocU8Array(int len) =>
      callInt('ghostty_wasm_alloc_u8_array', <Object>[len]);

  void freeU8Array(int ptr, int len) =>
      callInt('ghostty_wasm_free_u8_array', <Object>[ptr, len]);

  int allocU16Array(int len) =>
      callInt('ghostty_wasm_alloc_u16_array', <Object>[len]);

  void freeU16Array(int ptr, int len) =>
      callInt('ghostty_wasm_free_u16_array', <Object>[ptr, len]);

  int allocU8() => callInt('ghostty_wasm_alloc_u8');

  void freeU8(int ptr) => callInt('ghostty_wasm_free_u8', <Object>[ptr]);

  int allocUsize() => callInt('ghostty_wasm_alloc_usize');

  void freeUsize(int ptr) => callInt('ghostty_wasm_free_usize', <Object>[ptr]);
}

_GhosttyWasmRuntime? _runtime() => GhosttyVtWasm._runtime;

JSAny? _dartToJSAny(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is bool) {
    return value.toJS;
  }
  if (value is num) {
    return value.toJS;
  }
  if (value is String) {
    return value.toJS;
  }
  if (value is ByteBuffer) {
    return value.toJS;
  }
  if (value is Uint8List) {
    return value.toJS;
  }
  throw ArgumentError('Unsupported JS argument type: ${value.runtimeType}');
}

final class GhosttyVtError implements Exception {
  GhosttyVtError(this.operation, this.result);

  final String operation;
  final GhosttyResult result;

  @override
  String toString() => 'GhosttyVtError(operation: $operation, result: $result)';
}

void _checkResult(int result, String operation) {
  final mapped = GhosttyResult.fromValue(result);
  if (mapped != GhosttyResult.GHOSTTY_SUCCESS) {
    throw GhosttyVtError(operation, mapped);
  }
}

const int _ghosttyTerminalOptionsSize = 8;
const int _ghosttyFormatterScreenExtraSize = 12;
const int _ghosttyFormatterTerminalExtraSize = 24;
const int _ghosttyFormatterTerminalOptionsSize = 36;
const int _ghosttyTerminalScrollViewportSize = 24;
const int _ghosttyStringSize = 8;
const int _ghosttyColorRgbSize = 3;
const int _ghosttyColorPaletteLength = 256;
const int _ghosttyColorPaletteSize =
    _ghosttyColorRgbSize * _ghosttyColorPaletteLength;

const int _ghosttyBuildInfoSimd = 1;
const int _ghosttyBuildInfoKittyGraphics = 2;
const int _ghosttyBuildInfoTmuxControlMode = 3;
const int _ghosttyBuildInfoOptimize = 4;
const int _ghosttyBuildInfoVersionString = 5;
const int _ghosttyBuildInfoVersionMajor = 6;
const int _ghosttyBuildInfoVersionMinor = 7;
const int _ghosttyBuildInfoVersionPatch = 8;
const int _ghosttyBuildInfoVersionBuild = 9;

const int _ghosttyTerminalOptColorForeground = 11;
const int _ghosttyTerminalOptColorBackground = 12;
const int _ghosttyTerminalOptColorCursor = 13;
const int _ghosttyTerminalOptColorPalette = 14;

const int _ghosttyTerminalDataColorForeground = 18;
const int _ghosttyTerminalDataColorBackground = 19;
const int _ghosttyTerminalDataColorCursor = 20;
const int _ghosttyTerminalDataColorPalette = 21;
const int _ghosttyTerminalDataColorForegroundDefault = 22;
const int _ghosttyTerminalDataColorBackgroundDefault = 23;
const int _ghosttyTerminalDataColorCursorDefault = 24;
const int _ghosttyTerminalDataColorPaletteDefault = 25;

int _checkPositiveUint16(int value, String name) {
  if (value < 1 || value > 0xFFFF) {
    throw RangeError.range(value, 1, 0xFFFF, name);
  }
  return value;
}

int _checkNonNegative(int value, String name) {
  if (value < 0) {
    throw RangeError.range(value, 0, null, name);
  }
  return value;
}

_GhosttyWasmRuntime _requireTerminalRuntime(String member) {
  final rt = _runtime();
  if (rt == null) {
    throw StateError(
      '$member requires GhosttyVtWasm.initializeFromBytes() on web.',
    );
  }
  return rt;
}

int _allocU8ArrayOrThrow(_GhosttyWasmRuntime rt, int len, String operation) {
  if (len == 0) {
    return 0;
  }
  final ptr = rt.allocU8Array(len);
  if (ptr == 0) {
    throw GhosttyVtError(operation, GhosttyResult.GHOSTTY_OUT_OF_MEMORY);
  }
  rt.u8View(ptr, len).fillRange(0, len, 0);
  return ptr;
}

int _allocOpaqueOrThrow(_GhosttyWasmRuntime rt, String operation) {
  final ptr = rt.allocOpaque();
  if (ptr == 0) {
    throw GhosttyVtError(operation, GhosttyResult.GHOSTTY_OUT_OF_MEMORY);
  }
  return ptr;
}

VtRgbColor _readRgb(_GhosttyWasmRuntime rt, int ptr) {
  return VtRgbColor(rt.readU8(ptr), rt.readU8(ptr + 1), rt.readU8(ptr + 2));
}

void _writeRgb(_GhosttyWasmRuntime rt, int ptr, VtRgbColor value) {
  rt
    ..writeU8(ptr, value.r)
    ..writeU8(ptr + 1, value.g)
    ..writeU8(ptr + 2, value.b);
}

List<VtRgbColor> _readPalette(_GhosttyWasmRuntime rt, int ptr) {
  return List<VtRgbColor>.unmodifiable(
    List<VtRgbColor>.generate(
      _ghosttyColorPaletteLength,
      (index) => _readRgb(rt, ptr + (index * _ghosttyColorRgbSize)),
    ),
  );
}

String _readGhosttyString(_GhosttyWasmRuntime rt, int ptr) {
  final strPtr = rt.readPtr(ptr);
  final len = rt.readUsize(ptr + 4);
  if (strPtr == 0 || len == 0) {
    return '';
  }
  return utf8.decode(rt.u8View(strPtr, len), allowMalformed: true);
}

void _writeBoolByte(_GhosttyWasmRuntime rt, int ptr, int offset, bool value) {
  rt.writeU8(ptr + offset, value ? 1 : 0);
}

void _writeTerminalOptions(
  _GhosttyWasmRuntime rt,
  int ptr, {
  required int cols,
  required int rows,
  required int maxScrollback,
}) {
  rt.writeU16(ptr, _checkPositiveUint16(cols, 'cols'));
  rt.writeU16(ptr + 2, _checkPositiveUint16(rows, 'rows'));
  rt.writeU32(ptr + 4, _checkNonNegative(maxScrollback, 'maxScrollback'));
}

void _writeFormatterTerminalOptions(
  _GhosttyWasmRuntime rt,
  int ptr,
  VtFormatterTerminalOptions options,
) {
  final screen = options.extra.screen;
  rt.writeU32(ptr, _ghosttyFormatterTerminalOptionsSize);
  rt.writeU32(ptr + 4, options.emit.value);
  _writeBoolByte(rt, ptr, 8, options.unwrap);
  _writeBoolByte(rt, ptr, 9, options.trim);
  rt.writeU32(ptr + 12, _ghosttyFormatterTerminalExtraSize);
  _writeBoolByte(rt, ptr, 16, options.extra.palette);
  _writeBoolByte(rt, ptr, 17, options.extra.modes);
  _writeBoolByte(rt, ptr, 18, options.extra.scrollingRegion);
  _writeBoolByte(rt, ptr, 19, options.extra.tabstops);
  _writeBoolByte(rt, ptr, 20, options.extra.pwd);
  _writeBoolByte(rt, ptr, 21, options.extra.keyboard);
  rt.writeU32(ptr + 24, _ghosttyFormatterScreenExtraSize);
  _writeBoolByte(rt, ptr, 28, screen.cursor);
  _writeBoolByte(rt, ptr, 29, screen.style);
  _writeBoolByte(rt, ptr, 30, screen.hyperlink);
  _writeBoolByte(rt, ptr, 31, screen.protection);
  _writeBoolByte(rt, ptr, 32, screen.kittyKeyboard);
  _writeBoolByte(rt, ptr, 33, screen.charsets);
}

final class GhosttyModsMask {
  const GhosttyModsMask._();

  static const int shift = GHOSTTY_MODS_SHIFT;
  static const int ctrl = GHOSTTY_MODS_CTRL;
  static const int alt = GHOSTTY_MODS_ALT;
  static const int superKey = GHOSTTY_MODS_SUPER;
  static const int capsLock = GHOSTTY_MODS_CAPS_LOCK;
  static const int numLock = GHOSTTY_MODS_NUM_LOCK;
  static const int shiftSide = GHOSTTY_MODS_SHIFT_SIDE;
  static const int ctrlSide = GHOSTTY_MODS_CTRL_SIDE;
  static const int altSide = GHOSTTY_MODS_ALT_SIDE;
  static const int superSide = GHOSTTY_MODS_SUPER_SIDE;
}

final class GhosttyKittyFlags {
  const GhosttyKittyFlags._();

  static const int disabled = GHOSTTY_KITTY_KEY_DISABLED;
  static const int disambiguate = GHOSTTY_KITTY_KEY_DISAMBIGUATE;
  static const int reportEvents = GHOSTTY_KITTY_KEY_REPORT_EVENTS;
  static const int reportAlternates = GHOSTTY_KITTY_KEY_REPORT_ALTERNATES;
  static const int reportAll = GHOSTTY_KITTY_KEY_REPORT_ALL;
  static const int reportAssociated = GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED;
  static const int all = GHOSTTY_KITTY_KEY_ALL;
}

final class GhosttyNamedColor {
  const GhosttyNamedColor._();

  static const int black = GHOSTTY_COLOR_NAMED_BLACK;
  static const int red = GHOSTTY_COLOR_NAMED_RED;
  static const int green = GHOSTTY_COLOR_NAMED_GREEN;
  static const int yellow = GHOSTTY_COLOR_NAMED_YELLOW;
  static const int blue = GHOSTTY_COLOR_NAMED_BLUE;
  static const int magenta = GHOSTTY_COLOR_NAMED_MAGENTA;
  static const int cyan = GHOSTTY_COLOR_NAMED_CYAN;
  static const int white = GHOSTTY_COLOR_NAMED_WHITE;
  static const int brightBlack = GHOSTTY_COLOR_NAMED_BRIGHT_BLACK;
  static const int brightRed = GHOSTTY_COLOR_NAMED_BRIGHT_RED;
  static const int brightGreen = GHOSTTY_COLOR_NAMED_BRIGHT_GREEN;
  static const int brightYellow = GHOSTTY_COLOR_NAMED_BRIGHT_YELLOW;
  static const int brightBlue = GHOSTTY_COLOR_NAMED_BRIGHT_BLUE;
  static const int brightMagenta = GHOSTTY_COLOR_NAMED_BRIGHT_MAGENTA;
  static const int brightCyan = GHOSTTY_COLOR_NAMED_BRIGHT_CYAN;
  static const int brightWhite = GHOSTTY_COLOR_NAMED_BRIGHT_WHITE;
}

final class VtRgbColor {
  const VtRgbColor(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  @override
  String toString() => 'VtRgbColor(r: $r, g: $g, b: $b)';
}

/// Compile-time build metadata for the loaded libghostty-vt library.
final class VtBuildInfo {
  const VtBuildInfo({
    required this.simd,
    required this.kittyGraphics,
    required this.tmuxControlMode,
    required this.optimize,
    required this.versionString,
    required this.versionMajor,
    required this.versionMinor,
    required this.versionPatch,
    required this.versionBuild,
  });

  final bool simd;
  final bool kittyGraphics;
  final bool tmuxControlMode;
  final GhosttyOptimizeMode optimize;
  final String versionString;
  final int versionMajor;
  final int versionMinor;
  final int versionPatch;
  final String versionBuild;

  /// The numeric semantic version segment without build metadata.
  String get versionCore => '$versionMajor.$versionMinor.$versionPatch';
}

/// Effective or default terminal colors and palette.
final class VtTerminalColors {
  const VtTerminalColors({
    required this.foreground,
    required this.background,
    required this.cursor,
    required this.palette,
  });

  final VtRgbColor? foreground;
  final VtRgbColor? background;
  final VtRgbColor? cursor;
  final List<VtRgbColor> palette;

  /// Returns the palette entry at [index].
  VtRgbColor paletteAt(int index) {
    RangeError.checkValueInInterval(index, 0, palette.length - 1, 'index');
    return palette[index];
  }
}

final class VtMode {
  const VtMode(this.mode, {this.ansi = false})
    : assert(mode >= 0 && mode <= 0x7FFF);

  final int mode;
  final bool ansi;

  int get packed => (mode & 0x7FFF) | (ansi ? 0x8000 : 0);
}

/// Common terminal mode constants shared with the native API surface.
final class VtModes {
  const VtModes._();

  static const kam = VtMode(2, ansi: true);
  static const insert = VtMode(4, ansi: true);
  static const srm = VtMode(12, ansi: true);
  static const linefeed = VtMode(20, ansi: true);

  static const cursorKeys = VtMode(1);
  static const column132 = VtMode(3);
  static const slowScroll = VtMode(4);
  static const reverseColors = VtMode(5);
  static const origin = VtMode(6);
  static const wraparound = VtMode(7);
  static const autorepeat = VtMode(8);
  static const x10Mouse = VtMode(9);
  static const cursorBlinking = VtMode(12);
  static const cursorVisible = VtMode(25);
  static const enableMode3 = VtMode(40);
  static const reverseWrap = VtMode(45);
  static const altScreenLegacy = VtMode(47);
  static const keypadKeys = VtMode(66);
  static const leftRightMargin = VtMode(69);
  static const normalMouse = VtMode(1000);
  static const buttonMouse = VtMode(1002);
  static const anyMouse = VtMode(1003);
  static const focusEvent = VtMode(1004);
  static const utf8Mouse = VtMode(1005);
  static const sgrMouse = VtMode(1006);
  static const altScroll = VtMode(1007);
  static const urxvtMouse = VtMode(1015);
  static const sgrPixelsMouse = VtMode(1016);
  static const numlockKeypad = VtMode(1035);
  static const altEscPrefix = VtMode(1036);
  static const altSendsEsc = VtMode(1039);
  static const reverseWrapExt = VtMode(1045);
  static const altScreen = VtMode(1047);
  static const saveCursor = VtMode(1048);
  static const altScreenSave = VtMode(1049);
  static const bracketedPaste = VtMode(2004);
  static const syncOutput = VtMode(2026);
  static const graphemeCluster = VtMode(2027);
  static const colorSchemeReport = VtMode(2031);
  static const inBandResize = VtMode(2048);
}

final class VtPoint {
  const VtPoint.active(this.x, this.y)
    : tag = GhosttyPointTag.GHOSTTY_POINT_TAG_ACTIVE;

  const VtPoint.viewport(this.x, this.y)
    : tag = GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT;

  const VtPoint.screen(this.x, this.y)
    : tag = GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN;

  const VtPoint.history(this.x, this.y)
    : tag = GhosttyPointTag.GHOSTTY_POINT_TAG_HISTORY;

  final GhosttyPointTag tag;
  final int x;
  final int y;
}

final class VtStyleColor {
  const VtStyleColor._({required this.tag, this.paletteIndex, this.rgb});

  const VtStyleColor.none()
    : this._(tag: GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE);

  const VtStyleColor.palette(int index)
    : this._(
        tag: GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE,
        paletteIndex: index,
      );

  const VtStyleColor.rgb(VtRgbColor value)
    : this._(tag: GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB, rgb: value);

  final GhosttyStyleColorTag tag;
  final int? paletteIndex;
  final VtRgbColor? rgb;

  bool get isSet => tag != GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE;
}

final class VtStyle {
  const VtStyle({
    required this.foreground,
    required this.background,
    required this.underlineColor,
    required this.bold,
    required this.italic,
    required this.faint,
    required this.blink,
    required this.inverse,
    required this.invisible,
    required this.strikethrough,
    required this.overline,
    required this.underline,
  });

  final VtStyleColor foreground;
  final VtStyleColor background;
  final VtStyleColor underlineColor;
  final bool bold;
  final bool italic;
  final bool faint;
  final bool blink;
  final bool inverse;
  final bool invisible;
  final bool strikethrough;
  final bool overline;
  final GhosttySgrUnderline underline;
}

final class VtTerminalScrollbar {
  const VtTerminalScrollbar({
    required this.total,
    required this.offset,
    required this.length,
  });

  final int total;
  final int offset;
  final int length;
}

final class VtRowSnapshot {
  const VtRowSnapshot({
    required this.wrap,
    required this.wrapContinuation,
    required this.hasGrapheme,
    required this.styled,
    required this.hasHyperlink,
    required this.semanticPrompt,
    required this.kittyVirtualPlaceholder,
    required this.dirty,
  });

  final bool wrap;
  final bool wrapContinuation;
  final bool hasGrapheme;
  final bool styled;
  final bool hasHyperlink;
  final GhosttyRowSemanticPrompt semanticPrompt;
  final bool kittyVirtualPlaceholder;
  final bool dirty;
}

final class VtCellSnapshot {
  const VtCellSnapshot({
    required this.codepoint,
    required this.contentTag,
    required this.wide,
    required this.hasText,
    required this.hasStyling,
    required this.styleId,
    required this.hasHyperlink,
    required this.isProtected,
    required this.semanticContent,
    this.colorPaletteIndex,
    this.colorRgb,
  });

  final int codepoint;
  final GhosttyCellContentTag contentTag;
  final GhosttyCellWide wide;
  final bool hasText;
  final bool hasStyling;
  final int styleId;
  final bool hasHyperlink;
  final bool isProtected;
  final GhosttyCellSemanticContent semanticContent;
  final int? colorPaletteIndex;
  final VtRgbColor? colorRgb;

  String get text => codepoint == 0 ? '' : String.fromCharCode(codepoint);
}

final class VtGridRefSnapshot {
  const VtGridRefSnapshot({
    required this.x,
    required this.y,
    required this.cell,
    required this.row,
    required this.style,
    required this.graphemes,
  });

  final int x;
  final int y;
  final VtCellSnapshot cell;
  final VtRowSnapshot row;
  final VtStyle style;
  final String graphemes;
}

final class VtRenderColors {
  const VtRenderColors({
    required this.background,
    required this.foreground,
    required this.cursor,
    required this.palette,
  });

  final VtRgbColor background;
  final VtRgbColor foreground;
  final VtRgbColor? cursor;
  final List<VtRgbColor> palette;

  /// Returns the palette entry at [index].
  VtRgbColor paletteAt(int index) {
    RangeError.checkValueInInterval(index, 0, palette.length - 1, 'index');
    return palette[index];
  }

  /// Resolves [color] to an RGB value using this render-state palette.
  VtRgbColor? resolve(VtStyleColor color, {VtRgbColor? defaultColor}) {
    return switch (color.tag) {
      GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE => defaultColor,
      GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE => paletteAt(
        color.paletteIndex!,
      ),
      GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB => color.rgb,
    };
  }

  /// Resolves this style's foreground color using this render-state palette.
  VtRgbColor? resolveForeground(VtStyle style) =>
      resolve(style.foreground, defaultColor: foreground);

  /// Resolves this style's background color using this render-state palette.
  VtRgbColor? resolveBackground(VtStyle style) =>
      resolve(style.background, defaultColor: background);

  /// Resolves this style's underline color using this render-state palette.
  VtRgbColor? resolveUnderlineColor(VtStyle style) =>
      resolve(style.underlineColor, defaultColor: resolveForeground(style));
}

final class VtRenderCursorSnapshot {
  const VtRenderCursorSnapshot({
    required this.visualStyle,
    required this.visible,
    required this.blinking,
    required this.passwordInput,
    required this.hasViewportPosition,
    this.viewportX,
    this.viewportY,
    this.onWideTail,
  });

  final GhosttyRenderStateCursorVisualStyle visualStyle;
  final bool visible;
  final bool blinking;
  final bool passwordInput;
  final bool hasViewportPosition;
  final int? viewportX;
  final int? viewportY;
  final bool? onWideTail;
}

final class VtRenderCellSnapshot {
  const VtRenderCellSnapshot({
    required this.raw,
    required this.style,
    required this.graphemes,
  });

  final VtCellSnapshot raw;
  final VtStyle style;
  final String graphemes;
}

final class VtRenderRowSnapshot {
  const VtRenderRowSnapshot({
    required this.dirty,
    required this.raw,
    required this.cells,
  });

  final bool dirty;
  final VtRowSnapshot raw;
  final List<VtRenderCellSnapshot> cells;
}

final class VtRenderSnapshot {
  const VtRenderSnapshot({
    required this.cols,
    required this.rows,
    required this.dirty,
    required this.colors,
    required this.cursor,
    required this.rowsData,
  });

  final int cols;
  final int rows;
  final GhosttyRenderStateDirty dirty;
  final VtRenderColors colors;
  final VtRenderCursorSnapshot cursor;
  final List<VtRenderRowSnapshot> rowsData;
}

final class VtSizeReportSize {
  const VtSizeReportSize({
    required this.rows,
    required this.columns,
    required this.cellWidth,
    required this.cellHeight,
  });

  final int rows;
  final int columns;
  final int cellWidth;
  final int cellHeight;
}

/// Color scheme variants for the terminal.
enum GhosttyColorScheme {
  GHOSTTY_COLOR_SCHEME_LIGHT(0),
  GHOSTTY_COLOR_SCHEME_DARK(1);

  final int value;
  const GhosttyColorScheme(this.value);

  static GhosttyColorScheme fromValue(int value) => switch (value) {
    0 => GHOSTTY_COLOR_SCHEME_LIGHT,
    1 => GHOSTTY_COLOR_SCHEME_DARK,
    _ => throw ArgumentError('Unknown value for GhosttyColorScheme: $value'),
  };
}

/// Primary device attributes (DA1) response data.
final class VtDeviceAttributesPrimary {
  const VtDeviceAttributesPrimary({
    required this.conformanceLevel,
    this.features = const [],
  });

  final int conformanceLevel;
  final List<int> features;
}

/// Secondary device attributes (DA2) response data.
final class VtDeviceAttributesSecondary {
  const VtDeviceAttributesSecondary({
    required this.deviceType,
    required this.firmwareVersion,
    this.romCartridge = 0,
  });

  final int deviceType;
  final int firmwareVersion;
  final int romCartridge;
}

/// Tertiary device attributes (DA3) response data.
final class VtDeviceAttributesTertiary {
  const VtDeviceAttributesTertiary({required this.unitId});

  final int unitId;
}

/// Device attributes response data for all three DA levels.
final class VtDeviceAttributes {
  const VtDeviceAttributes({
    required this.primary,
    required this.secondary,
    required this.tertiary,
  });

  final VtDeviceAttributesPrimary primary;
  final VtDeviceAttributesSecondary secondary;
  final VtDeviceAttributesTertiary tertiary;
}

final class VtMousePosition {
  const VtMousePosition({required this.x, required this.y});

  final double x;
  final double y;
}

final class VtMouseEncoderSize {
  const VtMouseEncoderSize({
    required this.screenWidth,
    required this.screenHeight,
    required this.cellWidth,
    required this.cellHeight,
    this.paddingTop = 0,
    this.paddingBottom = 0,
    this.paddingRight = 0,
    this.paddingLeft = 0,
  });

  final int screenWidth;
  final int screenHeight;
  final int cellWidth;
  final int cellHeight;
  final int paddingTop;
  final int paddingBottom;
  final int paddingRight;
  final int paddingLeft;
}

final class VtOscCommand {
  const VtOscCommand({required this.type, this.windowTitle});

  final GhosttyOscCommandType type;
  final String? windowTitle;
}

final class VtOscParser {
  VtOscParser() {
    final rt = _runtime();
    if (rt != null) {
      _wasm = rt;
      final out = rt.allocOpaque();
      if (out == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_opaque',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      try {
        final result = rt.callInt('ghostty_osc_new', <Object>[0, out]);
        _checkResult(result, 'ghostty_osc_new');
        _handle = rt.readPtr(out);
      } finally {
        rt.freeOpaque(out);
      }
    }
  }

  _GhosttyWasmRuntime? _wasm;
  int _handle = 0;
  final List<int> _bytes = <int>[];
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtOscParser is already closed.');
    }
  }

  void reset() {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_osc_reset', <Object>[_handle]);
      return;
    }
    _bytes.clear();
  }

  void addByte(int byte) {
    _ensureOpen();
    if (byte < 0 || byte > 255) {
      throw RangeError.range(byte, 0, 255, 'byte');
    }
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_osc_next', <Object>[_handle, byte]);
      return;
    }
    _bytes.add(byte);
  }

  void addBytes(Iterable<int> bytes) {
    for (final byte in bytes) {
      addByte(byte);
    }
  }

  void addText(String text, {Encoding encoding = utf8}) {
    addBytes(encoding.encode(text));
  }

  VtOscCommand end({int terminator = 0x07}) {
    _ensureOpen();
    if (terminator < 0 || terminator > 255) {
      throw RangeError.range(terminator, 0, 255, 'terminator');
    }
    final rt = _wasm;
    if (rt != null) {
      final command = rt.callInt('ghostty_osc_end', <Object>[
        _handle,
        terminator,
      ]);

      // Guard: if the wasm call returned a null pointer, treat as invalid.
      if (command == 0) {
        return const VtOscCommand(
          type: GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID,
        );
      }

      final type = GhosttyOscCommandType.fromValue(
        rt.callInt('ghostty_osc_command_type', <Object>[command]),
      );

      // Guard: don't attempt to extract data from invalid/unrecognised
      // commands — the wasm library may crash if asked for data on a command
      // that doesn't carry it.
      if (type == GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID) {
        return const VtOscCommand(
          type: GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID,
        );
      }

      String? windowTitle;

      // Only query the window-title data field for command types that carry it.
      if (type ==
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE ||
          type ==
              GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON) {
        final out = rt.allocOpaque();
        if (out != 0) {
          try {
            final ok = rt.callBool('ghostty_osc_command_data', <Object>[
              command,
              GhosttyOscCommandData
                  .GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR
                  .value,
              out,
            ]);
            if (ok) {
              final strPtr = rt.readPtr(out);
              if (strPtr != 0) {
                windowTitle = rt.readCString(strPtr);
              }
            }
          } finally {
            rt.freeOpaque(out);
          }
        }
      }

      return VtOscCommand(type: type, windowTitle: windowTitle);
    }

    final payload = utf8.decode(_bytes, allowMalformed: true);
    final separator = payload.indexOf(';');
    if (separator <= 0 || separator >= payload.length - 1) {
      return const VtOscCommand(
        type: GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID,
      );
    }
    final code = payload.substring(0, separator);
    final data = payload.substring(separator + 1);
    switch (code) {
      case '0':
      case '2':
        return VtOscCommand(
          type: GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE,
          windowTitle: data,
        );
      case '1':
        return const VtOscCommand(
          type: GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON,
        );
      default:
        return const VtOscCommand(
          type: GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID,
        );
    }
  }

  void close() {
    final rt = _wasm;
    if (rt != null && _handle != 0) {
      rt.callInt('ghostty_osc_free', <Object>[_handle]);
      _handle = 0;
      _wasm = null;
    }
    _closed = true;
  }
}

final class VtSgrUnknownData {
  const VtSgrUnknownData({required this.full, required this.partial});

  final List<int> full;
  final List<int> partial;
}

final class VtSgrAttributeData {
  const VtSgrAttributeData({
    required this.tag,
    this.unknown,
    this.underline,
    this.rgb,
    this.paletteIndex,
  });

  final GhosttySgrAttributeTag tag;
  final VtSgrUnknownData? unknown;
  final GhosttySgrUnderline? underline;
  final VtRgbColor? rgb;
  final int? paletteIndex;
}

final class VtSgrParser {
  VtSgrParser() {
    final rt = _runtime();
    if (rt != null) {
      _wasm = rt;
      final out = rt.allocOpaque();
      if (out == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_opaque',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      try {
        final result = rt.callInt('ghostty_sgr_new', <Object>[0, out]);
        _checkResult(result, 'ghostty_sgr_new');
        _handle = rt.readPtr(out);
      } finally {
        rt.freeOpaque(out);
      }
      _attrPtr = rt.callInt('ghostty_wasm_alloc_sgr_attribute');
      if (_attrPtr == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_sgr_attribute',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
    }
  }

  _GhosttyWasmRuntime? _wasm;
  int _handle = 0;
  int _attrPtr = 0;
  List<int> _params = <int>[];
  int _index = 0;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtSgrParser is already closed.');
    }
  }

  void reset() {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_sgr_reset', <Object>[_handle]);
      return;
    }
    _index = 0;
  }

  void setParams(List<int> params, {String? separators}) {
    _ensureOpen();
    if (separators != null && separators.length != params.length) {
      throw ArgumentError.value(
        separators,
        'separators',
        'Must have same length as params.',
      );
    }
    final rt = _wasm;
    if (rt != null) {
      final paramsPtr = rt.allocU16Array(params.length);
      if (paramsPtr == 0 && params.isNotEmpty) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_u16_array',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      var separatorsPtr = 0;
      try {
        for (var i = 0; i < params.length; i++) {
          final value = params[i];
          if (value < 0 || value > 0xFFFF) {
            throw RangeError.range(value, 0, 0xFFFF, 'params[$i]');
          }
          rt.writeU16(paramsPtr + (i * 2), value);
        }
        if (separators != null) {
          separatorsPtr = rt.allocU8Array(separators.length);
          if (separatorsPtr == 0 && separators.isNotEmpty) {
            throw GhosttyVtError(
              'ghostty_wasm_alloc_u8_array',
              GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
            );
          }
          for (var i = 0; i < separators.length; i++) {
            final value = separators.codeUnitAt(i);
            if (value > 0xFF) {
              throw RangeError.range(value, 0, 0xFF, 'separators[$i]');
            }
            rt.writeU8(separatorsPtr + i, value);
          }
        }
        final result = rt.callInt('ghostty_sgr_set_params', <Object>[
          _handle,
          paramsPtr,
          separatorsPtr,
          params.length,
        ]);
        _checkResult(result, 'ghostty_sgr_set_params');
      } finally {
        if (separatorsPtr != 0) {
          rt.freeU8Array(separatorsPtr, separators!.length);
        }
        if (paramsPtr != 0) {
          rt.freeU16Array(paramsPtr, params.length);
        }
      }
      return;
    }
    _params = List<int>.from(params);
    _index = 0;
  }

  VtSgrAttributeData? next() {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      final hasNext = rt.callBool('ghostty_sgr_next', <Object>[
        _handle,
        _attrPtr,
      ]);
      if (!hasNext) {
        return null;
      }

      final tag = GhosttySgrAttributeTag.fromValue(
        rt.callInt('ghostty_sgr_attribute_tag', <Object>[_attrPtr]),
      );
      final valuePtr = rt.callInt('ghostty_sgr_attribute_value', <Object>[
        _attrPtr,
      ]);
      switch (tag) {
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNKNOWN:
          final fullPtr = rt.readPtr(valuePtr);
          final fullLen = rt.readUsize(valuePtr + 4);
          final partialPtr = rt.readPtr(valuePtr + 8);
          final partialLen = rt.readUsize(valuePtr + 12);
          return VtSgrAttributeData(
            tag: tag,
            unknown: VtSgrUnknownData(
              full: List<int>.unmodifiable(rt.readU16List(fullPtr, fullLen)),
              partial: List<int>.unmodifiable(
                rt.readU16List(partialPtr, partialLen),
              ),
            ),
          );
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE:
          return VtSgrAttributeData(
            tag: tag,
            underline: GhosttySgrUnderline.fromValue(rt.readI32(valuePtr)),
          );
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG:
          return VtSgrAttributeData(
            tag: tag,
            rgb: VtRgbColor(
              rt.readU8(valuePtr),
              rt.readU8(valuePtr + 1),
              rt.readU8(valuePtr + 2),
            ),
          );
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR_256:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_8:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_8:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_BG_8:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_FG_8:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_256:
        case GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_256:
          return VtSgrAttributeData(
            tag: tag,
            paletteIndex: rt.readU8(valuePtr),
          );
        default:
          return VtSgrAttributeData(tag: tag);
      }
    }
    if (_index >= _params.length) {
      return null;
    }
    final p = _params[_index++];
    switch (p) {
      case 0:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNSET,
        );
      case 1:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BOLD,
        );
      case 2:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FAINT,
        );
      case 3:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_ITALIC,
        );
      case 4:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE,
          underline: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_SINGLE,
        );
      case 5:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BLINK,
        );
      case 7:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_INVERSE,
        );
      case 8:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_INVISIBLE,
        );
      case 9:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_STRIKETHROUGH,
        );
      case 22:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_BOLD,
        );
      case 23:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_ITALIC,
        );
      case 24:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE,
          underline: GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE,
        );
      case 25:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_BLINK,
        );
      case 27:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_INVERSE,
        );
      case 28:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_INVISIBLE,
        );
      case 29:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_STRIKETHROUGH,
        );
      case 39:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_FG,
        );
      case 49:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_BG,
        );
      case 53:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_OVERLINE,
        );
      case 55:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_OVERLINE,
        );
      case 59:
        return const VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_RESET_UNDERLINE_COLOR,
        );
      case 30:
      case 31:
      case 32:
      case 33:
      case 34:
      case 35:
      case 36:
      case 37:
        return VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_8,
          paletteIndex: p - 30,
        );
      case 40:
      case 41:
      case 42:
      case 43:
      case 44:
      case 45:
      case 46:
      case 47:
        return VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_8,
          paletteIndex: p - 40,
        );
      case 90:
      case 91:
      case 92:
      case 93:
      case 94:
      case 95:
      case 96:
      case 97:
        return VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_FG_8,
          paletteIndex: (p - 90) + 8,
        );
      case 100:
      case 101:
      case 102:
      case 103:
      case 104:
      case 105:
      case 106:
      case 107:
        return VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_BG_8,
          paletteIndex: (p - 100) + 8,
        );
      case 38:
        return _parseComplexColor(fg: true, fallbackAt: _index - 1);
      case 48:
        return _parseComplexColor(fg: false, fallbackAt: _index - 1);
      case 58:
        return _parseUnderlineColor(fallbackAt: _index - 1);
      default:
        return VtSgrAttributeData(
          tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNKNOWN,
          unknown: VtSgrUnknownData(
            full: List<int>.from(_params),
            partial: List<int>.from(_params.sublist(_index - 1)),
          ),
        );
    }
  }

  VtSgrAttributeData _parseUnderlineColor({required int fallbackAt}) {
    if (_index + 1 < _params.length && _params[_index] == 5) {
      final palette = _params[_index + 1].clamp(0, 255);
      _index += 2;
      return VtSgrAttributeData(
        tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR_256,
        paletteIndex: palette,
      );
    }
    if (_index + 3 < _params.length && _params[_index] == 2) {
      final r = _params[_index + 1].clamp(0, 255);
      final g = _params[_index + 2].clamp(0, 255);
      final b = _params[_index + 3].clamp(0, 255);
      _index += 4;
      return VtSgrAttributeData(
        tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR,
        rgb: VtRgbColor(r, g, b),
      );
    }
    return VtSgrAttributeData(
      tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNKNOWN,
      unknown: VtSgrUnknownData(
        full: List<int>.from(_params),
        partial: List<int>.from(_params.sublist(fallbackAt)),
      ),
    );
  }

  VtSgrAttributeData _parseComplexColor({
    required bool fg,
    required int fallbackAt,
  }) {
    if (_index + 1 < _params.length && _params[_index] == 5) {
      final palette = _params[_index + 1].clamp(0, 255);
      _index += 2;
      return VtSgrAttributeData(
        tag: fg
            ? GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_256
            : GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_256,
        paletteIndex: palette,
      );
    }
    if (_index + 3 < _params.length && _params[_index] == 2) {
      final r = _params[_index + 1].clamp(0, 255);
      final g = _params[_index + 2].clamp(0, 255);
      final b = _params[_index + 3].clamp(0, 255);
      _index += 4;
      return VtSgrAttributeData(
        tag: fg
            ? GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG
            : GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG,
        rgb: VtRgbColor(r, g, b),
      );
    }
    return VtSgrAttributeData(
      tag: GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNKNOWN,
      unknown: VtSgrUnknownData(
        full: List<int>.from(_params),
        partial: List<int>.from(_params.sublist(fallbackAt)),
      ),
    );
  }

  List<VtSgrAttributeData> parseAll() {
    final out = <VtSgrAttributeData>[];
    while (true) {
      final attr = next();
      if (attr == null) {
        break;
      }
      out.add(attr);
    }
    return out;
  }

  List<VtSgrAttributeData> parseParams(List<int> params, {String? separators}) {
    setParams(params, separators: separators);
    return parseAll();
  }

  void close() {
    final rt = _wasm;
    if (rt != null) {
      if (_handle != 0) {
        rt.callInt('ghostty_sgr_free', <Object>[_handle]);
        _handle = 0;
      }
      if (_attrPtr != 0) {
        rt.callInt('ghostty_wasm_free_sgr_attribute', <Object>[_attrPtr]);
        _attrPtr = 0;
      }
      _wasm = null;
    }
    _closed = true;
  }
}

final class VtKeyEvent {
  VtKeyEvent() {
    final rt = _runtime();
    if (rt != null) {
      _wasm = rt;
      final out = rt.allocOpaque();
      if (out == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_opaque',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      try {
        final result = rt.callInt('ghostty_key_event_new', <Object>[0, out]);
        _checkResult(result, 'ghostty_key_event_new');
        _handle = rt.readPtr(out);
      } finally {
        rt.freeOpaque(out);
      }
    }
  }

  _GhosttyWasmRuntime? _wasm;
  int _handle = 0;
  int _utf8StoragePtr = 0;
  int _utf8StorageLen = 0;
  bool _closed = false;

  GhosttyKeyAction _fallbackAction = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS;
  GhosttyKey _fallbackKey = GhosttyKey.GHOSTTY_KEY_UNIDENTIFIED;
  int _fallbackMods = 0;
  int _fallbackConsumedMods = 0;
  bool _fallbackComposing = false;
  String _fallbackUtf8Text = '';
  int _fallbackUnshiftedCodepoint = 0;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtKeyEvent is already closed.');
    }
  }

  GhosttyKeyAction get action {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      return GhosttyKeyAction.fromValue(
        rt.callInt('ghostty_key_event_get_action', <Object>[_handle]),
      );
    }
    return _fallbackAction;
  }

  set action(GhosttyKeyAction value) {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_key_event_set_action', <Object>[
        _handle,
        value.value,
      ]);
      return;
    }
    _fallbackAction = value;
  }

  GhosttyKey get key {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      return GhosttyKey.fromValue(
        rt.callInt('ghostty_key_event_get_key', <Object>[_handle]),
      );
    }
    return _fallbackKey;
  }

  set key(GhosttyKey value) {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_key_event_set_key', <Object>[_handle, value.value]);
      return;
    }
    _fallbackKey = value;
  }

  int get mods {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      return rt.callInt('ghostty_key_event_get_mods', <Object>[_handle]);
    }
    return _fallbackMods;
  }

  set mods(int value) {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_key_event_set_mods', <Object>[_handle, value]);
      return;
    }
    _fallbackMods = value;
  }

  int get consumedMods {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      return rt.callInt('ghostty_key_event_get_consumed_mods', <Object>[
        _handle,
      ]);
    }
    return _fallbackConsumedMods;
  }

  set consumedMods(int value) {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_key_event_set_consumed_mods', <Object>[
        _handle,
        value,
      ]);
      return;
    }
    _fallbackConsumedMods = value;
  }

  bool get composing {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      return rt.callBool('ghostty_key_event_get_composing', <Object>[_handle]);
    }
    return _fallbackComposing;
  }

  set composing(bool value) {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_key_event_set_composing', <Object>[
        _handle,
        value ? 1 : 0,
      ]);
      return;
    }
    _fallbackComposing = value;
  }

  String get utf8Text {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      final lenPtr = rt.allocUsize();
      if (lenPtr == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_usize',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      try {
        final textPtr = rt.callInt('ghostty_key_event_get_utf8', <Object>[
          _handle,
          lenPtr,
        ]);
        final len = rt.readUsize(lenPtr);
        if (textPtr == 0 || len == 0) {
          return '';
        }
        return utf8.decode(rt.u8View(textPtr, len), allowMalformed: true);
      } finally {
        rt.freeUsize(lenPtr);
      }
    }
    return _fallbackUtf8Text;
  }

  set utf8Text(String value) {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      _freeUtf8Storage();
      if (value.isEmpty) {
        rt.callInt('ghostty_key_event_set_utf8', <Object>[_handle, 0, 0]);
        return;
      }
      final bytes = utf8.encode(value);
      final textPtr = rt.allocU8Array(bytes.length);
      if (textPtr == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_u8_array',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      rt.u8View(textPtr, bytes.length).setAll(0, bytes);
      _utf8StoragePtr = textPtr;
      _utf8StorageLen = bytes.length;
      rt.callInt('ghostty_key_event_set_utf8', <Object>[
        _handle,
        textPtr,
        bytes.length,
      ]);
      return;
    }
    _fallbackUtf8Text = value;
  }

  int get unshiftedCodepoint {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null) {
      return rt.callInt('ghostty_key_event_get_unshifted_codepoint', <Object>[
        _handle,
      ]);
    }
    return _fallbackUnshiftedCodepoint;
  }

  set unshiftedCodepoint(int value) {
    _ensureOpen();
    if (value < 0 || value > 0x10FFFF) {
      throw RangeError.range(value, 0, 0x10FFFF, 'unshiftedCodepoint');
    }
    final rt = _wasm;
    if (rt != null) {
      rt.callInt('ghostty_key_event_set_unshifted_codepoint', <Object>[
        _handle,
        value,
      ]);
      return;
    }
    _fallbackUnshiftedCodepoint = value;
  }

  void _freeUtf8Storage() {
    final rt = _wasm;
    if (rt != null && _utf8StoragePtr != 0) {
      rt.freeU8Array(_utf8StoragePtr, _utf8StorageLen);
      _utf8StoragePtr = 0;
      _utf8StorageLen = 0;
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _freeUtf8Storage();
    final rt = _wasm;
    if (rt != null && _handle != 0) {
      rt.callInt('ghostty_key_event_free', <Object>[_handle]);
      _handle = 0;
      _wasm = null;
    }
    _closed = true;
  }
}

final class VtKeyEncoder {
  VtKeyEncoder() {
    final rt = _runtime();
    if (rt != null) {
      _wasm = rt;
      final out = rt.allocOpaque();
      if (out == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_opaque',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      try {
        final result = rt.callInt('ghostty_key_encoder_new', <Object>[0, out]);
        _checkResult(result, 'ghostty_key_encoder_new');
        _handle = rt.readPtr(out);
      } finally {
        rt.freeOpaque(out);
      }
    }
  }

  _GhosttyWasmRuntime? _wasm;
  int _handle = 0;
  bool _closed = false;

  bool _cursorKeyApplication = false;
  bool _keypadKeyApplication = false;
  bool _ignoreKeypadWithNumLock = true;
  bool _altEscPrefix = true;
  bool _modifyOtherKeysState2 = true;
  int _kittyFlags = GhosttyKittyFlags.disabled;
  GhosttyOptionAsAlt _macosOptionAsAlt =
      GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_FALSE;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtKeyEncoder is already closed.');
    }
  }

  void _setBoolOptionWasm(GhosttyKeyEncoderOption option, bool value) {
    final rt = _wasm;
    if (rt == null) {
      return;
    }
    final ptr = rt.allocU8();
    if (ptr == 0) {
      throw GhosttyVtError(
        'ghostty_wasm_alloc_u8',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }
    try {
      rt.writeU8(ptr, value ? 1 : 0);
      rt.callInt('ghostty_key_encoder_setopt', <Object>[
        _handle,
        option.value,
        ptr,
      ]);
    } finally {
      rt.freeU8(ptr);
    }
  }

  set cursorKeyApplication(bool enabled) {
    _ensureOpen();
    _cursorKeyApplication = enabled;
    _setBoolOptionWasm(
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION,
      enabled,
    );
  }

  set keypadKeyApplication(bool enabled) {
    _ensureOpen();
    _keypadKeyApplication = enabled;
    _setBoolOptionWasm(
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION,
      enabled,
    );
  }

  set ignoreKeypadWithNumLock(bool enabled) {
    _ensureOpen();
    _ignoreKeypadWithNumLock = enabled;
    _setBoolOptionWasm(
      GhosttyKeyEncoderOption
          .GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK,
      enabled,
    );
  }

  set altEscPrefix(bool enabled) {
    _ensureOpen();
    _altEscPrefix = enabled;
    _setBoolOptionWasm(
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX,
      enabled,
    );
  }

  set modifyOtherKeysState2(bool enabled) {
    _ensureOpen();
    _modifyOtherKeysState2 = enabled;
    _setBoolOptionWasm(
      GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2,
      enabled,
    );
  }

  set kittyFlags(int flags) {
    _ensureOpen();
    _kittyFlags = flags;
    final rt = _wasm;
    if (rt == null) {
      return;
    }
    final ptr = rt.allocU8();
    if (ptr == 0) {
      throw GhosttyVtError(
        'ghostty_wasm_alloc_u8',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }
    try {
      rt.writeU8(ptr, flags & 0xFF);
      rt.callInt('ghostty_key_encoder_setopt', <Object>[
        _handle,
        GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS.value,
        ptr,
      ]);
    } finally {
      rt.freeU8(ptr);
    }
  }

  set macosOptionAsAlt(GhosttyOptionAsAlt value) {
    _ensureOpen();
    _macosOptionAsAlt = value;
    final rt = _wasm;
    if (rt == null) {
      return;
    }
    final ptr = rt.allocU8Array(4);
    if (ptr == 0) {
      throw GhosttyVtError(
        'ghostty_wasm_alloc_u8_array',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }
    try {
      rt.writeU32(ptr, value.value);
      rt.callInt('ghostty_key_encoder_setopt', <Object>[
        _handle,
        GhosttyKeyEncoderOption
            .GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT
            .value,
        ptr,
      ]);
    } finally {
      rt.freeU8Array(ptr, 4);
    }
  }

  void setOptionsFromTerminal(VtTerminal terminal) {
    _ensureOpen();
    terminal._ensureOpen();
    final rt = _wasm;
    if (rt == null || !identical(rt, terminal._wasm)) {
      throw StateError(
        'VtKeyEncoder.setOptionsFromTerminal requires the encoder and '
        'terminal to use the same initialized wasm runtime.',
      );
    }
    rt.callInt('ghostty_key_encoder_setopt_from_terminal', <Object>[
      _handle,
      terminal._handle,
    ]);
  }

  Uint8List encode(VtKeyEvent event) {
    _ensureOpen();
    final rt = _wasm;
    if (rt != null && event._wasm == rt && event._handle != 0) {
      final outLenPtr = rt.allocUsize();
      if (outLenPtr == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_usize',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      try {
        final first = rt.callInt('ghostty_key_encoder_encode', <Object>[
          _handle,
          event._handle,
          0,
          0,
          outLenPtr,
        ]);
        final required = rt.readUsize(outLenPtr);
        if (first == GhosttyResult.GHOSTTY_SUCCESS.value && required == 0) {
          return Uint8List(0);
        }
        if (first != GhosttyResult.GHOSTTY_OUT_OF_MEMORY.value) {
          _checkResult(first, 'ghostty_key_encoder_encode(size_probe)');
        }
        if (required == 0) {
          return Uint8List(0);
        }

        final outBuf = rt.allocU8Array(required);
        if (outBuf == 0) {
          throw GhosttyVtError(
            'ghostty_wasm_alloc_u8_array',
            GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
          );
        }
        try {
          final second = rt.callInt('ghostty_key_encoder_encode', <Object>[
            _handle,
            event._handle,
            outBuf,
            required,
            outLenPtr,
          ]);
          _checkResult(second, 'ghostty_key_encoder_encode');
          final written = rt.readUsize(outLenPtr);
          return Uint8List.fromList(rt.u8View(outBuf, written));
        } finally {
          rt.freeU8Array(outBuf, required);
        }
      } finally {
        rt.freeUsize(outLenPtr);
      }
    }

    var bytes = _encodeLegacy(event);

    final wantsKitty = _kittyFlags != GhosttyKittyFlags.disabled;
    if (wantsKitty &&
        (event.mods != 0 ||
            event.action != GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS)) {
      final kittyCode = _kittyKeyCode(event);
      if (kittyCode != 0) {
        final mods = _kittyModifierValue(event.mods);
        final seq =
            '\x1b[$kittyCode;$mods'
            '${event.action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE ? ':3' : ''}u';
        bytes = Uint8List.fromList(utf8.encode(seq));
      }
    }

    final useAltPrefix =
        _altEscPrefix &&
        (event.mods & GhosttyModsMask.alt) != 0 &&
        bytes.isNotEmpty;
    if (useAltPrefix) {
      bytes = Uint8List.fromList(<int>[0x1B, ...bytes]);
    }

    // Preserve option to avoid "unused" lints for stored options.
    if (_keypadKeyApplication ||
        _ignoreKeypadWithNumLock ||
        _modifyOtherKeysState2 ||
        _macosOptionAsAlt != GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_FALSE) {
      // No-op in web fallback.
    }

    return bytes;
  }

  String encodeToString(VtKeyEvent event) =>
      String.fromCharCodes(encode(event));

  Uint8List _encodeLegacy(VtKeyEvent event) {
    final ctrl = (event.mods & GhosttyModsMask.ctrl) != 0;

    if (ctrl) {
      final control = _controlCodeForLetter(event.key);
      if (control != null) {
        return Uint8List.fromList(<int>[control]);
      }
    }

    final special = _specialSequence(
      event.key,
      cursorApplication: _cursorKeyApplication,
    );
    if (special != null) {
      return Uint8List.fromList(special);
    }

    if (event.utf8Text.isNotEmpty) {
      return Uint8List.fromList(utf8.encode(event.utf8Text));
    }

    return Uint8List(0);
  }

  int? _controlCodeForLetter(GhosttyKey key) {
    final value = key.value;
    final a = GhosttyKey.GHOSTTY_KEY_A.value;
    final z = GhosttyKey.GHOSTTY_KEY_Z.value;
    if (value < a || value > z) {
      return null;
    }
    return (value - a) + 1;
  }

  int _kittyModifierValue(int mods) {
    var value = 1;
    if ((mods & GhosttyModsMask.shift) != 0) {
      value += 1;
    }
    if ((mods & GhosttyModsMask.alt) != 0) {
      value += 2;
    }
    if ((mods & GhosttyModsMask.ctrl) != 0) {
      value += 4;
    }
    if ((mods & GhosttyModsMask.superKey) != 0) {
      value += 8;
    }
    return value;
  }

  int _kittyKeyCode(VtKeyEvent event) {
    switch (event.key) {
      case GhosttyKey.GHOSTTY_KEY_ENTER:
        return 13;
      case GhosttyKey.GHOSTTY_KEY_TAB:
        return 9;
      case GhosttyKey.GHOSTTY_KEY_BACKSPACE:
        return 127;
      case GhosttyKey.GHOSTTY_KEY_ESCAPE:
        return 27;
      default:
        final value = event.key.value;
        final a = GhosttyKey.GHOSTTY_KEY_A.value;
        final z = GhosttyKey.GHOSTTY_KEY_Z.value;
        if (value >= a && value <= z) {
          return 'a'.codeUnitAt(0) + (value - a);
        }
        return event.unshiftedCodepoint;
    }
  }

  List<int>? _specialSequence(
    GhosttyKey key, {
    required bool cursorApplication,
  }) {
    switch (key) {
      case GhosttyKey.GHOSTTY_KEY_ENTER:
        return <int>[13];
      case GhosttyKey.GHOSTTY_KEY_TAB:
        return <int>[9];
      case GhosttyKey.GHOSTTY_KEY_BACKSPACE:
        return <int>[127];
      case GhosttyKey.GHOSTTY_KEY_ESCAPE:
        return <int>[27];
      case GhosttyKey.GHOSTTY_KEY_ARROW_UP:
        return utf8.encode(cursorApplication ? '\x1bOA' : '\x1b[A');
      case GhosttyKey.GHOSTTY_KEY_ARROW_DOWN:
        return utf8.encode(cursorApplication ? '\x1bOB' : '\x1b[B');
      case GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT:
        return utf8.encode(cursorApplication ? '\x1bOC' : '\x1b[C');
      case GhosttyKey.GHOSTTY_KEY_ARROW_LEFT:
        return utf8.encode(cursorApplication ? '\x1bOD' : '\x1b[D');
      case GhosttyKey.GHOSTTY_KEY_HOME:
        return utf8.encode(cursorApplication ? '\x1bOH' : '\x1b[H');
      case GhosttyKey.GHOSTTY_KEY_END:
        return utf8.encode(cursorApplication ? '\x1bOF' : '\x1b[F');
      case GhosttyKey.GHOSTTY_KEY_INSERT:
        return utf8.encode('\x1b[2~');
      case GhosttyKey.GHOSTTY_KEY_DELETE:
        return utf8.encode('\x1b[3~');
      case GhosttyKey.GHOSTTY_KEY_PAGE_UP:
        return utf8.encode('\x1b[5~');
      case GhosttyKey.GHOSTTY_KEY_PAGE_DOWN:
        return utf8.encode('\x1b[6~');
      case GhosttyKey.GHOSTTY_KEY_F1:
        return utf8.encode('\x1bOP');
      case GhosttyKey.GHOSTTY_KEY_F2:
        return utf8.encode('\x1bOQ');
      case GhosttyKey.GHOSTTY_KEY_F3:
        return utf8.encode('\x1bOR');
      case GhosttyKey.GHOSTTY_KEY_F4:
        return utf8.encode('\x1bOS');
      case GhosttyKey.GHOSTTY_KEY_F5:
        return utf8.encode('\x1b[15~');
      case GhosttyKey.GHOSTTY_KEY_F6:
        return utf8.encode('\x1b[17~');
      case GhosttyKey.GHOSTTY_KEY_F7:
        return utf8.encode('\x1b[18~');
      case GhosttyKey.GHOSTTY_KEY_F8:
        return utf8.encode('\x1b[19~');
      case GhosttyKey.GHOSTTY_KEY_F9:
        return utf8.encode('\x1b[20~');
      case GhosttyKey.GHOSTTY_KEY_F10:
        return utf8.encode('\x1b[21~');
      case GhosttyKey.GHOSTTY_KEY_F11:
        return utf8.encode('\x1b[23~');
      case GhosttyKey.GHOSTTY_KEY_F12:
        return utf8.encode('\x1b[24~');
      default:
        return null;
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    final rt = _wasm;
    if (rt != null && _handle != 0) {
      rt.callInt('ghostty_key_encoder_free', <Object>[_handle]);
      _handle = 0;
      _wasm = null;
    }
    _closed = true;
  }
}

Never _unsupportedTerminalApi(String member) {
  throw UnsupportedError(
    '$member is not available on web yet. '
    'The wasm runtime currently supports OSC, SGR, key encoding, VT '
    'terminals, and formatters, but this newer VT surface has not been '
    'bridged yet.',
  );
}

final class VtTerminalScrollViewport {
  const VtTerminalScrollViewport._(this._tag, {this.delta = 0});

  const VtTerminalScrollViewport.top() : this._(0);

  const VtTerminalScrollViewport.bottom() : this._(1);

  const VtTerminalScrollViewport.delta(int delta) : this._(2, delta: delta);

  final int _tag;
  final int delta;
}

final class VtFormatterScreenExtra {
  const VtFormatterScreenExtra({
    this.cursor = false,
    this.style = false,
    this.hyperlink = false,
    this.protection = false,
    this.kittyKeyboard = false,
    this.charsets = false,
  });

  const VtFormatterScreenExtra.all()
    : cursor = true,
      style = true,
      hyperlink = true,
      protection = true,
      kittyKeyboard = true,
      charsets = true;

  final bool cursor;
  final bool style;
  final bool hyperlink;
  final bool protection;
  final bool kittyKeyboard;
  final bool charsets;
}

final class VtFormatterTerminalExtra {
  const VtFormatterTerminalExtra({
    this.palette = false,
    this.modes = false,
    this.scrollingRegion = false,
    this.tabstops = false,
    this.pwd = false,
    this.keyboard = false,
    this.screen = const VtFormatterScreenExtra(),
  });

  const VtFormatterTerminalExtra.all()
    : palette = true,
      modes = true,
      scrollingRegion = true,
      tabstops = true,
      pwd = true,
      keyboard = true,
      screen = const VtFormatterScreenExtra.all();

  final bool palette;
  final bool modes;
  final bool scrollingRegion;
  final bool tabstops;
  final bool pwd;
  final bool keyboard;
  final VtFormatterScreenExtra screen;
}

final class VtFormatterTerminalOptions {
  const VtFormatterTerminalOptions({
    this.emit = GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
    this.unwrap = false,
    this.trim = true,
    this.extra = const VtFormatterTerminalExtra(),
  });

  final GhosttyFormatterFormat emit;
  final bool unwrap;
  final bool trim;
  final VtFormatterTerminalExtra extra;
}

final class VtAllocator {
  VtAllocator._();

  static final VtAllocator dartMalloc = VtAllocator._();

  Never get pointer => _unsupportedTerminalApi('VtAllocator.pointer');

  Uint8List copyBytesAndFree(Object ptr, int len) {
    _unsupportedTerminalApi('VtAllocator.copyBytesAndFree');
  }

  void freePointer(Object ptr) {
    _unsupportedTerminalApi('VtAllocator.freePointer');
  }
}

final class VtRenderState {
  VtRenderState._(this._terminal);

  final VtTerminal _terminal;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtRenderState is already closed.');
    }
  }

  void update() {
    _ensureOpen();
    _terminal._ensureOpen();
    _unsupportedTerminalApi('VtRenderState.update');
  }

  VtRenderSnapshot snapshot() {
    _ensureOpen();
    _terminal._ensureOpen();
    _unsupportedTerminalApi('VtRenderState.snapshot');
  }

  void close() {
    _closed = true;
  }
}

final class VtMouseEvent {
  GhosttyMouseAction action = GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS;
  GhosttyMouseButton? button;
  int mods = 0;
  VtMousePosition position = const VtMousePosition(x: 0, y: 0);
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtMouseEvent is already closed.');
    }
  }

  void close() {
    _closed = true;
  }
}

final class VtMouseEncoder {
  GhosttyMouseTrackingMode trackingMode =
      GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NONE;
  GhosttyMouseFormat format = GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR;
  VtMouseEncoderSize size = const VtMouseEncoderSize(
    screenWidth: 1,
    screenHeight: 1,
    cellWidth: 1,
    cellHeight: 1,
  );
  bool anyButtonPressed = false;
  bool trackLastCell = false;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtMouseEncoder is already closed.');
    }
  }

  void setOptionsFromTerminal(VtTerminal terminal) {
    _ensureOpen();
    terminal._ensureOpen();
    _unsupportedTerminalApi('VtMouseEncoder.setOptionsFromTerminal');
  }

  void reset() {
    _ensureOpen();
  }

  Uint8List encode(VtMouseEvent event) {
    _ensureOpen();
    event._ensureOpen();
    _unsupportedTerminalApi('VtMouseEncoder.encode');
  }

  void close() {
    _closed = true;
  }
}

/// Reusable configuration for a [VtMouseEncoder].
final class VtMouseEncoderOptions {
  const VtMouseEncoderOptions({
    required this.trackingMode,
    required this.format,
    required this.size,
    this.anyButtonPressed = false,
    this.trackLastCell = false,
  });

  const VtMouseEncoderOptions.sgr({
    required this.size,
    this.trackingMode = GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL,
    this.anyButtonPressed = false,
    this.trackLastCell = true,
  }) : format = GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR;

  const VtMouseEncoderOptions.sgrPixels({
    required this.size,
    this.trackingMode = GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY,
    this.anyButtonPressed = false,
    this.trackLastCell = true,
  }) : format = GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR_PIXELS;

  final GhosttyMouseTrackingMode trackingMode;
  final GhosttyMouseFormat format;
  final VtMouseEncoderSize size;
  final bool anyButtonPressed;
  final bool trackLastCell;

  /// Applies this option set to [encoder].
  void applyTo(VtMouseEncoder encoder) {
    encoder
      ..trackingMode = trackingMode
      ..format = format
      ..size = size
      ..anyButtonPressed = anyButtonPressed
      ..trackLastCell = trackLastCell;
  }
}

final class VtTerminal {
  VtTerminal({required int cols, required int rows, int maxScrollback = 10_000})
    : _cols = _checkPositiveUint16(cols, 'cols'),
      _rows = _checkPositiveUint16(rows, 'rows'),
      _maxScrollback = _checkNonNegative(maxScrollback, 'maxScrollback'),
      _wasm = _requireTerminalRuntime('VtTerminal') {
    final out = _allocOpaqueOrThrow(_wasm, 'ghostty_wasm_alloc_opaque');
    final optionsPtr = _allocU8ArrayOrThrow(
      _wasm,
      _ghosttyTerminalOptionsSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      _writeTerminalOptions(
        _wasm,
        optionsPtr,
        cols: _cols,
        rows: _rows,
        maxScrollback: _maxScrollback,
      );
      final result = _wasm.callInt('ghostty_terminal_new', <Object>[
        0,
        out,
        optionsPtr,
      ]);
      _checkResult(result, 'ghostty_terminal_new');
      _handle = _wasm.readPtr(out);
    } finally {
      _wasm.freeU8Array(optionsPtr, _ghosttyTerminalOptionsSize);
      _wasm.freeOpaque(out);
    }
  }

  final _GhosttyWasmRuntime _wasm;
  final Set<VtTerminalFormatter> _formatters = <VtTerminalFormatter>{};
  int _handle = 0;
  bool _closed = false;
  int _cols;
  int _rows;
  final int _maxScrollback;

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onWritePty(void Function(Uint8List data)? callback) {
    _unsupportedTerminalApi('VtTerminal.onWritePty');
  }

  /// Not yet supported on the web platform.
  void Function(Uint8List data)? get onWritePty =>
      _unsupportedTerminalApi('VtTerminal.onWritePty');

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onBell(void Function()? callback) {
    _unsupportedTerminalApi('VtTerminal.onBell');
  }

  /// Not yet supported on the web platform.
  void Function()? get onBell => _unsupportedTerminalApi('VtTerminal.onBell');

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onTitleChanged(void Function()? callback) {
    _unsupportedTerminalApi('VtTerminal.onTitleChanged');
  }

  /// Not yet supported on the web platform.
  void Function()? get onTitleChanged =>
      _unsupportedTerminalApi('VtTerminal.onTitleChanged');

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onSizeQuery(VtSizeReportSize? Function()? callback) {
    _unsupportedTerminalApi('VtTerminal.onSizeQuery');
  }

  /// Not yet supported on the web platform.
  VtSizeReportSize? Function()? get onSizeQuery =>
      _unsupportedTerminalApi('VtTerminal.onSizeQuery');

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onColorSchemeQuery(GhosttyColorScheme? Function()? callback) {
    _unsupportedTerminalApi('VtTerminal.onColorSchemeQuery');
  }

  /// Not yet supported on the web platform.
  GhosttyColorScheme? Function()? get onColorSchemeQuery =>
      _unsupportedTerminalApi('VtTerminal.onColorSchemeQuery');

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onDeviceAttributesQuery(VtDeviceAttributes? Function()? callback) {
    _unsupportedTerminalApi('VtTerminal.onDeviceAttributesQuery');
  }

  /// Not yet supported on the web platform.
  VtDeviceAttributes? Function()? get onDeviceAttributesQuery =>
      _unsupportedTerminalApi('VtTerminal.onDeviceAttributesQuery');

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onEnquiry(Uint8List Function()? callback) {
    _unsupportedTerminalApi('VtTerminal.onEnquiry');
  }

  /// Not yet supported on the web platform.
  Uint8List Function()? get onEnquiry =>
      _unsupportedTerminalApi('VtTerminal.onEnquiry');

  /// Not yet supported on the web platform.
  // ignore: use_setters_to_change_properties
  set onXtversion(String Function()? callback) {
    _unsupportedTerminalApi('VtTerminal.onXtversion');
  }

  /// Not yet supported on the web platform.
  String Function()? get onXtversion =>
      _unsupportedTerminalApi('VtTerminal.onXtversion');

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtTerminal is already closed.');
    }
  }

  void _detachFormatter(VtTerminalFormatter formatter) {
    _formatters.remove(formatter);
  }

  int get cols {
    _ensureOpen();
    return _cols;
  }

  int get rows {
    _ensureOpen();
    return _rows;
  }

  int get maxScrollback {
    _ensureOpen();
    return _maxScrollback;
  }

  int get cursorX {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.cursorX');
  }

  int get cursorY {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.cursorY');
  }

  bool get cursorPendingWrap {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.cursorPendingWrap');
  }

  GhosttyTerminalScreen get activeScreen {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.activeScreen');
  }

  bool get cursorVisible {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.cursorVisible');
  }

  String get title {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.title');
  }

  String get pwd {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.pwd');
  }

  /// Web currently does not expose direct terminal mode queries.
  ///
  /// Return `false` so higher-level widgets can safely disable optional
  /// mode-dependent behavior such as mouse tracking.
  bool getMode(VtMode mode) {
    _ensureOpen();
    return false;
  }

  bool get mouseTracking {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.mouseTracking');
  }

  int get totalRows {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.totalRows');
  }

  int get scrollbackRows {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.scrollbackRows');
  }

  int get widthPx {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.widthPx');
  }

  int get heightPx {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.heightPx');
  }

  /// The effective foreground color, including OSC overrides when present.
  VtRgbColor? get foregroundColor =>
      _terminalRgb(_ghosttyTerminalDataColorForeground);

  /// The effective background color, including OSC overrides when present.
  VtRgbColor? get backgroundColor =>
      _terminalRgb(_ghosttyTerminalDataColorBackground);

  /// The effective cursor color, including OSC overrides when present.
  VtRgbColor? get cursorColor => _terminalRgb(_ghosttyTerminalDataColorCursor);

  /// The effective 256-color palette, including OSC overrides.
  List<VtRgbColor> get colorPalette =>
      _terminalPalette(_ghosttyTerminalDataColorPalette);

  /// The default foreground color, ignoring OSC overrides.
  VtRgbColor? get defaultForegroundColor =>
      _terminalRgb(_ghosttyTerminalDataColorForegroundDefault);

  set defaultForegroundColor(VtRgbColor? value) {
    _terminalSetRgb(_ghosttyTerminalOptColorForeground, value);
  }

  /// The default background color, ignoring OSC overrides.
  VtRgbColor? get defaultBackgroundColor =>
      _terminalRgb(_ghosttyTerminalDataColorBackgroundDefault);

  set defaultBackgroundColor(VtRgbColor? value) {
    _terminalSetRgb(_ghosttyTerminalOptColorBackground, value);
  }

  /// The default cursor color, ignoring OSC overrides.
  VtRgbColor? get defaultCursorColor =>
      _terminalRgb(_ghosttyTerminalDataColorCursorDefault);

  set defaultCursorColor(VtRgbColor? value) {
    _terminalSetRgb(_ghosttyTerminalOptColorCursor, value);
  }

  /// The default 256-color palette, ignoring OSC overrides.
  List<VtRgbColor> get defaultPalette =>
      _terminalPalette(_ghosttyTerminalDataColorPaletteDefault);

  set defaultPalette(List<VtRgbColor>? value) {
    _terminalSetPalette(_ghosttyTerminalOptColorPalette, value);
  }

  /// The current effective terminal colors and palette.
  VtTerminalColors get effectiveColors => VtTerminalColors(
    foreground: foregroundColor,
    background: backgroundColor,
    cursor: cursorColor,
    palette: colorPalette,
  );

  /// The configured default terminal colors and palette.
  VtTerminalColors get defaultColors => VtTerminalColors(
    foreground: defaultForegroundColor,
    background: defaultBackgroundColor,
    cursor: defaultCursorColor,
    palette: defaultPalette,
  );

  int get kittyKeyboardFlags {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.kittyKeyboardFlags');
  }

  VtTerminalScrollbar get scrollbar {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.scrollbar');
  }

  VtStyle get cursorStyle {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.cursorStyle');
  }

  VtRgbColor? _terminalRgb(int data) {
    final out = _allocU8ArrayOrThrow(
      _wasm,
      _ghosttyColorRgbSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      final result = _wasm.callInt('ghostty_terminal_get', <Object>[
        _handle,
        data,
        out,
      ]);
      if (result == GhosttyResult.GHOSTTY_NO_VALUE.value) {
        return null;
      }
      _checkResult(result, 'ghostty_terminal_get');
      return _readRgb(_wasm, out);
    } finally {
      _wasm.freeU8Array(out, _ghosttyColorRgbSize);
    }
  }

  List<VtRgbColor> _terminalPalette(int data) {
    final out = _allocU8ArrayOrThrow(
      _wasm,
      _ghosttyColorPaletteSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      _checkResult(
        _wasm.callInt('ghostty_terminal_get', <Object>[_handle, data, out]),
        'ghostty_terminal_get',
      );
      return _readPalette(_wasm, out);
    } finally {
      _wasm.freeU8Array(out, _ghosttyColorPaletteSize);
    }
  }

  void _terminalSetRgb(int option, VtRgbColor? value) {
    _ensureOpen();
    if (value == null) {
      _wasm.callInt('ghostty_terminal_set', <Object>[_handle, option, 0]);
      return;
    }
    final native = _allocU8ArrayOrThrow(
      _wasm,
      _ghosttyColorRgbSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      _writeRgb(_wasm, native, value);
      _wasm.callInt('ghostty_terminal_set', <Object>[_handle, option, native]);
    } finally {
      _wasm.freeU8Array(native, _ghosttyColorRgbSize);
    }
  }

  void _terminalSetPalette(int option, List<VtRgbColor>? value) {
    _ensureOpen();
    if (value == null) {
      _wasm.callInt('ghostty_terminal_set', <Object>[_handle, option, 0]);
      return;
    }
    if (value.length != _ghosttyColorPaletteLength) {
      throw ArgumentError.value(
        value.length,
        'value.length',
        'Palette must contain exactly 256 colors.',
      );
    }
    final native = _allocU8ArrayOrThrow(
      _wasm,
      _ghosttyColorPaletteSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      for (var i = 0; i < value.length; i++) {
        _writeRgb(_wasm, native + (i * _ghosttyColorRgbSize), value[i]);
      }
      _wasm.callInt('ghostty_terminal_set', <Object>[_handle, option, native]);
    } finally {
      _wasm.freeU8Array(native, _ghosttyColorPaletteSize);
    }
  }

  void writeBytes(List<int> bytes) {
    _ensureOpen();
    if (bytes.isEmpty) {
      return;
    }
    final dataPtr = _allocU8ArrayOrThrow(
      _wasm,
      bytes.length,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      _wasm.u8View(dataPtr, bytes.length).setAll(0, bytes);
      _wasm.callInt('ghostty_terminal_vt_write', <Object>[
        _handle,
        dataPtr,
        bytes.length,
      ]);
    } finally {
      _wasm.freeU8Array(dataPtr, bytes.length);
    }
  }

  void write(String text, {Encoding encoding = utf8}) {
    writeBytes(encoding.encode(text));
  }

  void reset() {
    _ensureOpen();
    _wasm.callInt('ghostty_terminal_reset', <Object>[_handle]);
  }

  /// Resizes the terminal to the given cell dimensions.
  ///
  /// [cellWidthPx] and [cellHeightPx] specify the pixel dimensions of a
  /// single cell, used for pixel-based size reporting. They default to 0.
  void resize({
    required int cols,
    required int rows,
    int cellWidthPx = 0,
    int cellHeightPx = 0,
  }) {
    _ensureOpen();
    final checkedCols = _checkPositiveUint16(cols, 'cols');
    final checkedRows = _checkPositiveUint16(rows, 'rows');
    final result = _wasm.callInt('ghostty_terminal_resize', <Object>[
      _handle,
      checkedCols,
      checkedRows,
      cellWidthPx,
      cellHeightPx,
    ]);
    _checkResult(result, 'ghostty_terminal_resize');
    _cols = checkedCols;
    _rows = checkedRows;
  }

  void scrollViewport(VtTerminalScrollViewport behavior) {
    _ensureOpen();
    final behaviorPtr = _allocU8ArrayOrThrow(
      _wasm,
      _ghosttyTerminalScrollViewportSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      _wasm.writeU32(behaviorPtr, behavior._tag);
      if (behavior._tag == 2) {
        _wasm.writeI32(behaviorPtr + 8, behavior.delta);
      }
      _wasm.callInt('ghostty_terminal_scroll_viewport', <Object>[
        _handle,
        behaviorPtr,
      ]);
    } finally {
      _wasm.freeU8Array(behaviorPtr, _ghosttyTerminalScrollViewportSize);
    }
  }

  void scrollToTop() {
    scrollViewport(const VtTerminalScrollViewport.top());
  }

  void scrollToBottom() {
    scrollViewport(const VtTerminalScrollViewport.bottom());
  }

  void scrollBy(int delta) {
    scrollViewport(VtTerminalScrollViewport.delta(delta));
  }

  VtTerminalFormatter createFormatter([
    VtFormatterTerminalOptions options = const VtFormatterTerminalOptions(),
  ]) {
    _ensureOpen();
    final formatter = VtTerminalFormatter._(this, options);
    _formatters.add(formatter);
    return formatter;
  }

  VtGridRefSnapshot gridRef(VtPoint point) {
    _ensureOpen();
    _unsupportedTerminalApi('VtTerminal.gridRef');
  }

  VtRenderState createRenderState() {
    _ensureOpen();
    return VtRenderState._(this);
  }

  void close() {
    if (_closed) {
      return;
    }
    for (final formatter in List<VtTerminalFormatter>.from(_formatters)) {
      formatter.close();
    }
    _wasm.callInt('ghostty_terminal_free', <Object>[_handle]);
    _handle = 0;
    _closed = true;
  }
}

final class VtTerminalFormatter {
  VtTerminalFormatter._(VtTerminal terminal, VtFormatterTerminalOptions options)
    : _terminal = terminal,
      _wasm = terminal._wasm {
    final out = _allocOpaqueOrThrow(_wasm, 'ghostty_wasm_alloc_opaque');
    final optionsPtr = _allocU8ArrayOrThrow(
      _wasm,
      _ghosttyFormatterTerminalOptionsSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      _writeFormatterTerminalOptions(_wasm, optionsPtr, options);
      final result = _wasm.callInt('ghostty_formatter_terminal_new', <Object>[
        0,
        out,
        _terminal._handle,
        optionsPtr,
      ]);
      _checkResult(result, 'ghostty_formatter_terminal_new');
      _handle = _wasm.readPtr(out);
    } finally {
      _wasm.freeU8Array(optionsPtr, _ghosttyFormatterTerminalOptionsSize);
      _wasm.freeOpaque(out);
    }
  }

  final VtTerminal _terminal;
  final _GhosttyWasmRuntime _wasm;
  int _handle = 0;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtTerminalFormatter is already closed.');
    }
  }

  int _requiredSize() {
    final outWritten = _wasm.allocUsize();
    if (outWritten == 0) {
      throw GhosttyVtError(
        'ghostty_wasm_alloc_usize',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }
    try {
      final result = _wasm.callInt('ghostty_formatter_format_buf', <Object>[
        _handle,
        0,
        0,
        outWritten,
      ]);
      if (result == GhosttyResult.GHOSTTY_SUCCESS.value) {
        return _wasm.readUsize(outWritten);
      }
      if (result != GhosttyResult.GHOSTTY_OUT_OF_SPACE.value) {
        _checkResult(result, 'ghostty_formatter_format_buf(size_probe)');
      }
      return _wasm.readUsize(outWritten);
    } finally {
      _wasm.freeUsize(outWritten);
    }
  }

  Uint8List formatBytes() {
    _ensureOpen();
    _terminal._ensureOpen();

    var required = _requiredSize();
    if (required == 0) {
      return Uint8List(0);
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      final outWritten = _wasm.allocUsize();
      if (outWritten == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_usize',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      final allocated = required;
      final buffer = _allocU8ArrayOrThrow(
        _wasm,
        allocated,
        'ghostty_wasm_alloc_u8_array',
      );
      try {
        final result = _wasm.callInt('ghostty_formatter_format_buf', <Object>[
          _handle,
          buffer,
          allocated,
          outWritten,
        ]);
        if (result == GhosttyResult.GHOSTTY_SUCCESS.value) {
          final written = _wasm.readUsize(outWritten);
          return Uint8List.fromList(_wasm.u8View(buffer, written));
        }
        if (result != GhosttyResult.GHOSTTY_OUT_OF_SPACE.value) {
          _checkResult(result, 'ghostty_formatter_format_buf');
        }
        required = _wasm.readUsize(outWritten);
        if (required == 0) {
          return Uint8List(0);
        }
      } finally {
        _wasm.freeU8Array(buffer, allocated);
        _wasm.freeUsize(outWritten);
      }
    }

    throw StateError(
      'VtTerminalFormatter output changed while formatting. Retry the call.',
    );
  }

  Uint8List formatBytesAllocated() {
    return formatBytesAllocatedWith(VtAllocator.dartMalloc);
  }

  Uint8List formatBytesAllocatedWith(VtAllocator allocator) {
    allocator;
    _ensureOpen();
    _terminal._ensureOpen();

    final outPtr = _allocOpaqueOrThrow(_wasm, 'ghostty_wasm_alloc_opaque');
    final outLen = _wasm.allocUsize();
    if (outLen == 0) {
      _wasm.freeOpaque(outPtr);
      throw GhosttyVtError(
        'ghostty_wasm_alloc_usize',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }
    try {
      final result = _wasm.callInt('ghostty_formatter_format_alloc', <Object>[
        _handle,
        0,
        outPtr,
        outLen,
      ]);
      _checkResult(result, 'ghostty_formatter_format_alloc');

      final ptr = _wasm.readPtr(outPtr);
      final len = _wasm.readUsize(outLen);
      if (ptr == 0 || len == 0) {
        if (ptr != 0) {
          _wasm.freeU8Array(ptr, len);
        }
        return Uint8List(0);
      }

      final bytes = Uint8List.fromList(_wasm.u8View(ptr, len));
      _wasm.freeU8Array(ptr, len);
      return bytes;
    } finally {
      _wasm.freeUsize(outLen);
      _wasm.freeOpaque(outPtr);
    }
  }

  String formatText({Encoding encoding = utf8}) {
    final bytes = formatBytes();
    if (encoding == utf8) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return encoding.decode(bytes);
  }

  String formatTextAllocated({Encoding encoding = utf8}) {
    return formatTextAllocatedWith(VtAllocator.dartMalloc, encoding: encoding);
  }

  String formatTextAllocatedWith(
    VtAllocator allocator, {
    Encoding encoding = utf8,
  }) {
    final bytes = formatBytesAllocatedWith(allocator);
    if (encoding == utf8) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return encoding.decode(bytes);
  }

  void close() {
    if (_closed) {
      return;
    }
    _wasm.callInt('ghostty_formatter_free', <Object>[_handle]);
    _handle = 0;
    _terminal._detachFormatter(this);
    _closed = true;
  }
}

final class GhosttyVt {
  const GhosttyVt._();

  /// Compile-time build metadata for the loaded libghostty-vt library.
  static VtBuildInfo get buildInfo {
    final rt = _requireTerminalRuntime('GhosttyVt.buildInfo');
    return VtBuildInfo(
      simd: _buildInfoBool(rt, _ghosttyBuildInfoSimd),
      kittyGraphics: _buildInfoBool(rt, _ghosttyBuildInfoKittyGraphics),
      tmuxControlMode: _buildInfoBool(rt, _ghosttyBuildInfoTmuxControlMode),
      optimize: _buildInfoOptimize(rt, _ghosttyBuildInfoOptimize),
      versionString: _buildInfoString(rt, _ghosttyBuildInfoVersionString),
      versionMajor: _buildInfoSize(rt, _ghosttyBuildInfoVersionMajor),
      versionMinor: _buildInfoSize(rt, _ghosttyBuildInfoVersionMinor),
      versionPatch: _buildInfoSize(rt, _ghosttyBuildInfoVersionPatch),
      versionBuild: _buildInfoString(rt, _ghosttyBuildInfoVersionBuild),
    );
  }

  static bool isPasteSafe(String text) {
    return isPasteSafeBytes(utf8.encode(text));
  }

  static bool isPasteSafeBytes(List<int> bytes) {
    final rt = _runtime();
    if (rt != null) {
      if (bytes.isEmpty) {
        return true;
      }
      final dataPtr = rt.allocU8Array(bytes.length);
      if (dataPtr == 0) {
        throw GhosttyVtError(
          'ghostty_wasm_alloc_u8_array',
          GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
        );
      }
      try {
        rt.u8View(dataPtr, bytes.length).setAll(0, bytes);
        return rt.callBool('ghostty_paste_is_safe', <Object>[
          dataPtr,
          bytes.length,
        ]);
      } finally {
        rt.freeU8Array(dataPtr, bytes.length);
      }
    }

    // Fallback for web usage prior to wasm initialization.
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0x0A) {
        return false;
      }
      if (i + 5 < bytes.length &&
          bytes[i] == 0x1B &&
          bytes[i + 1] == 0x5B &&
          bytes[i + 2] == 0x32 &&
          bytes[i + 3] == 0x30 &&
          bytes[i + 4] == 0x31 &&
          bytes[i + 5] == 0x7E) {
        return false;
      }
    }
    return true;
  }

  /// Encodes paste bytes for terminal input.
  ///
  /// Unsafe control bytes are rewritten, and bracketed paste markers are
  /// added when [bracketed] is true.
  static Uint8List encodePasteBytes(List<int> bytes, {bool bracketed = false}) {
    final rt = _requireTerminalRuntime('GhosttyVt.encodePasteBytes');
    final dataPtr = bytes.isEmpty
        ? 0
        : _allocU8ArrayOrThrow(rt, bytes.length, 'ghostty_wasm_alloc_u8_array');
    final outWritten = rt.allocUsize();
    if (outWritten == 0) {
      if (dataPtr != 0) {
        rt.freeU8Array(dataPtr, bytes.length);
      }
      throw GhosttyVtError(
        'ghostty_wasm_alloc_usize',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }

    try {
      if (dataPtr != 0) {
        rt.u8View(dataPtr, bytes.length).setAll(0, bytes);
      }
      final first = rt.callInt('ghostty_paste_encode', <Object>[
        dataPtr,
        bytes.length,
        bracketed,
        0,
        0,
        outWritten,
      ]);
      if (first != GhosttyResult.GHOSTTY_OUT_OF_SPACE.value &&
          first != GhosttyResult.GHOSTTY_SUCCESS.value) {
        _checkResult(first, 'ghostty_paste_encode(size_probe)');
      }
      final required = rt.readUsize(outWritten);
      if (required == 0) {
        return Uint8List(0);
      }

      final output = _allocU8ArrayOrThrow(
        rt,
        required,
        'ghostty_wasm_alloc_u8_array',
      );
      try {
        final second = rt.callInt('ghostty_paste_encode', <Object>[
          dataPtr,
          bytes.length,
          bracketed,
          output,
          required,
          outWritten,
        ]);
        _checkResult(second, 'ghostty_paste_encode');
        final written = rt.readUsize(outWritten);
        return Uint8List.fromList(rt.u8View(output, written));
      } finally {
        rt.freeU8Array(output, required);
      }
    } finally {
      rt.freeUsize(outWritten);
      if (dataPtr != 0) {
        rt.freeU8Array(dataPtr, bytes.length);
      }
    }
  }

  /// Encodes [text] for terminal paste input.
  static String encodePaste(
    String text, {
    bool bracketed = false,
    Encoding encoding = utf8,
  }) {
    final bytes = encodePasteBytes(encoding.encode(text), bracketed: bracketed);
    if (encoding == utf8) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return encoding.decode(bytes);
  }

  static VtOscParser newOscParser() => VtOscParser();
  static VtSgrParser newSgrParser() => VtSgrParser();
  static VtKeyEvent newKeyEvent() => VtKeyEvent();
  static VtKeyEncoder newKeyEncoder() => VtKeyEncoder();
  static VtMouseEvent newMouseEvent() => VtMouseEvent();
  static VtMouseEncoder newMouseEncoder() => VtMouseEncoder();

  static Uint8List encodeFocus(GhosttyFocusEvent event) {
    return Uint8List.fromList(
      ascii.encode(
        event == GhosttyFocusEvent.GHOSTTY_FOCUS_GAINED ? '\x1b[I' : '\x1b[O',
      ),
    );
  }

  static Uint8List encodeModeReport(VtMode mode, GhosttyModeReportState state) {
    final prefix = mode.ansi ? '' : '?';
    return Uint8List.fromList(
      ascii.encode('\x1b[$prefix${mode.mode};${state.value}\$y'),
    );
  }

  static Uint8List encodeSizeReport(
    GhosttySizeReportStyle style,
    VtSizeReportSize size,
  ) {
    final sequence = switch (style) {
      GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_MODE_2048 =>
        '\x1b[48;${size.rows};${size.columns};${size.cellHeight};${size.cellWidth}t',
      GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_14_T =>
        '\x1b[4;${size.cellHeight * size.rows};${size.cellWidth * size.columns}t',
      GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_16_T =>
        '\x1b[6;${size.cellHeight};${size.cellWidth}t',
      GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_18_T =>
        '\x1b[8;${size.rows};${size.columns}t',
    };
    return Uint8List.fromList(ascii.encode(sequence));
  }

  static VtTerminal newTerminal({
    required int cols,
    required int rows,
    int maxScrollback = 10_000,
  }) => VtTerminal(cols: cols, rows: rows, maxScrollback: maxScrollback);

  static bool _buildInfoBool(_GhosttyWasmRuntime rt, int data) {
    final out = rt.allocU8();
    if (out == 0) {
      throw GhosttyVtError(
        'ghostty_wasm_alloc_u8',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }
    try {
      _checkResult(
        rt.callInt('ghostty_build_info', <Object>[data, out]),
        'ghostty_build_info',
      );
      return rt.readU8(out) != 0;
    } finally {
      rt.freeU8(out);
    }
  }

  static int _buildInfoSize(_GhosttyWasmRuntime rt, int data) {
    final out = rt.allocUsize();
    if (out == 0) {
      throw GhosttyVtError(
        'ghostty_wasm_alloc_usize',
        GhosttyResult.GHOSTTY_OUT_OF_MEMORY,
      );
    }
    try {
      _checkResult(
        rt.callInt('ghostty_build_info', <Object>[data, out]),
        'ghostty_build_info',
      );
      return rt.readUsize(out);
    } finally {
      rt.freeUsize(out);
    }
  }

  static String _buildInfoString(_GhosttyWasmRuntime rt, int data) {
    final out = _allocU8ArrayOrThrow(
      rt,
      _ghosttyStringSize,
      'ghostty_wasm_alloc_u8_array',
    );
    try {
      _checkResult(
        rt.callInt('ghostty_build_info', <Object>[data, out]),
        'ghostty_build_info',
      );
      return _readGhosttyString(rt, out);
    } finally {
      rt.freeU8Array(out, _ghosttyStringSize);
    }
  }

  static GhosttyOptimizeMode _buildInfoOptimize(
    _GhosttyWasmRuntime rt,
    int data,
  ) {
    final out = _allocU8ArrayOrThrow(rt, 4, 'ghostty_wasm_alloc_u8_array');
    try {
      _checkResult(
        rt.callInt('ghostty_build_info', <Object>[data, out]),
        'ghostty_build_info',
      );
      return GhosttyOptimizeMode.fromValue(rt.readUsize(out));
    } finally {
      rt.freeU8Array(out, 4);
    }
  }
}
