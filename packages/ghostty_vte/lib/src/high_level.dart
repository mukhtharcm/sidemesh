import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ghostty_vte_bindings_generated.dart' as bindings;

/// High-level helpers and wrappers on top of libghostty-vt FFI bindings.
///
/// Provides factory methods for OSC/SGR parsers, terminals, formatters,
/// key events, and key encoders, as well as paste-safety checks.
///
/// ```dart
/// // Create a terminal and formatter
/// final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
/// final formatter = terminal.createFormatter(
///   const VtFormatterTerminalOptions(
///     emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
///     trim: true,
///   ),
/// );
/// terminal.write('Hello');
/// print(formatter.formatText());
/// formatter.close();
/// terminal.close();
///
/// // Check paste safety
/// if (GhosttyVt.isPasteSafe(clipboardText)) {
///   terminal.write(clipboardText);
/// }
///
/// // Create a key encoder
/// final encoder = GhosttyVt.newKeyEncoder();
/// final event = GhosttyVt.newKeyEvent();
/// // ... configure event ...
/// final bytes = encoder.encode(event);
/// event.close();
/// encoder.close();
/// ```
final class GhosttyVt {
  const GhosttyVt._();

  /// Compile-time build metadata for the loaded libghostty-vt library.
  static VtBuildInfo get buildInfo => VtBuildInfo(
    simd: _buildInfoBool(bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_SIMD),
    kittyGraphics: _buildInfoBool(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_KITTY_GRAPHICS,
    ),
    tmuxControlMode: _buildInfoBool(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE,
    ),
    optimize: _buildInfoOptimize(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_OPTIMIZE,
    ),
    versionString: _buildInfoString(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_STRING,
    ),
    versionMajor: _buildInfoSize(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_MAJOR,
    ),
    versionMinor: _buildInfoSize(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_MINOR,
    ),
    versionPatch: _buildInfoSize(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_PATCH,
    ),
    versionBuild: _buildInfoString(
      bindings.GhosttyBuildInfo.GHOSTTY_BUILD_INFO_VERSION_BUILD,
    ),
  );

  /// Returns whether [text] is safe to paste into a terminal.
  ///
  /// Checks for dangerous control characters that could execute
  /// unintended commands.
  ///
  /// ```dart
  /// final safe = GhosttyVt.isPasteSafe('ls -la');
  /// assert(safe == true);
  /// ```
  static bool isPasteSafe(String text) {
    final bytes = utf8.encode(text);
    return isPasteSafeBytes(bytes);
  }

  /// Returns whether raw UTF-8 bytes are safe to paste into a terminal.
  static bool isPasteSafeBytes(List<int> bytes) {
    final ptr = calloc<ffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return bindings.ghostty_paste_is_safe(ptr.cast<ffi.Char>(), bytes.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Encodes paste bytes for terminal input.
  ///
  /// Unsafe control bytes are rewritten, and bracketed paste markers are
  /// added when [bracketed] is true.
  static Uint8List encodePasteBytes(List<int> bytes, {bool bracketed = false}) {
    final mutable = Uint8List.fromList(bytes);
    final input = calloc<ffi.Char>(mutable.length);
    final outWritten = calloc<ffi.Size>();
    try {
      if (mutable.isNotEmpty) {
        input.cast<ffi.Uint8>().asTypedList(mutable.length).setAll(0, mutable);
      }
      final first = bindings.ghostty_paste_encode(
        input,
        mutable.length,
        bracketed,
        ffi.nullptr,
        0,
        outWritten,
      );
      if (first != bindings.GhosttyResult.GHOSTTY_OUT_OF_SPACE &&
          first != bindings.GhosttyResult.GHOSTTY_SUCCESS) {
        _checkResult(first, 'ghostty_paste_encode(size_probe)');
      }
      final required = outWritten.value;
      if (required == 0) {
        return Uint8List(0);
      }

      final output = calloc<ffi.Char>(required);
      try {
        final second = bindings.ghostty_paste_encode(
          input,
          mutable.length,
          bracketed,
          output,
          required,
          outWritten,
        );
        _checkResult(second, 'ghostty_paste_encode');
        return Uint8List.fromList(
          output.cast<ffi.Uint8>().asTypedList(outWritten.value),
        );
      } finally {
        calloc.free(output);
      }
    } finally {
      calloc.free(outWritten);
      calloc.free(input);
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

  /// Creates a streaming OSC parser.
  static VtOscParser newOscParser() => VtOscParser();

  /// Creates an SGR parser.
  static VtSgrParser newSgrParser() => VtSgrParser();

  /// Creates a key event object.
  static VtKeyEvent newKeyEvent() => VtKeyEvent();

  /// Creates a key encoder object.
  static VtKeyEncoder newKeyEncoder() => VtKeyEncoder();

  /// Creates a terminal emulator instance.
  static VtTerminal newTerminal({
    required int cols,
    required int rows,
    int maxScrollback = 10_000,
  }) => VtTerminal(cols: cols, rows: rows, maxScrollback: maxScrollback);

  /// Creates a mouse event object.
  static VtMouseEvent newMouseEvent() => VtMouseEvent();

  /// Creates a mouse encoder object.
  static VtMouseEncoder newMouseEncoder() => VtMouseEncoder();

  /// Encodes a terminal focus event into bytes.
  static Uint8List encodeFocus(bindings.GhosttyFocusEvent event) {
    return _encodeCharSequence(
      'ghostty_focus_encode',
      (buffer, length, outWritten) =>
          bindings.ghostty_focus_encode(event, buffer, length, outWritten),
    );
  }

  /// Encodes a DECRPM/ANSI mode report into bytes.
  static Uint8List encodeModeReport(
    VtMode mode,
    bindings.GhosttyModeReportState state,
  ) {
    return _encodeCharSequence(
      'ghostty_mode_report_encode',
      (buffer, length, outWritten) => bindings.ghostty_mode_report_encode(
        mode.packed,
        state,
        buffer,
        length,
        outWritten,
      ),
    );
  }

  /// Encodes a terminal size report into bytes.
  static Uint8List encodeSizeReport(
    bindings.GhosttySizeReportStyle style,
    VtSizeReportSize size,
  ) {
    final nativeSize = calloc<bindings.GhosttySizeReportSize>();
    try {
      size._writeTo(nativeSize.ref);
      return _encodeCharSequence(
        'ghostty_size_report_encode',
        (buffer, length, outWritten) => bindings.ghostty_size_report_encode(
          style,
          nativeSize.ref,
          buffer,
          length,
          outWritten,
        ),
      );
    } finally {
      calloc.free(nativeSize);
    }
  }

  static bool _buildInfoBool(bindings.GhosttyBuildInfo data) {
    final out = calloc<ffi.Bool>();
    try {
      _checkResult(bindings.ghostty_build_info(data, out.cast()), 'build_info');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  static int _buildInfoSize(bindings.GhosttyBuildInfo data) {
    final out = calloc<ffi.Size>();
    try {
      _checkResult(bindings.ghostty_build_info(data, out.cast()), 'build_info');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  static String _buildInfoString(bindings.GhosttyBuildInfo data) {
    final out = calloc<bindings.GhosttyString>();
    try {
      _checkResult(bindings.ghostty_build_info(data, out.cast()), 'build_info');
      final len = out.ref.len;
      if (len == 0) {
        return '';
      }
      return utf8.decode(out.ref.ptr.asTypedList(len), allowMalformed: true);
    } finally {
      calloc.free(out);
    }
  }

  static bindings.GhosttyOptimizeMode _buildInfoOptimize(
    bindings.GhosttyBuildInfo data,
  ) {
    final out = calloc<ffi.UnsignedInt>();
    try {
      _checkResult(bindings.ghostty_build_info(data, out.cast()), 'build_info');
      return bindings.GhosttyOptimizeMode.fromValue(out.value);
    } finally {
      calloc.free(out);
    }
  }
}

/// Exception thrown for libghostty-vt operation failures.
///
/// Contains the failed [operation] name and the native [result] code.
final class GhosttyVtError implements Exception {
  GhosttyVtError(this.operation, this.result);

  final String operation;
  final bindings.GhosttyResult result;

  @override
  String toString() {
    return 'GhosttyVtError(operation: $operation, result: $result)';
  }
}

void _checkResult(bindings.GhosttyResult result, String operation) {
  if (result != bindings.GhosttyResult.GHOSTTY_SUCCESS) {
    throw GhosttyVtError(operation, result);
  }
}

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

Uint8List _encodeCharSequence(
  String operation,
  bindings.GhosttyResult Function(
    ffi.Pointer<ffi.Char> buffer,
    int length,
    ffi.Pointer<ffi.Size> outWritten,
  )
  invoke,
) {
  final outWritten = calloc<ffi.Size>();
  try {
    final first = invoke(ffi.nullptr, 0, outWritten);
    if (first != bindings.GhosttyResult.GHOSTTY_OUT_OF_SPACE &&
        first != bindings.GhosttyResult.GHOSTTY_SUCCESS) {
      _checkResult(first, '$operation(size_probe)');
    }
    final required = outWritten.value;
    if (required == 0) {
      return Uint8List(0);
    }

    final buffer = calloc<ffi.Char>(required);
    try {
      final secondOutWritten = calloc<ffi.Size>();
      try {
        final second = invoke(buffer, required, secondOutWritten);
        _checkResult(second, operation);
        return Uint8List.fromList(
          buffer.cast<ffi.Uint8>().asTypedList(secondOutWritten.value),
        );
      } finally {
        calloc.free(secondOutWritten);
      }
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(outWritten);
  }
}

VtRgbColor _rgbFromNative(bindings.GhosttyColorRgb native) {
  return VtRgbColor.fromNative(native);
}

void _writeRgbToNative(VtRgbColor color, bindings.GhosttyColorRgb native) {
  native
    ..r = color.r
    ..g = color.g
    ..b = color.b;
}

List<VtRgbColor> _rgbPaletteFromNative(
  ffi.Pointer<bindings.GhosttyColorRgb> native,
) {
  return List<VtRgbColor>.unmodifiable(
    List<VtRgbColor>.generate(
      256,
      (index) => _rgbFromNative((native + index).ref),
    ),
  );
}

void _writeStyleColorToNative(
  VtStyleColor color,
  bindings.GhosttyStyleColor native,
) {
  native.tagAsInt = color.tag.value;
  switch (color.tag) {
    case bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE:
      native.value.palette = 0;
    case bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE:
      native.value.palette = color.paletteIndex ?? 0;
    case bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB:
      final rgb = color.rgb ?? const VtRgbColor(0, 0, 0);
      native.value.rgb
        ..r = rgb.r
        ..g = rgb.g
        ..b = rgb.b;
  }
}

typedef _GhosttyAllocatorAllocNative =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> ctx,
      ffi.Size len,
      ffi.Uint8 alignment,
      ffi.UintPtr retAddr,
    );

typedef _GhosttyAllocatorResizeNative =
    ffi.Bool Function(
      ffi.Pointer<ffi.Void> ctx,
      ffi.Pointer<ffi.Void> memory,
      ffi.Size memoryLen,
      ffi.Uint8 alignment,
      ffi.Size newLen,
      ffi.UintPtr retAddr,
    );

typedef _GhosttyAllocatorRemapNative =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> ctx,
      ffi.Pointer<ffi.Void> memory,
      ffi.Size memoryLen,
      ffi.Uint8 alignment,
      ffi.Size newLen,
      ffi.UintPtr retAddr,
    );

typedef _GhosttyAllocatorFreeNative =
    ffi.Void Function(
      ffi.Pointer<ffi.Void> ctx,
      ffi.Pointer<ffi.Void> memory,
      ffi.Size memoryLen,
      ffi.Uint8 alignment,
      ffi.UintPtr retAddr,
    );

/// Native allocator bridge for advanced libghostty-vt usage.
///
/// `VtAllocator.dartMalloc` uses Dart's `malloc`/`free` underneath and can be
/// passed to raw generated bindings that accept a `GhosttyAllocator*`.
///
/// Most callers should use the higher-level helpers on [VtTerminalFormatter]
/// instead of interacting with this directly.
final class VtAllocator {
  VtAllocator._(this.pointer);

  /// Allocator backed by Dart's `malloc`/`free`.
  static final VtAllocator dartMalloc = VtAllocator._(_create());

  /// Native allocator pointer suitable for generated bindings.
  final ffi.Pointer<bindings.GhosttyAllocator> pointer;

  static ffi.Pointer<bindings.GhosttyAllocator> _create() {
    final vtable = calloc<bindings.GhosttyAllocatorVtable>();
    final allocator = calloc<bindings.GhosttyAllocator>();

    vtable.ref
      ..alloc = ffi.Pointer.fromFunction<_GhosttyAllocatorAllocNative>(_alloc)
      ..resize = ffi.Pointer.fromFunction<_GhosttyAllocatorResizeNative>(
        _resize,
        false,
      )
      ..remap = ffi.Pointer.fromFunction<_GhosttyAllocatorRemapNative>(_remap)
      ..free = ffi.Pointer.fromFunction<_GhosttyAllocatorFreeNative>(_free);

    allocator.ref
      ..ctx = ffi.nullptr
      ..vtable = vtable;

    return allocator;
  }

  static ffi.Pointer<ffi.Void> _alloc(
    ffi.Pointer<ffi.Void> ctx,
    int len,
    int alignment,
    int retAddr,
  ) {
    if (len <= 0) {
      return ffi.nullptr;
    }
    try {
      return malloc
          .allocate<ffi.Uint8>(len, alignment: alignment)
          .cast<ffi.Void>();
    } catch (_) {
      return ffi.nullptr;
    }
  }

  static bool _resize(
    ffi.Pointer<ffi.Void> ctx,
    ffi.Pointer<ffi.Void> memory,
    int memoryLen,
    int alignment,
    int newLen,
    int retAddr,
  ) {
    return false;
  }

  static ffi.Pointer<ffi.Void> _remap(
    ffi.Pointer<ffi.Void> ctx,
    ffi.Pointer<ffi.Void> memory,
    int memoryLen,
    int alignment,
    int newLen,
    int retAddr,
  ) {
    final remapped = _alloc(ctx, newLen, alignment, retAddr);
    if (remapped == ffi.nullptr) {
      return ffi.nullptr;
    }

    if (memory != ffi.nullptr && memoryLen > 0) {
      final copyLen = memoryLen < newLen ? memoryLen : newLen;
      remapped
          .cast<ffi.Uint8>()
          .asTypedList(copyLen)
          .setAll(0, memory.cast<ffi.Uint8>().asTypedList(copyLen));
      _free(ctx, memory, memoryLen, alignment, retAddr);
    }

    return remapped;
  }

  static void _free(
    ffi.Pointer<ffi.Void> ctx,
    ffi.Pointer<ffi.Void> memory,
    int memoryLen,
    int alignment,
    int retAddr,
  ) {
    if (memory == ffi.nullptr) {
      return;
    }
    malloc.free(memory);
  }

  /// Copies [len] bytes from [ptr] into Dart-managed memory and frees [ptr].
  Uint8List copyBytesAndFree(ffi.Pointer<ffi.Uint8> ptr, int len) {
    if (ptr == ffi.nullptr || len == 0) {
      if (ptr != ffi.nullptr) {
        freePointer(ptr.cast());
      }
      return Uint8List(0);
    }

    final bytes = Uint8List.fromList(ptr.asTypedList(len));
    freePointer(ptr.cast());
    return bytes;
  }

  /// Frees a pointer allocated by this allocator.
  void freePointer(ffi.Pointer<ffi.Void> ptr) {
    if (ptr == ffi.nullptr) {
      return;
    }
    malloc.free(ptr);
  }
}

/// Bit masks for keyboard modifiers.
///
/// Combine with bitwise OR to represent multiple modifiers.
///
/// ```dart
/// final mods = GhosttyModsMask.ctrl | GhosttyModsMask.shift;
/// event.mods = mods;
/// ```
final class GhosttyModsMask {
  const GhosttyModsMask._();

  static const int shift = bindings.GHOSTTY_MODS_SHIFT;
  static const int ctrl = bindings.GHOSTTY_MODS_CTRL;
  static const int alt = bindings.GHOSTTY_MODS_ALT;
  static const int superKey = bindings.GHOSTTY_MODS_SUPER;
  static const int capsLock = bindings.GHOSTTY_MODS_CAPS_LOCK;
  static const int numLock = bindings.GHOSTTY_MODS_NUM_LOCK;
  static const int shiftSide = bindings.GHOSTTY_MODS_SHIFT_SIDE;
  static const int ctrlSide = bindings.GHOSTTY_MODS_CTRL_SIDE;
  static const int altSide = bindings.GHOSTTY_MODS_ALT_SIDE;
  static const int superSide = bindings.GHOSTTY_MODS_SUPER_SIDE;
}

/// Bit flags for the Kitty keyboard protocol.
///
/// Set on [VtKeyEncoder.kittyFlags] to control encoding behavior.
///
/// ```dart
/// encoder.kittyFlags = GhosttyKittyFlags.disambiguate
///     | GhosttyKittyFlags.reportEvents;
/// ```
final class GhosttyKittyFlags {
  const GhosttyKittyFlags._();

  static const int disabled = bindings.GHOSTTY_KITTY_KEY_DISABLED;
  static const int disambiguate = bindings.GHOSTTY_KITTY_KEY_DISAMBIGUATE;
  static const int reportEvents = bindings.GHOSTTY_KITTY_KEY_REPORT_EVENTS;
  static const int reportAlternates =
      bindings.GHOSTTY_KITTY_KEY_REPORT_ALTERNATES;
  static const int reportAll = bindings.GHOSTTY_KITTY_KEY_REPORT_ALL;
  static const int reportAssociated =
      bindings.GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED;
  static const int all = bindings.GHOSTTY_KITTY_KEY_ALL;
}

/// Named ANSI color indices.
final class GhosttyNamedColor {
  const GhosttyNamedColor._();

  static const int black = bindings.GHOSTTY_COLOR_NAMED_BLACK;
  static const int red = bindings.GHOSTTY_COLOR_NAMED_RED;
  static const int green = bindings.GHOSTTY_COLOR_NAMED_GREEN;
  static const int yellow = bindings.GHOSTTY_COLOR_NAMED_YELLOW;
  static const int blue = bindings.GHOSTTY_COLOR_NAMED_BLUE;
  static const int magenta = bindings.GHOSTTY_COLOR_NAMED_MAGENTA;
  static const int cyan = bindings.GHOSTTY_COLOR_NAMED_CYAN;
  static const int white = bindings.GHOSTTY_COLOR_NAMED_WHITE;
  static const int brightBlack = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_BLACK;
  static const int brightRed = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_RED;
  static const int brightGreen = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_GREEN;
  static const int brightYellow = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_YELLOW;
  static const int brightBlue = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_BLUE;
  static const int brightMagenta = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_MAGENTA;
  static const int brightCyan = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_CYAN;
  static const int brightWhite = bindings.GHOSTTY_COLOR_NAMED_BRIGHT_WHITE;
}

/// RGB color value with 8-bit [r], [g], [b] channels.
///
/// ```dart
/// const red = VtRgbColor(255, 0, 0);
/// print('Red: ${red.r}, Green: ${red.g}, Blue: ${red.b}');
/// ```
final class VtRgbColor {
  const VtRgbColor(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  factory VtRgbColor.fromNative(bindings.GhosttyColorRgb native) {
    final r = calloc<ffi.Uint8>();
    final g = calloc<ffi.Uint8>();
    final b = calloc<ffi.Uint8>();
    try {
      bindings.ghostty_color_rgb_get(native, r, g, b);
      return VtRgbColor(r.value, g.value, b.value);
    } finally {
      calloc.free(r);
      calloc.free(g);
      calloc.free(b);
    }
  }

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
  final bindings.GhosttyOptimizeMode optimize;
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

/// Packed terminal mode helper used by DECRPM mode reports.
final class VtMode {
  const VtMode(this.mode, {this.ansi = false})
    : assert(mode >= 0 && mode <= 0x7FFF);

  final int mode;
  final bool ansi;

  int get packed => (mode & 0x7FFF) | (ansi ? 0x8000 : 0);
}

/// Named terminal modes exposed by Ghostty.
///
/// Use these constants with [VtTerminal.getMode], [VtTerminal.setMode], and
/// [GhosttyVt.encodeModeReport] instead of manually packing raw mode values.
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

/// Aggregated mouse-reporting state derived from terminal modes.
final class VtMouseProtocolState {
  const VtMouseProtocolState({
    required this.enabled,
    required this.trackingMode,
    required this.format,
    required this.focusEvents,
    required this.altScroll,
  });

  /// Whether the terminal currently reports mouse events to the application.
  final bool enabled;

  /// Active Ghostty mouse tracking mode, if mouse reporting is enabled.
  final bindings.GhosttyMouseTrackingMode? trackingMode;

  /// Active Ghostty mouse encoding format, if mouse reporting is enabled.
  final bindings.GhosttyMouseFormat? format;

  /// Whether focus in/out events are enabled alongside mouse reporting.
  final bool focusEvents;

  /// Whether alternate-scroll mode is enabled.
  final bool altScroll;
}

/// Tagged terminal point used by grid/screen lookup APIs.
final class VtPoint {
  const VtPoint.active(this.x, this.y)
    : tag = bindings.GhosttyPointTag.GHOSTTY_POINT_TAG_ACTIVE;

  const VtPoint.viewport(this.x, this.y)
    : tag = bindings.GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT;

  const VtPoint.screen(this.x, this.y)
    : tag = bindings.GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN;

  const VtPoint.history(this.x, this.y)
    : tag = bindings.GhosttyPointTag.GHOSTTY_POINT_TAG_HISTORY;

  final bindings.GhosttyPointTag tag;
  final int x;
  final int y;

  void _writeTo(bindings.GhosttyPoint native) {
    native
      ..tagAsInt = tag.value
      ..value.coordinate.x = _checkPositiveUint16(x + 1, 'x + 1') - 1
      ..value.coordinate.y = _checkNonNegative(y, 'y');
  }
}

/// Tagged style color resolved from Ghostty VT state.
final class VtStyleColor {
  const VtStyleColor._({required this.tag, this.paletteIndex, this.rgb});

  const VtStyleColor.none()
    : this._(tag: bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE);

  const VtStyleColor.palette(int index)
    : this._(
        tag: bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE,
        paletteIndex: index,
      );

  const VtStyleColor.rgb(VtRgbColor value)
    : this._(
        tag: bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB,
        rgb: value,
      );

  final bindings.GhosttyStyleColorTag tag;
  final int? paletteIndex;
  final VtRgbColor? rgb;

  bool get isSet =>
      tag != bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE;

  factory VtStyleColor.fromNative(bindings.GhosttyStyleColor native) {
    return switch (native.tag) {
      bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE =>
        const VtStyleColor.none(),
      bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE =>
        VtStyleColor.palette(native.value.palette),
      bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB => VtStyleColor.rgb(
        _rgbFromNative(native.value.rgb),
      ),
    };
  }
}

/// Fully resolved terminal cell style.
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
  final bindings.GhosttySgrUnderline underline;

  /// Returns the Ghostty default terminal style.
  static VtStyle defaults() {
    final native = calloc<bindings.GhosttyStyle>();
    try {
      native.ref.size = ffi.sizeOf<bindings.GhosttyStyle>();
      bindings.ghostty_style_default(native);
      return VtStyle.fromNative(native.ref);
    } finally {
      calloc.free(native);
    }
  }

  factory VtStyle.fromNative(bindings.GhosttyStyle native) {
    return VtStyle(
      foreground: VtStyleColor.fromNative(native.fg_color),
      background: VtStyleColor.fromNative(native.bg_color),
      underlineColor: VtStyleColor.fromNative(native.underline_color),
      bold: native.bold,
      italic: native.italic,
      faint: native.faint,
      blink: native.blink,
      inverse: native.inverse,
      invisible: native.invisible,
      strikethrough: native.strikethrough,
      overline: native.overline,
      underline: bindings.GhosttySgrUnderline.fromValue(native.underline),
    );
  }

  /// Whether this style matches the Ghostty default style exactly.
  bool get isDefault {
    final native = calloc<bindings.GhosttyStyle>();
    try {
      _writeTo(native.ref);
      return bindings.ghostty_style_is_default(native);
    } finally {
      calloc.free(native);
    }
  }

  void _writeTo(bindings.GhosttyStyle native) {
    native
      ..size = ffi.sizeOf<bindings.GhosttyStyle>()
      ..bold = bold
      ..italic = italic
      ..faint = faint
      ..blink = blink
      ..inverse = inverse
      ..invisible = invisible
      ..strikethrough = strikethrough
      ..overline = overline
      ..underline = underline.value;
    _writeStyleColorToNative(foreground, native.fg_color);
    _writeStyleColorToNative(background, native.bg_color);
    _writeStyleColorToNative(underlineColor, native.underline_color);
  }
}

/// Terminal scrollbar metrics.
final class VtTerminalScrollbar {
  const VtTerminalScrollbar({
    required this.total,
    required this.offset,
    required this.length,
  });

  final int total;
  final int offset;
  final int length;

  factory VtTerminalScrollbar.fromNative(
    bindings.GhosttyTerminalScrollbar native,
  ) {
    return VtTerminalScrollbar(
      total: native.total,
      offset: native.offset,
      length: native.len,
    );
  }
}

/// Snapshot of a raw terminal row.
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
  final bindings.GhosttyRowSemanticPrompt semanticPrompt;
  final bool kittyVirtualPlaceholder;
  final bool dirty;

  /// Whether prompt cells exist in this row and this row is the primary prompt.
  bool get isPrompt =>
      semanticPrompt ==
      bindings.GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_PROMPT;

  /// Whether prompt cells exist in this row and this row continues a prompt.
  bool get isPromptContinuation =>
      semanticPrompt ==
      bindings
          .GhosttyRowSemanticPrompt
          .GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION;

  /// Whether this row participates in semantic prompt markup.
  bool get hasSemanticPrompt => isPrompt || isPromptContinuation;

  factory VtRowSnapshot.fromRaw(bindings.DartGhosttyRow row) {
    bool getBool(bindings.GhosttyRowData data) {
      final out = calloc<ffi.Bool>();
      try {
        _checkResult(
          bindings.ghostty_row_get(row, data, out.cast()),
          'row_get',
        );
        return out.value;
      } finally {
        calloc.free(out);
      }
    }

    final semanticPrompt = calloc<ffi.UnsignedInt>();
    try {
      _checkResult(
        bindings.ghostty_row_get(
          row,
          bindings.GhosttyRowData.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT,
          semanticPrompt.cast(),
        ),
        'row_get',
      );
      return VtRowSnapshot(
        wrap: getBool(bindings.GhosttyRowData.GHOSTTY_ROW_DATA_WRAP),
        wrapContinuation: getBool(
          bindings.GhosttyRowData.GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
        ),
        hasGrapheme: getBool(bindings.GhosttyRowData.GHOSTTY_ROW_DATA_GRAPHEME),
        styled: getBool(bindings.GhosttyRowData.GHOSTTY_ROW_DATA_STYLED),
        hasHyperlink: getBool(
          bindings.GhosttyRowData.GHOSTTY_ROW_DATA_HYPERLINK,
        ),
        semanticPrompt: bindings.GhosttyRowSemanticPrompt.fromValue(
          semanticPrompt.value,
        ),
        kittyVirtualPlaceholder: getBool(
          bindings.GhosttyRowData.GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER,
        ),
        dirty: getBool(bindings.GhosttyRowData.GHOSTTY_ROW_DATA_DIRTY),
      );
    } finally {
      calloc.free(semanticPrompt);
    }
  }
}

/// Snapshot of a raw terminal cell.
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
  final bindings.GhosttyCellContentTag contentTag;
  final bindings.GhosttyCellWide wide;
  final bool hasText;
  final bool hasStyling;
  final int styleId;
  final bool hasHyperlink;
  final bool isProtected;
  final bindings.GhosttyCellSemanticContent semanticContent;
  final int? colorPaletteIndex;
  final VtRgbColor? colorRgb;

  String get text => codepoint == 0 ? '' : String.fromCharCode(codepoint);

  /// Whether this cell contains no text and no explicit background color.
  bool get isEmpty =>
      !hasText &&
      contentTag ==
          bindings.GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT;

  /// Whether this cell only contributes an explicit background color.
  bool get isBackgroundColorOnly =>
      contentTag ==
          bindings
              .GhosttyCellContentTag
              .GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE ||
      contentTag ==
          bindings.GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB;

  /// Whether this cell is the leading half of a wide grapheme.
  bool get isWideLead =>
      wide == bindings.GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE;

  /// Whether this cell is the trailing spacer half of a wide grapheme.
  bool get isWideTail =>
      wide == bindings.GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_TAIL;

  /// Whether this cell carries an explicit background color payload.
  bool get hasExplicitBackgroundColor =>
      colorPaletteIndex != null || colorRgb != null;

  /// Whether this cell is marked as prompt text by semantic prompt markup.
  bool get isPromptText =>
      semanticContent ==
      bindings.GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_PROMPT;

  /// Whether this cell is marked as command input by semantic prompt markup.
  bool get isPromptInput =>
      semanticContent ==
      bindings.GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_INPUT;

  /// Whether this cell is marked as command output by semantic prompt markup.
  bool get isPromptOutput =>
      semanticContent ==
      bindings.GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_OUTPUT;

  factory VtCellSnapshot.fromRaw(bindings.DartGhosttyCell cell) {
    int getUint32(bindings.GhosttyCellData data) {
      final out = calloc<ffi.Uint32>();
      try {
        _checkResult(
          bindings.ghostty_cell_get(cell, data, out.cast()),
          'cell_get',
        );
        return out.value;
      } finally {
        calloc.free(out);
      }
    }

    bool getBool(bindings.GhosttyCellData data) {
      final out = calloc<ffi.Bool>();
      try {
        _checkResult(
          bindings.ghostty_cell_get(cell, data, out.cast()),
          'cell_get',
        );
        return out.value;
      } finally {
        calloc.free(out);
      }
    }

    final contentTag = bindings.GhosttyCellContentTag.fromValue(
      getUint32(bindings.GhosttyCellData.GHOSTTY_CELL_DATA_CONTENT_TAG),
    );
    final colorPaletteIndex =
        contentTag ==
            bindings.GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE
        ? (() {
            final out = calloc<ffi.Uint8>();
            try {
              _checkResult(
                bindings.ghostty_cell_get(
                  cell,
                  bindings.GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_PALETTE,
                  out.cast(),
                ),
                'cell_get',
              );
              return out.value;
            } finally {
              calloc.free(out);
            }
          })()
        : null;
    final colorRgb =
        contentTag ==
            bindings.GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB
        ? (() {
            final out = calloc<bindings.GhosttyColorRgb>();
            try {
              _checkResult(
                bindings.ghostty_cell_get(
                  cell,
                  bindings.GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_RGB,
                  out.cast(),
                ),
                'cell_get',
              );
              return _rgbFromNative(out.ref);
            } finally {
              calloc.free(out);
            }
          })()
        : null;

    return VtCellSnapshot(
      codepoint: getUint32(
        bindings.GhosttyCellData.GHOSTTY_CELL_DATA_CODEPOINT,
      ),
      contentTag: contentTag,
      wide: bindings.GhosttyCellWide.fromValue(
        getUint32(bindings.GhosttyCellData.GHOSTTY_CELL_DATA_WIDE),
      ),
      hasText: getBool(bindings.GhosttyCellData.GHOSTTY_CELL_DATA_HAS_TEXT),
      hasStyling: getBool(
        bindings.GhosttyCellData.GHOSTTY_CELL_DATA_HAS_STYLING,
      ),
      styleId: (() {
        final out = calloc<ffi.Uint16>();
        try {
          _checkResult(
            bindings.ghostty_cell_get(
              cell,
              bindings.GhosttyCellData.GHOSTTY_CELL_DATA_STYLE_ID,
              out.cast(),
            ),
            'cell_get',
          );
          return out.value;
        } finally {
          calloc.free(out);
        }
      })(),
      hasHyperlink: getBool(
        bindings.GhosttyCellData.GHOSTTY_CELL_DATA_HAS_HYPERLINK,
      ),
      isProtected: getBool(
        bindings.GhosttyCellData.GHOSTTY_CELL_DATA_PROTECTED,
      ),
      semanticContent: bindings.GhosttyCellSemanticContent.fromValue(
        getUint32(bindings.GhosttyCellData.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT),
      ),
      colorPaletteIndex: colorPaletteIndex,
      colorRgb: colorRgb,
    );
  }
}

/// Snapshot of a resolved terminal grid reference.
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

  static VtGridRefSnapshot fromNative(
    ffi.Pointer<bindings.GhosttyGridRef> ref,
  ) {
    final cellPtr = calloc<bindings.GhosttyCell>();
    final rowPtr = calloc<bindings.GhosttyRow>();
    final stylePtr = calloc<bindings.GhosttyStyle>();
    final graphemeLen = calloc<ffi.Size>();
    try {
      stylePtr.ref.size = ffi.sizeOf<bindings.GhosttyStyle>();
      _checkResult(
        bindings.ghostty_grid_ref_cell(ref, cellPtr),
        'grid_ref_cell',
      );
      _checkResult(bindings.ghostty_grid_ref_row(ref, rowPtr), 'grid_ref_row');
      _checkResult(
        bindings.ghostty_grid_ref_style(ref, stylePtr),
        'grid_ref_style',
      );
      final first = bindings.ghostty_grid_ref_graphemes(
        ref,
        ffi.nullptr,
        0,
        graphemeLen,
      );
      if (first != bindings.GhosttyResult.GHOSTTY_OUT_OF_SPACE &&
          first != bindings.GhosttyResult.GHOSTTY_SUCCESS) {
        _checkResult(first, 'grid_ref_graphemes(size_probe)');
      }
      final length = graphemeLen.value;
      final graphemes = length == 0
          ? ''
          : (() {
              final buffer = calloc<ffi.Uint32>(length);
              try {
                _checkResult(
                  bindings.ghostty_grid_ref_graphemes(
                    ref,
                    buffer,
                    length,
                    graphemeLen,
                  ),
                  'grid_ref_graphemes',
                );
                return String.fromCharCodes(
                  buffer.asTypedList(graphemeLen.value),
                );
              } finally {
                calloc.free(buffer);
              }
            })();

      return VtGridRefSnapshot(
        x: ref.ref.x,
        y: ref.ref.y,
        cell: VtCellSnapshot.fromRaw(cellPtr.value),
        row: VtRowSnapshot.fromRaw(rowPtr.value),
        style: VtStyle.fromNative(stylePtr.ref),
        graphemes: graphemes,
      );
    } finally {
      calloc.free(graphemeLen);
      calloc.free(stylePtr);
      calloc.free(rowPtr);
      calloc.free(cellPtr);
    }
  }
}

/// Colors exposed by a render-state snapshot.
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
  ///
  /// Returns [defaultColor] when [color] is unset.
  VtRgbColor? resolve(VtStyleColor color, {VtRgbColor? defaultColor}) {
    return switch (color.tag) {
      bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE => defaultColor,
      bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE => paletteAt(
        color.paletteIndex!,
      ),
      bindings.GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB => color.rgb,
    };
  }

  /// Resolves this style's foreground color using this render-state palette.
  VtRgbColor? resolveForeground(VtStyle style) =>
      resolve(style.foreground, defaultColor: foreground);

  /// Resolves this style's background color using this render-state palette.
  VtRgbColor? resolveBackground(VtStyle style) =>
      resolve(style.background, defaultColor: background);

  /// Resolves this style's underline color using this render-state palette.
  ///
  /// Falls back to the resolved foreground color when the underline color is
  /// unset.
  VtRgbColor? resolveUnderlineColor(VtStyle style) =>
      resolve(style.underlineColor, defaultColor: resolveForeground(style));

  factory VtRenderColors.fromNative(bindings.GhosttyRenderStateColors native) {
    return VtRenderColors(
      background: _rgbFromNative(native.background),
      foreground: _rgbFromNative(native.foreground),
      cursor: native.cursor_has_value ? _rgbFromNative(native.cursor) : null,
      palette: List<VtRgbColor>.generate(
        256,
        (index) => _rgbFromNative(native.palette[index]),
      ),
    );
  }
}

/// Cursor data from a render-state snapshot.
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

  final bindings.GhosttyRenderStateCursorVisualStyle visualStyle;
  final bool visible;
  final bool blinking;
  final bool passwordInput;
  final bool hasViewportPosition;
  final int? viewportX;
  final int? viewportY;
  final bool? onWideTail;

  /// Whether this cursor is painted as a filled or hollow block.
  bool get isBlock =>
      visualStyle ==
          bindings
              .GhosttyRenderStateCursorVisualStyle
              .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK ||
      visualStyle ==
          bindings
              .GhosttyRenderStateCursorVisualStyle
              .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW;

  /// Whether this cursor is painted as a vertical bar.
  bool get isBar =>
      visualStyle ==
      bindings
          .GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR;

  /// Whether this cursor is painted as an underline.
  bool get isUnderline =>
      visualStyle ==
      bindings
          .GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE;

  /// Whether this cursor is painted as a hollow block outline.
  bool get isHollowBlock =>
      visualStyle ==
      bindings
          .GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW;
}

/// Single cell snapshot from Ghostty render state.
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

/// Live row cursor over Ghostty render-state iteration.
///
/// Instances of this type are transient and should only be used inside
/// [VtRenderState.visitRows].
final class VtRenderRowCursor {
  VtRenderRowCursor._(this._handle);

  final bindings.GhosttyRenderStateRowIterator _handle;

  /// Whether this row is currently marked dirty.
  bool get dirty {
    final out = calloc<ffi.Bool>();
    try {
      _checkResult(
        bindings.ghostty_render_state_row_get(
          _handle,
          bindings
              .GhosttyRenderStateRowData
              .GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
          out.cast(),
        ),
        'ghostty_render_state_row_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Updates whether this row is marked dirty.
  set dirty(bool value) {
    final out = calloc<ffi.Bool>();
    try {
      out.value = value;
      _checkResult(
        bindings.ghostty_render_state_row_set(
          _handle,
          bindings
              .GhosttyRenderStateRowOption
              .GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
          out.cast(),
        ),
        'ghostty_render_state_row_set',
      );
    } finally {
      calloc.free(out);
    }
  }

  /// The raw metadata snapshot for this row.
  VtRowSnapshot get raw {
    final out = calloc<bindings.GhosttyRow>();
    try {
      _checkResult(
        bindings.ghostty_render_state_row_get(
          _handle,
          bindings.GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_RAW,
          out.cast(),
        ),
        'ghostty_render_state_row_get',
      );
      return VtRowSnapshot.fromRaw(out.value);
    } finally {
      calloc.free(out);
    }
  }

  /// Creates a live cell cursor for this row.
  VtRenderRowCellsCursor createCellsCursor() {
    final cells = calloc<bindings.GhosttyRenderStateRowCells>();
    try {
      _checkResult(
        bindings.ghostty_render_state_row_cells_new(ffi.nullptr, cells),
        'ghostty_render_state_row_cells_new',
      );
      _checkResult(
        bindings.ghostty_render_state_row_get(
          _handle,
          bindings
              .GhosttyRenderStateRowData
              .GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
          cells.cast(),
        ),
        'ghostty_render_state_row_get',
      );
      return VtRenderRowCellsCursor._(cells.value);
    } finally {
      calloc.free(cells);
    }
  }

  /// Visits this row's live cell cursor and closes it after [visitor] returns.
  void visitCells(void Function(VtRenderRowCellsCursor cells) visitor) {
    final cells = createCellsCursor();
    try {
      visitor(cells);
    } finally {
      cells.close();
    }
  }
}

/// Live cell cursor over the cells of a render-state row.
///
/// Instances of this type are transient and should be closed when no longer
/// needed.
final class VtRenderRowCellsCursor {
  VtRenderRowCellsCursor._(this._handle);

  final bindings.GhosttyRenderStateRowCells _handle;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtRenderRowCellsCursor is already closed.');
    }
  }

  /// Advances this cursor to the next cell.
  ///
  /// Returns `true` when the cursor moved and a current cell is available.
  bool moveNext() {
    _ensureOpen();
    return bindings.ghostty_render_state_row_cells_next(_handle);
  }

  /// Repositions this cursor to the zero-based column [x].
  void select(int x) {
    _ensureOpen();
    _checkResult(
      bindings.ghostty_render_state_row_cells_select(
        _handle,
        _checkNonNegative(x, 'x'),
      ),
      'ghostty_render_state_row_cells_select',
    );
  }

  /// The cell at this cursor's current position.
  VtRenderCellSnapshot get current {
    _ensureOpen();
    final raw = calloc<bindings.GhosttyCell>();
    final style = calloc<bindings.GhosttyStyle>();
    final graphemeLen = calloc<ffi.Uint32>();
    try {
      style.ref.size = ffi.sizeOf<bindings.GhosttyStyle>();
      _checkResult(
        bindings.ghostty_render_state_row_cells_get(
          _handle,
          bindings
              .GhosttyRenderStateRowCellsData
              .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
          raw.cast(),
        ),
        'ghostty_render_state_row_cells_get',
      );
      _checkResult(
        bindings.ghostty_render_state_row_cells_get(
          _handle,
          bindings
              .GhosttyRenderStateRowCellsData
              .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
          style.cast(),
        ),
        'ghostty_render_state_row_cells_get',
      );
      _checkResult(
        bindings.ghostty_render_state_row_cells_get(
          _handle,
          bindings
              .GhosttyRenderStateRowCellsData
              .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
          graphemeLen.cast(),
        ),
        'ghostty_render_state_row_cells_get',
      );
      final graphemes = graphemeLen.value == 0
          ? ''
          : (() {
              final buffer = calloc<ffi.Uint32>(graphemeLen.value);
              try {
                _checkResult(
                  bindings.ghostty_render_state_row_cells_get(
                    _handle,
                    bindings
                        .GhosttyRenderStateRowCellsData
                        .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                    buffer.cast(),
                  ),
                  'ghostty_render_state_row_cells_get',
                );
                return String.fromCharCodes(
                  buffer.asTypedList(graphemeLen.value),
                );
              } finally {
                calloc.free(buffer);
              }
            })();

      return VtRenderCellSnapshot(
        raw: VtCellSnapshot.fromRaw(raw.value),
        style: VtStyle.fromNative(style.ref),
        graphemes: graphemes,
      );
    } finally {
      calloc.free(graphemeLen);
      calloc.free(style);
      calloc.free(raw);
    }
  }

  /// Returns the cell at zero-based column [x].
  VtRenderCellSnapshot cellAt(int x) {
    select(x);
    return current;
  }

  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_render_state_row_cells_free(_handle);
    _closed = true;
  }
}

/// Single row snapshot from Ghostty render state.
final class VtRenderRowSnapshot {
  const VtRenderRowSnapshot({
    required this.dirty,
    required this.raw,
    required this.cells,
  });

  final bool dirty;
  final VtRowSnapshot raw;
  final List<VtRenderCellSnapshot> cells;

  VtRenderCellSnapshot cellAt(int column) {
    RangeError.checkValidIndex(column, cells, 'column', cells.length);
    return cells[column];
  }
}

/// Full high-level snapshot produced from Ghostty render state.
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
  final bindings.GhosttyRenderStateDirty dirty;
  final VtRenderColors colors;
  final VtRenderCursorSnapshot cursor;
  final List<VtRenderRowSnapshot> rowsData;

  VtRenderRowSnapshot rowAt(int row) {
    RangeError.checkValidIndex(row, rowsData, 'row', rowsData.length);
    return rowsData[row];
  }

  VtRenderCellSnapshot cellAt({required int row, required int column}) {
    return rowAt(row).cellAt(column);
  }
}

/// Primary device attributes (DA1) response data.
///
/// Contains the conformance level and a list of feature codes, which are
/// sent in response to a CSI c query.
final class VtDeviceAttributesPrimary {
  const VtDeviceAttributesPrimary({
    required this.conformanceLevel,
    this.features = const [],
  });

  /// Conformance level (Pp parameter). E.g. 62 for VT220.
  final int conformanceLevel;

  /// DA1 feature codes. Up to 64 entries.
  final List<int> features;
}

/// Secondary device attributes (DA2) response data.
///
/// Sent in response to a CSI > c query.
final class VtDeviceAttributesSecondary {
  const VtDeviceAttributesSecondary({
    required this.deviceType,
    required this.firmwareVersion,
    this.romCartridge = 0,
  });

  /// Terminal type identifier (Pp). E.g. 1 for VT220.
  final int deviceType;

  /// Firmware/patch version number (Pv).
  final int firmwareVersion;

  /// ROM cartridge registration number (Pc). Always 0 for emulators.
  final int romCartridge;
}

/// Tertiary device attributes (DA3) response data.
///
/// Sent in response to a CSI = c query (DECRPTUI).
final class VtDeviceAttributesTertiary {
  const VtDeviceAttributesTertiary({required this.unitId});

  /// Unit ID encoded as 8 uppercase hex digits in the response.
  final int unitId;
}

/// Device attributes response data for all three DA levels.
///
/// Filled by the [VtTerminal.onDeviceAttributesQuery] callback.
final class VtDeviceAttributes {
  const VtDeviceAttributes({
    required this.primary,
    required this.secondary,
    required this.tertiary,
  });

  final VtDeviceAttributesPrimary primary;
  final VtDeviceAttributesSecondary secondary;
  final VtDeviceAttributesTertiary tertiary;

  void _writeTo(bindings.GhosttyDeviceAttributes native) {
    native.primary.conformance_level = primary.conformanceLevel;
    final featureCount = primary.features.length > 64
        ? 64
        : primary.features.length;
    for (var i = 0; i < featureCount; i++) {
      native.primary.features[i] = primary.features[i];
    }
    native.primary.num_features = featureCount;

    native.secondary.device_type = secondary.deviceType;
    native.secondary.firmware_version = secondary.firmwareVersion;
    native.secondary.rom_cartridge = secondary.romCartridge;

    native.tertiary.unit_id = tertiary.unitId;
  }
}

/// Size context used by Ghostty size-report encoding.
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

  void _writeTo(bindings.GhosttySizeReportSize native) {
    native
      ..rows = _checkPositiveUint16(rows, 'rows')
      ..columns = _checkPositiveUint16(columns, 'columns')
      ..cell_width = _checkNonNegative(cellWidth, 'cellWidth')
      ..cell_height = _checkNonNegative(cellHeight, 'cellHeight');
  }
}

/// Mouse position in surface-space pixels.
final class VtMousePosition {
  const VtMousePosition({required this.x, required this.y});

  final double x;
  final double y;

  void _writeTo(bindings.GhosttyMousePosition native) {
    native
      ..x = x
      ..y = y;
  }

  factory VtMousePosition.fromNative(bindings.GhosttyMousePosition native) {
    return VtMousePosition(x: native.x, y: native.y);
  }
}

/// Geometry context used by Ghostty mouse encoding.
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

  void _writeTo(bindings.GhosttyMouseEncoderSize native) {
    native
      ..size = ffi.sizeOf<bindings.GhosttyMouseEncoderSize>()
      ..screen_width = _checkNonNegative(screenWidth, 'screenWidth')
      ..screen_height = _checkNonNegative(screenHeight, 'screenHeight')
      ..cell_width = _checkPositiveUint16(cellWidth, 'cellWidth')
      ..cell_height = _checkPositiveUint16(cellHeight, 'cellHeight')
      ..padding_top = _checkNonNegative(paddingTop, 'paddingTop')
      ..padding_bottom = _checkNonNegative(paddingBottom, 'paddingBottom')
      ..padding_right = _checkNonNegative(paddingRight, 'paddingRight')
      ..padding_left = _checkNonNegative(paddingLeft, 'paddingLeft');
  }
}

/// Reusable configuration for a [VtKeyEncoder].
final class VtKeyEncoderOptions {
  const VtKeyEncoderOptions({
    this.cursorKeyApplication = false,
    this.keypadKeyApplication = false,
    this.ignoreKeypadWithNumLock = false,
    this.altEscPrefix = false,
    this.modifyOtherKeysState2 = false,
    this.kittyFlags = 0,
    this.macosOptionAsAlt =
        bindings.GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_FALSE,
  });

  /// Conventional Kitty keyboard configuration with [kittyFlags].
  const VtKeyEncoderOptions.kitty({
    this.cursorKeyApplication = false,
    this.keypadKeyApplication = false,
    this.ignoreKeypadWithNumLock = false,
    this.altEscPrefix = false,
    this.modifyOtherKeysState2 = false,
    this.kittyFlags = GhosttyKittyFlags.all,
    this.macosOptionAsAlt =
        bindings.GhosttyOptionAsAlt.GHOSTTY_OPTION_AS_ALT_FALSE,
  });

  final bool cursorKeyApplication;
  final bool keypadKeyApplication;
  final bool ignoreKeypadWithNumLock;
  final bool altEscPrefix;
  final bool modifyOtherKeysState2;
  final int kittyFlags;
  final bindings.GhosttyOptionAsAlt macosOptionAsAlt;

  /// Applies this option set to [encoder].
  void applyTo(VtKeyEncoder encoder) {
    encoder
      ..cursorKeyApplication = cursorKeyApplication
      ..keypadKeyApplication = keypadKeyApplication
      ..ignoreKeypadWithNumLock = ignoreKeypadWithNumLock
      ..altEscPrefix = altEscPrefix
      ..modifyOtherKeysState2 = modifyOtherKeysState2
      ..kittyFlags = kittyFlags
      ..macosOptionAsAlt = macosOptionAsAlt;
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

  /// Common SGR mouse reporting configuration.
  const VtMouseEncoderOptions.sgr({
    required this.size,
    this.trackingMode =
        bindings.GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL,
    this.anyButtonPressed = false,
    this.trackLastCell = true,
  }) : format = bindings.GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR;

  /// Common SGR pixel mouse reporting configuration.
  const VtMouseEncoderOptions.sgrPixels({
    required this.size,
    this.trackingMode =
        bindings.GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY,
    this.anyButtonPressed = false,
    this.trackLastCell = true,
  }) : format = bindings.GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR_PIXELS;

  final bindings.GhosttyMouseTrackingMode trackingMode;
  final bindings.GhosttyMouseFormat format;
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

/// Scroll viewport behavior for [VtTerminal.scrollViewport].
final class VtTerminalScrollViewport {
  const VtTerminalScrollViewport._(this._tag, {this.delta = 0});

  /// Scroll to the top of the scrollback.
  const VtTerminalScrollViewport.top()
    : this._(
        bindings.GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_TOP,
      );

  /// Scroll to the bottom of the active screen.
  const VtTerminalScrollViewport.bottom()
    : this._(
        bindings
            .GhosttyTerminalScrollViewportTag
            .GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
      );

  /// Scroll by [delta] rows. Negative values move up.
  const VtTerminalScrollViewport.delta(int delta)
    : this._(
        bindings.GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA,
        delta: delta,
      );

  final bindings.GhosttyTerminalScrollViewportTag _tag;
  final int delta;
}

/// Extra screen state to include in styled formatter output.
final class VtFormatterScreenExtra {
  const VtFormatterScreenExtra({
    this.cursor = false,
    this.style = false,
    this.hyperlink = false,
    this.protection = false,
    this.kittyKeyboard = false,
    this.charsets = false,
  });

  /// Enables all screen-level formatter extras.
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

/// Extra terminal state to include in styled formatter output.
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

  /// Enables all terminal-level formatter extras.
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

/// Options for [VtTerminal.createFormatter].
final class VtFormatterTerminalOptions {
  const VtFormatterTerminalOptions({
    this.emit = bindings.GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
    this.unwrap = false,
    this.trim = true,
    this.extra = const VtFormatterTerminalExtra(),
  });

  final bindings.GhosttyFormatterFormat emit;
  final bool unwrap;
  final bool trim;
  final VtFormatterTerminalExtra extra;
}

/// Stateful VT terminal emulator instance.
final class VtTerminal {
  VtTerminal({required int cols, required int rows, int maxScrollback = 10_000})
    : _cols = _checkPositiveUint16(cols, 'cols'),
      _rows = _checkPositiveUint16(rows, 'rows'),
      _maxScrollback = _checkNonNegative(maxScrollback, 'maxScrollback'),
      _handle = _newTerminal(
        cols: cols,
        rows: rows,
        maxScrollback: maxScrollback,
      );

  final bindings.GhosttyTerminal _handle;
  final Set<VtTerminalFormatter> _formatters = <VtTerminalFormatter>{};
  bool _closed = false;
  int _cols;
  int _rows;
  final int _maxScrollback;

  // --- Terminal effect callbacks ---

  /// Native callable backing [onWritePty]. Kept alive until replaced or
  /// the terminal is closed.
  ffi.NativeCallable<bindings.GhosttyTerminalWritePtyFnFunction>?
  _writePtyCallable;

  /// User-supplied callback invoked when the terminal needs to write data
  /// back to the PTY (e.g. in response to device-status reports or mode
  /// queries).
  ///
  /// The [Uint8List] contains the response bytes and is only valid for the
  /// duration of the call — callers must copy it if it needs to persist.
  void Function(Uint8List data)? get onWritePty => _onWritePty;
  void Function(Uint8List data)? _onWritePty;
  set onWritePty(void Function(Uint8List data)? callback) {
    _ensureOpen();
    _onWritePty = callback;

    // Tear down previous callable if any.
    _writePtyCallable?.close();
    _writePtyCallable = null;

    if (callback != null) {
      _writePtyCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalWritePtyFnFunction
          >.isolateLocal(_nativeWritePty);
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_WRITE_PTY,
        _writePtyCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_WRITE_PTY,
        ffi.nullptr,
      );
    }
  }

  /// Native trampoline for the write-pty callback. Copies the data buffer
  /// (which is only valid for the duration of the call) into a [Uint8List]
  /// and forwards it to the user callback.
  void _nativeWritePty(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<ffi.Uint8> data,
    int len,
  ) {
    final cb = _onWritePty;
    if (cb != null && len > 0) {
      cb(Uint8List.fromList(data.asTypedList(len)));
    }
  }

  // --- onBell callback ---

  ffi.NativeCallable<bindings.GhosttyTerminalBellFnFunction>? _bellCallable;

  /// User-supplied callback invoked when the terminal receives a BEL
  /// character (0x07).
  void Function()? get onBell => _onBell;
  void Function()? _onBell;
  set onBell(void Function()? callback) {
    _ensureOpen();
    _onBell = callback;

    _bellCallable?.close();
    _bellCallable = null;

    if (callback != null) {
      _bellCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalBellFnFunction
          >.isolateLocal(_nativeBell);
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_BELL,
        _bellCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_BELL,
        ffi.nullptr,
      );
    }
  }

  void _nativeBell(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    _onBell?.call();
  }

  // --- onTitleChanged callback ---

  ffi.NativeCallable<bindings.GhosttyTerminalTitleChangedFnFunction>?
  _titleChangedCallable;

  /// User-supplied callback invoked when the terminal title changes via
  /// escape sequences (e.g. OSC 0 or OSC 2).
  ///
  /// The new title can be queried from [title] after the callback fires.
  void Function()? get onTitleChanged => _onTitleChanged;
  void Function()? _onTitleChanged;
  set onTitleChanged(void Function()? callback) {
    _ensureOpen();
    _onTitleChanged = callback;

    _titleChangedCallable?.close();
    _titleChangedCallable = null;

    if (callback != null) {
      _titleChangedCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalTitleChangedFnFunction
          >.isolateLocal(_nativeTitleChanged);
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
        _titleChangedCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
        ffi.nullptr,
      );
    }
  }

  void _nativeTitleChanged(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    _onTitleChanged?.call();
  }

  // --- onSizeQuery callback ---

  ffi.NativeCallable<bindings.GhosttyTerminalSizeFnFunction>?
  _sizeQueryCallable;

  /// User-supplied callback invoked in response to XTWINOPS size queries
  /// (CSI 14/16/18 t).
  ///
  /// Return a [VtSizeReportSize] to respond to the query, or `null` to
  /// silently ignore it.
  VtSizeReportSize? Function()? get onSizeQuery => _onSizeQuery;
  VtSizeReportSize? Function()? _onSizeQuery;
  set onSizeQuery(VtSizeReportSize? Function()? callback) {
    _ensureOpen();
    _onSizeQuery = callback;

    _sizeQueryCallable?.close();
    _sizeQueryCallable = null;

    if (callback != null) {
      _sizeQueryCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalSizeFnFunction
          >.isolateLocal(_nativeSizeQuery, exceptionalReturn: false);
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SIZE,
        _sizeQueryCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_SIZE,
        ffi.nullptr,
      );
    }
  }

  bool _nativeSizeQuery(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<bindings.GhosttySizeReportSize> outSize,
  ) {
    final cb = _onSizeQuery;
    if (cb == null) return false;
    final result = cb();
    if (result == null) return false;
    result._writeTo(outSize.ref);
    return true;
  }

  // --- onColorSchemeQuery callback ---

  ffi.NativeCallable<bindings.GhosttyTerminalColorSchemeFnFunction>?
  _colorSchemeQueryCallable;

  /// User-supplied callback invoked in response to a color scheme device
  /// status report query (CSI ? 996 n).
  ///
  /// Return a [GhosttyColorScheme] to respond to the query, or `null` to
  /// silently ignore it.
  bindings.GhosttyColorScheme? Function()? get onColorSchemeQuery =>
      _onColorSchemeQuery;
  bindings.GhosttyColorScheme? Function()? _onColorSchemeQuery;
  set onColorSchemeQuery(bindings.GhosttyColorScheme? Function()? callback) {
    _ensureOpen();
    _onColorSchemeQuery = callback;

    _colorSchemeQueryCallable?.close();
    _colorSchemeQueryCallable = null;

    if (callback != null) {
      _colorSchemeQueryCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalColorSchemeFnFunction
          >.isolateLocal(_nativeColorSchemeQuery, exceptionalReturn: false);
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
        _colorSchemeQueryCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
        ffi.nullptr,
      );
    }
  }

  bool _nativeColorSchemeQuery(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<ffi.UnsignedInt> outScheme,
  ) {
    final cb = _onColorSchemeQuery;
    if (cb == null) return false;
    final result = cb();
    if (result == null) return false;
    outScheme.value = result.value;
    return true;
  }

  // --- onDeviceAttributesQuery callback ---

  ffi.NativeCallable<bindings.GhosttyTerminalDeviceAttributesFnFunction>?
  _deviceAttributesQueryCallable;

  /// User-supplied callback invoked in response to device attributes queries
  /// (DA1: CSI c, DA2: CSI > c, DA3: CSI = c).
  ///
  /// Return a [VtDeviceAttributes] to respond to the query, or `null` to
  /// silently ignore it.
  VtDeviceAttributes? Function()? get onDeviceAttributesQuery =>
      _onDeviceAttributesQuery;
  VtDeviceAttributes? Function()? _onDeviceAttributesQuery;
  set onDeviceAttributesQuery(VtDeviceAttributes? Function()? callback) {
    _ensureOpen();
    _onDeviceAttributesQuery = callback;

    _deviceAttributesQueryCallable?.close();
    _deviceAttributesQueryCallable = null;

    if (callback != null) {
      _deviceAttributesQueryCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalDeviceAttributesFnFunction
          >.isolateLocal(
            _nativeDeviceAttributesQuery,
            exceptionalReturn: false,
          );
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
        _deviceAttributesQueryCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
        ffi.nullptr,
      );
    }
  }

  bool _nativeDeviceAttributesQuery(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
    ffi.Pointer<bindings.GhosttyDeviceAttributes> outAttrs,
  ) {
    final cb = _onDeviceAttributesQuery;
    if (cb == null) return false;
    final result = cb();
    if (result == null) return false;
    result._writeTo(outAttrs.ref);
    return true;
  }

  // --- onEnquiry callback ---

  ffi.NativeCallable<bindings.GhosttyTerminalEnquiryFnFunction>?
  _enquiryCallable;

  /// User-supplied callback invoked when the terminal receives an ENQ
  /// character (0x05).
  ///
  /// Return a [Uint8List] of response bytes. Return an empty list to send
  /// no response. The returned data must remain valid for the duration of
  /// the call (which it does since Dart manages GC).
  Uint8List Function()? get onEnquiry => _onEnquiry;
  Uint8List Function()? _onEnquiry;
  set onEnquiry(Uint8List Function()? callback) {
    _ensureOpen();
    _onEnquiry = callback;

    _enquiryCallable?.close();
    _enquiryCallable = null;

    if (callback != null) {
      _enquiryCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalEnquiryFnFunction
          >.isolateLocal(_nativeEnquiry);
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_ENQUIRY,
        _enquiryCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_ENQUIRY,
        ffi.nullptr,
      );
    }
  }

  /// Pinned native memory for the enquiry response. Kept alive between
  /// calls to avoid premature GC of the pointer returned to native code.
  ffi.Pointer<ffi.Uint8> _enquiryResponsePtr = ffi.nullptr;
  int _enquiryResponseLen = 0;

  bindings.GhosttyString _nativeEnquiry(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    // Free any previous pinned response.
    if (_enquiryResponsePtr != ffi.nullptr) {
      calloc.free(_enquiryResponsePtr);
      _enquiryResponsePtr = ffi.nullptr;
      _enquiryResponseLen = 0;
    }

    final cb = _onEnquiry;
    if (cb == null) {
      return _emptyGhosttyString();
    }
    final data = cb();
    if (data.isEmpty) {
      return _emptyGhosttyString();
    }

    // Allocate native memory and copy the response bytes.
    _enquiryResponsePtr = calloc<ffi.Uint8>(data.length);
    _enquiryResponseLen = data.length;
    _enquiryResponsePtr.asTypedList(data.length).setAll(0, data);

    return ffi.Struct.create<bindings.GhosttyString>()
      ..ptr = _enquiryResponsePtr
      ..len = _enquiryResponseLen;
  }

  // --- onXtversion callback ---

  ffi.NativeCallable<bindings.GhosttyTerminalXtversionFnFunction>?
  _xtversionCallable;

  /// User-supplied callback invoked when the terminal receives an XTVERSION
  /// query (CSI > q).
  ///
  /// Return a version string (e.g. "myterm 1.0"). Return an empty string
  /// to report the default "libghostty" version.
  String Function()? get onXtversion => _onXtversion;
  String Function()? _onXtversion;
  set onXtversion(String Function()? callback) {
    _ensureOpen();
    _onXtversion = callback;

    _xtversionCallable?.close();
    _xtversionCallable = null;

    if (callback != null) {
      _xtversionCallable =
          ffi.NativeCallable<
            bindings.GhosttyTerminalXtversionFnFunction
          >.isolateLocal(_nativeXtversion);
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_XTVERSION,
        _xtversionCallable!.nativeFunction.cast(),
      );
    } else {
      bindings.ghostty_terminal_set(
        _handle,
        bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_XTVERSION,
        ffi.nullptr,
      );
    }
  }

  /// Pinned native memory for the xtversion response.
  ffi.Pointer<ffi.Uint8> _xtversionResponsePtr = ffi.nullptr;
  int _xtversionResponseLen = 0;

  bindings.GhosttyString _nativeXtversion(
    bindings.GhosttyTerminal terminal,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    // Free any previous pinned response.
    if (_xtversionResponsePtr != ffi.nullptr) {
      calloc.free(_xtversionResponsePtr);
      _xtversionResponsePtr = ffi.nullptr;
      _xtversionResponseLen = 0;
    }

    final cb = _onXtversion;
    if (cb == null) {
      return _emptyGhosttyString();
    }
    final text = cb();
    if (text.isEmpty) {
      return _emptyGhosttyString();
    }

    final bytes = utf8.encode(text);
    _xtversionResponsePtr = calloc<ffi.Uint8>(bytes.length);
    _xtversionResponseLen = bytes.length;
    _xtversionResponsePtr.asTypedList(bytes.length).setAll(0, bytes);

    return ffi.Struct.create<bindings.GhosttyString>()
      ..ptr = _xtversionResponsePtr
      ..len = _xtversionResponseLen;
  }

  static bindings.GhosttyString _emptyGhosttyString() {
    return ffi.Struct.create<bindings.GhosttyString>()
      ..ptr = ffi.nullptr
      ..len = 0;
  }

  static bindings.GhosttyTerminal _newTerminal({
    required int cols,
    required int rows,
    required int maxScrollback,
  }) {
    final optionsPtr = calloc<bindings.GhosttyTerminalOptions>();
    final out = calloc<bindings.GhosttyTerminal>();
    try {
      optionsPtr.ref
        ..cols = _checkPositiveUint16(cols, 'cols')
        ..rows = _checkPositiveUint16(rows, 'rows')
        ..max_scrollback = _checkNonNegative(maxScrollback, 'maxScrollback');
      final result = bindings.ghostty_terminal_new(
        ffi.nullptr,
        out,
        optionsPtr.ref,
      );
      _checkResult(result, 'ghostty_terminal_new');
      return out.value;
    } finally {
      calloc.free(out);
      calloc.free(optionsPtr);
    }
  }

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

  /// The current cursor position within the active screen.
  ({int x, int y}) get cursorPosition => (x: cursorX, y: cursorY);

  int get cursorX => _terminalUint16(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_X,
  );

  int get cursorY => _terminalUint16(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_Y,
  );

  bool get cursorPendingWrap => _terminalBool(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP,
  );

  bindings.GhosttyTerminalScreen get activeScreen {
    final out = calloc<ffi.UnsignedInt>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(
          _handle,
          bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
          out.cast(),
        ),
        'ghostty_terminal_get',
      );
      return bindings.GhosttyTerminalScreen.fromValue(out.value);
    } finally {
      calloc.free(out);
    }
  }

  /// Whether this terminal is currently on the primary screen.
  bool get isPrimaryScreen =>
      activeScreen ==
      bindings.GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_PRIMARY;

  /// Whether this terminal is currently on the alternate screen.
  bool get isAlternateScreen =>
      activeScreen ==
      bindings.GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;

  /// Aggregated mouse-reporting state derived from the terminal's mode flags.
  VtMouseProtocolState get mouseProtocolState {
    final enabled =
        getMode(VtModes.x10Mouse) ||
        getMode(VtModes.normalMouse) ||
        getMode(VtModes.buttonMouse) ||
        getMode(VtModes.anyMouse);

    final bindings.GhosttyMouseTrackingMode? trackingMode;
    if (getMode(VtModes.anyMouse)) {
      trackingMode =
          bindings.GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY;
    } else if (getMode(VtModes.buttonMouse)) {
      trackingMode =
          bindings.GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_BUTTON;
    } else if (getMode(VtModes.normalMouse)) {
      trackingMode =
          bindings.GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL;
    } else if (getMode(VtModes.x10Mouse)) {
      trackingMode =
          bindings.GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_X10;
    } else {
      trackingMode = null;
    }

    final bindings.GhosttyMouseFormat? format;
    if (!enabled) {
      format = null;
    } else if (getMode(VtModes.sgrPixelsMouse)) {
      format = bindings.GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR_PIXELS;
    } else if (getMode(VtModes.sgrMouse)) {
      format = bindings.GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR;
    } else if (getMode(VtModes.urxvtMouse)) {
      format = bindings.GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_URXVT;
    } else if (getMode(VtModes.utf8Mouse)) {
      format = bindings.GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_UTF8;
    } else {
      format = bindings.GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_X10;
    }

    return VtMouseProtocolState(
      enabled: enabled,
      trackingMode: trackingMode,
      format: format,
      focusEvents: getMode(VtModes.focusEvent),
      altScroll: getMode(VtModes.altScroll),
    );
  }

  bool get cursorVisible => _terminalBool(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE,
  );

  /// The terminal title as last set by escape sequences (e.g. OSC 0 / OSC 2).
  ///
  /// Returns an empty string when no title has been set.
  String get title =>
      _terminalString(bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_TITLE);

  /// The terminal's current working directory as last set by escape sequences
  /// (e.g. OSC 7).
  ///
  /// Returns an empty string when no pwd has been set.
  String get pwd =>
      _terminalString(bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_PWD);

  /// Whether any mouse tracking mode (X10, normal, button, or any-event) is
  /// currently enabled.
  bool get mouseTracking => _terminalBool(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
  );

  /// The total number of rows in the active screen including scrollback.
  int get totalRows => _terminalSize(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS,
  );

  /// The number of scrollback rows (total rows minus viewport rows).
  int get scrollbackRows => _terminalSize(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,
  );

  /// The total width of the terminal in pixels (cols * cell_width_px as set
  /// by [resize]).
  int get widthPx => _terminalUint32(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_WIDTH_PX,
  );

  /// The total height of the terminal in pixels (rows * cell_height_px as set
  /// by [resize]).
  int get heightPx => _terminalUint32(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_HEIGHT_PX,
  );

  /// The effective foreground color, including OSC overrides when present.
  VtRgbColor? get foregroundColor => _terminalRgb(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
  );

  /// The effective background color, including OSC overrides when present.
  VtRgbColor? get backgroundColor => _terminalRgb(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
  );

  /// The effective cursor color, including OSC overrides when present.
  VtRgbColor? get cursorColor => _terminalRgb(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR,
  );

  /// The effective 256-color palette, including OSC overrides.
  List<VtRgbColor> get colorPalette => _terminalPalette(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE,
  );

  /// The default foreground color, ignoring OSC overrides.
  VtRgbColor? get defaultForegroundColor => _terminalRgb(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT,
  );

  set defaultForegroundColor(VtRgbColor? value) {
    _terminalSetRgb(
      bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
      value,
    );
  }

  /// The default background color, ignoring OSC overrides.
  VtRgbColor? get defaultBackgroundColor => _terminalRgb(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT,
  );

  set defaultBackgroundColor(VtRgbColor? value) {
    _terminalSetRgb(
      bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
      value,
    );
  }

  /// The default cursor color, ignoring OSC overrides.
  VtRgbColor? get defaultCursorColor => _terminalRgb(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT,
  );

  set defaultCursorColor(VtRgbColor? value) {
    _terminalSetRgb(
      bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,
      value,
    );
  }

  /// The default 256-color palette, ignoring OSC overrides.
  List<VtRgbColor> get defaultPalette => _terminalPalette(
    bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
  );

  set defaultPalette(List<VtRgbColor>? value) {
    _terminalSetPalette(
      bindings.GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
      value,
    );
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

  /// Returns whether [mode] is currently set on this terminal.
  bool getMode(VtMode mode) {
    _ensureOpen();
    final out = calloc<ffi.Bool>();
    try {
      _checkResult(
        bindings.ghostty_terminal_mode_get(_handle, mode.packed, out),
        'ghostty_terminal_mode_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Sets [mode] to [value] on this terminal.
  void setMode(VtMode mode, bool value) {
    _ensureOpen();
    _checkResult(
      bindings.ghostty_terminal_mode_set(_handle, mode.packed, value),
      'ghostty_terminal_mode_set',
    );
  }

  int get kittyKeyboardFlags {
    final out = calloc<ffi.Uint8>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(
          _handle,
          bindings
              .GhosttyTerminalData
              .GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS,
          out.cast(),
        ),
        'ghostty_terminal_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  VtTerminalScrollbar get scrollbar {
    final out = calloc<bindings.GhosttyTerminalScrollbar>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(
          _handle,
          bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR,
          out.cast(),
        ),
        'ghostty_terminal_get',
      );
      return VtTerminalScrollbar.fromNative(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  VtStyle get cursorStyle {
    final out = calloc<bindings.GhosttyStyle>();
    try {
      out.ref.size = ffi.sizeOf<bindings.GhosttyStyle>();
      _checkResult(
        bindings.ghostty_terminal_get(
          _handle,
          bindings.GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_CURSOR_STYLE,
          out.cast(),
        ),
        'ghostty_terminal_get',
      );
      return VtStyle.fromNative(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  VtRgbColor? _terminalRgb(bindings.GhosttyTerminalData data) {
    final out = calloc<bindings.GhosttyColorRgb>();
    try {
      final result = bindings.ghostty_terminal_get(_handle, data, out.cast());
      if (result == bindings.GhosttyResult.GHOSTTY_NO_VALUE) {
        return null;
      }
      _checkResult(result, 'ghostty_terminal_get');
      return _rgbFromNative(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  List<VtRgbColor> _terminalPalette(bindings.GhosttyTerminalData data) {
    final out = calloc<bindings.GhosttyColorRgb>(256);
    try {
      _checkResult(
        bindings.ghostty_terminal_get(_handle, data, out.cast()),
        'ghostty_terminal_get',
      );
      return _rgbPaletteFromNative(out);
    } finally {
      calloc.free(out);
    }
  }

  void _terminalSetRgb(
    bindings.GhosttyTerminalOption option,
    VtRgbColor? value,
  ) {
    _ensureOpen();
    if (value == null) {
      bindings.ghostty_terminal_set(_handle, option, ffi.nullptr);
      return;
    }

    final native = calloc<bindings.GhosttyColorRgb>();
    try {
      _writeRgbToNative(value, native.ref);
      bindings.ghostty_terminal_set(_handle, option, native.cast());
    } finally {
      calloc.free(native);
    }
  }

  void _terminalSetPalette(
    bindings.GhosttyTerminalOption option,
    List<VtRgbColor>? value,
  ) {
    _ensureOpen();
    if (value == null) {
      bindings.ghostty_terminal_set(_handle, option, ffi.nullptr);
      return;
    }
    if (value.length != 256) {
      throw ArgumentError.value(
        value.length,
        'value.length',
        'Palette must contain exactly 256 colors.',
      );
    }

    final native = calloc<bindings.GhosttyColorRgb>(256);
    try {
      for (var i = 0; i < value.length; i++) {
        _writeRgbToNative(value[i], (native + i).ref);
      }
      bindings.ghostty_terminal_set(_handle, option, native.cast());
    } finally {
      calloc.free(native);
    }
  }

  int _terminalUint16(bindings.GhosttyTerminalData data) {
    final out = calloc<ffi.Uint16>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(_handle, data, out.cast()),
        'ghostty_terminal_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  int _terminalUint32(bindings.GhosttyTerminalData data) {
    final out = calloc<ffi.Uint32>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(_handle, data, out.cast()),
        'ghostty_terminal_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  int _terminalSize(bindings.GhosttyTerminalData data) {
    final out = calloc<ffi.Size>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(_handle, data, out.cast()),
        'ghostty_terminal_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  bool _terminalBool(bindings.GhosttyTerminalData data) {
    final out = calloc<ffi.Bool>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(_handle, data, out.cast()),
        'ghostty_terminal_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Reads a borrowed [GhosttyString] from the terminal and copies it into a
  /// Dart [String].
  ///
  /// The borrowed pointer is only valid until the next call to
  /// [ghostty_terminal_vt_write] or [ghostty_terminal_reset], so the bytes are
  /// decoded immediately.
  String _terminalString(bindings.GhosttyTerminalData data) {
    final out = calloc<bindings.GhosttyString>();
    try {
      _checkResult(
        bindings.ghostty_terminal_get(_handle, data, out.cast()),
        'ghostty_terminal_get',
      );
      final len = out.ref.len;
      if (len == 0) return '';
      return utf8.decode(out.ref.ptr.asTypedList(len));
    } finally {
      calloc.free(out);
    }
  }

  /// Writes raw VT-encoded bytes into the terminal stream.
  void writeBytes(List<int> bytes) {
    _ensureOpen();
    if (bytes.isEmpty) {
      return;
    }
    final ptr = calloc<ffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      bindings.ghostty_terminal_vt_write(_handle, ptr, bytes.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Writes text bytes into the terminal stream.
  void write(String text, {Encoding encoding = utf8}) {
    writeBytes(encoding.encode(text));
  }

  /// Performs a full terminal reset while preserving dimensions.
  void reset() {
    _ensureOpen();
    bindings.ghostty_terminal_reset(_handle);
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
    RangeError.checkNotNegative(cellWidthPx, 'cellWidthPx');
    RangeError.checkNotNegative(cellHeightPx, 'cellHeightPx');
    final result = bindings.ghostty_terminal_resize(
      _handle,
      checkedCols,
      checkedRows,
      cellWidthPx,
      cellHeightPx,
    );
    _checkResult(result, 'ghostty_terminal_resize');
    _cols = checkedCols;
    _rows = checkedRows;
  }

  /// Scrolls the visible viewport within the terminal scrollback.
  void scrollViewport(VtTerminalScrollViewport behavior) {
    _ensureOpen();
    final behaviorPtr = calloc<bindings.GhosttyTerminalScrollViewport>();
    try {
      behaviorPtr.ref.tagAsInt = behavior._tag.value;
      if (behavior._tag ==
          bindings
              .GhosttyTerminalScrollViewportTag
              .GHOSTTY_SCROLL_VIEWPORT_DELTA) {
        behaviorPtr.ref.value.delta = behavior.delta;
      }
      bindings.ghostty_terminal_scroll_viewport(_handle, behaviorPtr.ref);
    } finally {
      calloc.free(behaviorPtr);
    }
  }

  /// Scrolls to the top of the terminal scrollback.
  void scrollToTop() {
    scrollViewport(const VtTerminalScrollViewport.top());
  }

  /// Scrolls back to the active bottom of the terminal.
  void scrollToBottom() {
    scrollViewport(const VtTerminalScrollViewport.bottom());
  }

  /// Scrolls by [delta] rows. Negative values move up.
  void scrollBy(int delta) {
    scrollViewport(VtTerminalScrollViewport.delta(delta));
  }

  /// Resolves a cell position within the terminal grid.
  VtGridRefSnapshot gridRef(VtPoint point) {
    _ensureOpen();
    final out = calloc<bindings.GhosttyGridRef>();
    final nativePoint = calloc<bindings.GhosttyPoint>();
    try {
      out.ref.size = ffi.sizeOf<bindings.GhosttyGridRef>();
      point._writeTo(nativePoint.ref);
      _checkResult(
        bindings.ghostty_terminal_grid_ref(_handle, nativePoint.ref, out),
        'ghostty_terminal_grid_ref',
      );
      return VtGridRefSnapshot.fromNative(out);
    } finally {
      calloc.free(nativePoint);
      calloc.free(out);
    }
  }

  /// Resolves the active-screen cell at zero-based column [x] and row [y].
  VtGridRefSnapshot activeCell(int x, int y) => gridRef(VtPoint.active(x, y));

  /// Resolves the viewport cell at zero-based column [x] and row [y].
  VtGridRefSnapshot viewportCell(int x, int y) =>
      gridRef(VtPoint.viewport(x, y));

  /// Resolves the screen cell at zero-based column [x] and row [y].
  VtGridRefSnapshot screenCell(int x, int y) => gridRef(VtPoint.screen(x, y));

  /// Resolves the history cell at zero-based column [x] and row [y].
  VtGridRefSnapshot historyCell(int x, int y) => gridRef(VtPoint.history(x, y));

  /// Creates a formatter that reflects the terminal state on each call.
  VtTerminalFormatter createFormatter([
    VtFormatterTerminalOptions options = const VtFormatterTerminalOptions(),
  ]) {
    _ensureOpen();
    final formatter = VtTerminalFormatter._(this, options);
    _formatters.add(formatter);
    return formatter;
  }

  /// Creates a high-level render-state wrapper for this terminal.
  VtRenderState createRenderState() {
    _ensureOpen();
    return VtRenderState._(this);
  }

  /// Releases terminal resources.
  void close() {
    if (_closed) {
      return;
    }
    for (final formatter in List<VtTerminalFormatter>.from(_formatters)) {
      formatter.close();
    }
    // Clean up native callables before freeing the terminal handle.
    _writePtyCallable?.close();
    _writePtyCallable = null;
    _onWritePty = null;

    _bellCallable?.close();
    _bellCallable = null;
    _onBell = null;

    _titleChangedCallable?.close();
    _titleChangedCallable = null;
    _onTitleChanged = null;

    _sizeQueryCallable?.close();
    _sizeQueryCallable = null;
    _onSizeQuery = null;

    _colorSchemeQueryCallable?.close();
    _colorSchemeQueryCallable = null;
    _onColorSchemeQuery = null;

    _deviceAttributesQueryCallable?.close();
    _deviceAttributesQueryCallable = null;
    _onDeviceAttributesQuery = null;

    _enquiryCallable?.close();
    _enquiryCallable = null;
    _onEnquiry = null;
    if (_enquiryResponsePtr != ffi.nullptr) {
      calloc.free(_enquiryResponsePtr);
      _enquiryResponsePtr = ffi.nullptr;
      _enquiryResponseLen = 0;
    }

    _xtversionCallable?.close();
    _xtversionCallable = null;
    _onXtversion = null;
    if (_xtversionResponsePtr != ffi.nullptr) {
      calloc.free(_xtversionResponsePtr);
      _xtversionResponsePtr = ffi.nullptr;
      _xtversionResponseLen = 0;
    }

    bindings.ghostty_terminal_free(_handle);
    _closed = true;
  }
}

/// High-level wrapper over Ghostty's incremental render-state API.
final class VtRenderState {
  VtRenderState._(this._terminal) : _handle = _newRenderState();

  final VtTerminal _terminal;
  final bindings.GhosttyRenderState _handle;
  bool _closed = false;

  static bindings.GhosttyRenderState _newRenderState() {
    final out = calloc<bindings.GhosttyRenderState>();
    try {
      _checkResult(
        bindings.ghostty_render_state_new(ffi.nullptr, out),
        'ghostty_render_state_new',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtRenderState is already closed.');
    }
  }

  void update() {
    _ensureOpen();
    _terminal._ensureOpen();
    _checkResult(
      bindings.ghostty_render_state_update(_handle, _terminal._handle),
      'ghostty_render_state_update',
    );
  }

  /// The current dirty state for this render state.
  bindings.GhosttyRenderStateDirty get dirty {
    _ensureOpen();
    final out = calloc<ffi.UnsignedInt>();
    try {
      _checkResult(
        bindings.ghostty_render_state_get(
          _handle,
          bindings.GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_DIRTY,
          out.cast(),
        ),
        'ghostty_render_state_get',
      );
      return bindings.GhosttyRenderStateDirty.fromValue(out.value);
    } finally {
      calloc.free(out);
    }
  }

  /// Updates the dirty state for this render state.
  set dirty(bindings.GhosttyRenderStateDirty value) {
    _ensureOpen();
    final nativeValue = calloc<ffi.UnsignedInt>();
    try {
      nativeValue.value = value.value;
      _checkResult(
        bindings.ghostty_render_state_set(
          _handle,
          bindings.GhosttyRenderStateOption.GHOSTTY_RENDER_STATE_OPTION_DIRTY,
          nativeValue.cast(),
        ),
        'ghostty_render_state_set',
      );
    } finally {
      calloc.free(nativeValue);
    }
  }

  /// The current viewport width in cells.
  int get cols {
    _ensureOpen();
    final out = calloc<ffi.Uint16>();
    try {
      _checkResult(
        bindings.ghostty_render_state_get(
          _handle,
          bindings.GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLS,
          out.cast(),
        ),
        'ghostty_render_state_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// The current viewport height in cells.
  int get rows {
    _ensureOpen();
    final out = calloc<ffi.Uint16>();
    try {
      _checkResult(
        bindings.ghostty_render_state_get(
          _handle,
          bindings.GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROWS,
          out.cast(),
        ),
        'ghostty_render_state_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// The current default colors and palette for this render state.
  VtRenderColors get colors {
    _ensureOpen();
    final out = calloc<bindings.GhosttyRenderStateColors>();
    try {
      out.ref.size = ffi.sizeOf<bindings.GhosttyRenderStateColors>();
      _checkResult(
        bindings.ghostty_render_state_colors_get(_handle, out),
        'ghostty_render_state_colors_get',
      );
      return VtRenderColors.fromNative(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  /// The visual style used to paint the cursor.
  bindings.GhosttyRenderStateCursorVisualStyle get cursorVisualStyle {
    _ensureOpen();
    final out = calloc<ffi.UnsignedInt>();
    try {
      _checkResult(
        bindings.ghostty_render_state_get(
          _handle,
          bindings
              .GhosttyRenderStateData
              .GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
          out.cast(),
        ),
        'ghostty_render_state_get',
      );
      return bindings.GhosttyRenderStateCursorVisualStyle.fromValue(out.value);
    } finally {
      calloc.free(out);
    }
  }

  /// Whether the cursor is currently visible.
  bool get cursorVisible => _renderStateBool(
    bindings.GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
  );

  /// Whether the cursor should blink.
  bool get cursorBlinking => _renderStateBool(
    bindings.GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,
  );

  /// Whether the cursor is currently over password input.
  bool get cursorPasswordInput => _renderStateBool(
    bindings
        .GhosttyRenderStateData
        .GHOSTTY_RENDER_STATE_DATA_CURSOR_PASSWORD_INPUT,
  );

  /// Whether the cursor currently has a visible viewport position.
  bool get cursorHasViewportPosition => _renderStateBool(
    bindings
        .GhosttyRenderStateData
        .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
  );

  /// The zero-based viewport x coordinate of the cursor, when visible.
  int? get cursorViewportX => cursorHasViewportPosition
      ? _renderStateUint16(
          bindings
              .GhosttyRenderStateData
              .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
        )
      : null;

  /// The zero-based viewport y coordinate of the cursor, when visible.
  int? get cursorViewportY => cursorHasViewportPosition
      ? _renderStateUint16(
          bindings
              .GhosttyRenderStateData
              .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
        )
      : null;

  /// Whether the cursor is positioned on the tail of a wide grapheme.
  bool? get cursorOnWideTail => cursorHasViewportPosition
      ? _renderStateBool(
          bindings
              .GhosttyRenderStateData
              .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL,
        )
      : null;

  /// A lightweight cursor snapshot for this render state.
  VtRenderCursorSnapshot get cursorSnapshot => VtRenderCursorSnapshot(
    visualStyle: cursorVisualStyle,
    visible: cursorVisible,
    blinking: cursorBlinking,
    passwordInput: cursorPasswordInput,
    hasViewportPosition: cursorHasViewportPosition,
    viewportX: cursorViewportX,
    viewportY: cursorViewportY,
    onWideTail: cursorOnWideTail,
  );

  int _renderStateUint16(bindings.GhosttyRenderStateData data) {
    final out = calloc<ffi.Uint16>();
    try {
      _checkResult(
        bindings.ghostty_render_state_get(_handle, data, out.cast()),
        'ghostty_render_state_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  bool _renderStateBool(bindings.GhosttyRenderStateData data) {
    final out = calloc<ffi.Bool>();
    try {
      _checkResult(
        bindings.ghostty_render_state_get(_handle, data, out.cast()),
        'ghostty_render_state_get',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Visits the live row iterator for this render state.
  ///
  /// The rows exposed to [visitor] remain valid until this render state is
  /// updated again.
  void visitRows(void Function(VtRenderRowCursor row) visitor) {
    _ensureOpen();
    final iterator = calloc<bindings.GhosttyRenderStateRowIterator>();
    try {
      _checkResult(
        bindings.ghostty_render_state_row_iterator_new(ffi.nullptr, iterator),
        'ghostty_render_state_row_iterator_new',
      );
      final iteratorHandle = iterator.value;
      _checkResult(
        bindings.ghostty_render_state_get(
          _handle,
          bindings
              .GhosttyRenderStateData
              .GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
          iterator.cast(),
        ),
        'ghostty_render_state_get',
      );
      while (bindings.ghostty_render_state_row_iterator_next(iteratorHandle)) {
        visitor(VtRenderRowCursor._(iteratorHandle));
      }
    } finally {
      final iteratorHandle = iterator.value;
      if (iteratorHandle != ffi.nullptr) {
        bindings.ghostty_render_state_row_iterator_free(iteratorHandle);
      }
      calloc.free(iterator);
    }
  }

  VtRenderSnapshot snapshot() {
    _ensureOpen();
    return VtRenderSnapshot(
      cols: cols,
      rows: rows,
      dirty: dirty,
      colors: colors,
      cursor: cursorSnapshot,
      rowsData: _snapshotRows(),
    );
  }

  List<VtRenderRowSnapshot> _snapshotRows() {
    final iterator = calloc<bindings.GhosttyRenderStateRowIterator>();
    try {
      _checkResult(
        bindings.ghostty_render_state_row_iterator_new(ffi.nullptr, iterator),
        'ghostty_render_state_row_iterator_new',
      );
      final iteratorHandle = iterator.value;
      _checkResult(
        bindings.ghostty_render_state_get(
          _handle,
          bindings
              .GhosttyRenderStateData
              .GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
          iterator.cast(),
        ),
        'ghostty_render_state_get',
      );
      final rows = <VtRenderRowSnapshot>[];
      while (bindings.ghostty_render_state_row_iterator_next(iteratorHandle)) {
        rows.add(_snapshotRow(iteratorHandle));
      }
      return rows;
    } finally {
      final iteratorHandle = iterator.value;
      if (iteratorHandle != ffi.nullptr) {
        bindings.ghostty_render_state_row_iterator_free(iteratorHandle);
      }
      calloc.free(iterator);
    }
  }

  VtRenderRowSnapshot _snapshotRow(
    bindings.GhosttyRenderStateRowIterator iterator,
  ) {
    final dirty = calloc<ffi.Bool>();
    final raw = calloc<bindings.GhosttyRow>();
    final cells = calloc<bindings.GhosttyRenderStateRowCells>();
    try {
      _checkResult(
        bindings.ghostty_render_state_row_get(
          iterator,
          bindings
              .GhosttyRenderStateRowData
              .GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
          dirty.cast(),
        ),
        'ghostty_render_state_row_get',
      );
      _checkResult(
        bindings.ghostty_render_state_row_get(
          iterator,
          bindings.GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_RAW,
          raw.cast(),
        ),
        'ghostty_render_state_row_get',
      );
      _checkResult(
        bindings.ghostty_render_state_row_cells_new(ffi.nullptr, cells),
        'ghostty_render_state_row_cells_new',
      );
      final cellsHandle = cells.value;
      _checkResult(
        bindings.ghostty_render_state_row_get(
          iterator,
          bindings
              .GhosttyRenderStateRowData
              .GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
          cells.cast(),
        ),
        'ghostty_render_state_row_get',
      );
      final rowCells = <VtRenderCellSnapshot>[];
      while (bindings.ghostty_render_state_row_cells_next(cellsHandle)) {
        rowCells.add(_snapshotCell(cellsHandle));
      }
      return VtRenderRowSnapshot(
        dirty: dirty.value,
        raw: VtRowSnapshot.fromRaw(raw.value),
        cells: rowCells,
      );
    } finally {
      final cellsHandle = cells.value;
      if (cellsHandle != ffi.nullptr) {
        bindings.ghostty_render_state_row_cells_free(cellsHandle);
      }
      calloc.free(cells);
      calloc.free(raw);
      calloc.free(dirty);
    }
  }

  VtRenderCellSnapshot _snapshotCell(
    bindings.GhosttyRenderStateRowCells cells,
  ) {
    final raw = calloc<bindings.GhosttyCell>();
    final style = calloc<bindings.GhosttyStyle>();
    final graphemeLen = calloc<ffi.Uint32>();
    try {
      style.ref.size = ffi.sizeOf<bindings.GhosttyStyle>();
      _checkResult(
        bindings.ghostty_render_state_row_cells_get(
          cells,
          bindings
              .GhosttyRenderStateRowCellsData
              .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
          raw.cast(),
        ),
        'ghostty_render_state_row_cells_get',
      );
      _checkResult(
        bindings.ghostty_render_state_row_cells_get(
          cells,
          bindings
              .GhosttyRenderStateRowCellsData
              .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
          style.cast(),
        ),
        'ghostty_render_state_row_cells_get',
      );
      _checkResult(
        bindings.ghostty_render_state_row_cells_get(
          cells,
          bindings
              .GhosttyRenderStateRowCellsData
              .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
          graphemeLen.cast(),
        ),
        'ghostty_render_state_row_cells_get',
      );
      final graphemes = graphemeLen.value == 0
          ? ''
          : (() {
              final buffer = calloc<ffi.Uint32>(graphemeLen.value);
              try {
                _checkResult(
                  bindings.ghostty_render_state_row_cells_get(
                    cells,
                    bindings
                        .GhosttyRenderStateRowCellsData
                        .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                    buffer.cast(),
                  ),
                  'ghostty_render_state_row_cells_get',
                );
                return String.fromCharCodes(
                  buffer.asTypedList(graphemeLen.value),
                );
              } finally {
                calloc.free(buffer);
              }
            })();

      return VtRenderCellSnapshot(
        raw: VtCellSnapshot.fromRaw(raw.value),
        style: VtStyle.fromNative(style.ref),
        graphemes: graphemes,
      );
    } finally {
      calloc.free(graphemeLen);
      calloc.free(style);
      calloc.free(raw);
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_render_state_free(_handle);
    _closed = true;
  }
}

/// Mutable mouse event used with [VtMouseEncoder].
final class VtMouseEvent {
  VtMouseEvent() : _handle = _newMouseEvent();

  final bindings.GhosttyMouseEvent _handle;
  bool _closed = false;

  static bindings.GhosttyMouseEvent _newMouseEvent() {
    final out = calloc<bindings.GhosttyMouseEvent>();
    try {
      _checkResult(
        bindings.ghostty_mouse_event_new(ffi.nullptr, out),
        'ghostty_mouse_event_new',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtMouseEvent is already closed.');
    }
  }

  bindings.GhosttyMouseAction get action {
    _ensureOpen();
    return bindings.ghostty_mouse_event_get_action(_handle);
  }

  set action(bindings.GhosttyMouseAction value) {
    _ensureOpen();
    bindings.ghostty_mouse_event_set_action(_handle, value);
  }

  bindings.GhosttyMouseButton? get button {
    _ensureOpen();
    final out = calloc<ffi.UnsignedInt>();
    try {
      final hasButton = bindings.ghostty_mouse_event_get_button(_handle, out);
      if (!hasButton) {
        return null;
      }
      return bindings.GhosttyMouseButton.fromValue(out.value);
    } finally {
      calloc.free(out);
    }
  }

  set button(bindings.GhosttyMouseButton? value) {
    _ensureOpen();
    if (value == null) {
      bindings.ghostty_mouse_event_clear_button(_handle);
      return;
    }
    bindings.ghostty_mouse_event_set_button(_handle, value);
  }

  int get mods {
    _ensureOpen();
    return bindings.ghostty_mouse_event_get_mods(_handle);
  }

  set mods(int value) {
    _ensureOpen();
    bindings.ghostty_mouse_event_set_mods(_handle, value);
  }

  VtMousePosition get position {
    _ensureOpen();
    return VtMousePosition.fromNative(
      bindings.ghostty_mouse_event_get_position(_handle),
    );
  }

  set position(VtMousePosition value) {
    _ensureOpen();
    final native = calloc<bindings.GhosttyMousePosition>();
    try {
      value._writeTo(native.ref);
      bindings.ghostty_mouse_event_set_position(_handle, native.ref);
    } finally {
      calloc.free(native);
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_mouse_event_free(_handle);
    _closed = true;
  }
}

/// Ghostty mouse encoder wrapper.
final class VtMouseEncoder {
  VtMouseEncoder() : _handle = _newMouseEncoder();

  final bindings.GhosttyMouseEncoder _handle;
  bool _closed = false;

  static bindings.GhosttyMouseEncoder _newMouseEncoder() {
    final out = calloc<bindings.GhosttyMouseEncoder>();
    try {
      _checkResult(
        bindings.ghostty_mouse_encoder_new(ffi.nullptr, out),
        'ghostty_mouse_encoder_new',
      );
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtMouseEncoder is already closed.');
    }
  }

  void _setOption(
    bindings.GhosttyMouseEncoderOption option,
    ffi.Pointer<ffi.Void> value,
  ) {
    bindings.ghostty_mouse_encoder_setopt(_handle, option, value);
  }

  set trackingMode(bindings.GhosttyMouseTrackingMode value) {
    _ensureOpen();
    final out = calloc<ffi.UnsignedInt>()..value = value.value;
    try {
      _setOption(
        bindings.GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_EVENT,
        out.cast(),
      );
    } finally {
      calloc.free(out);
    }
  }

  set format(bindings.GhosttyMouseFormat value) {
    _ensureOpen();
    final out = calloc<ffi.UnsignedInt>()..value = value.value;
    try {
      _setOption(
        bindings.GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_FORMAT,
        out.cast(),
      );
    } finally {
      calloc.free(out);
    }
  }

  set size(VtMouseEncoderSize value) {
    _ensureOpen();
    final native = calloc<bindings.GhosttyMouseEncoderSize>();
    try {
      value._writeTo(native.ref);
      _setOption(
        bindings.GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
        native.cast(),
      );
    } finally {
      calloc.free(native);
    }
  }

  set anyButtonPressed(bool value) {
    _ensureOpen();
    final out = calloc<ffi.Bool>()..value = value;
    try {
      _setOption(
        bindings
            .GhosttyMouseEncoderOption
            .GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
        out.cast(),
      );
    } finally {
      calloc.free(out);
    }
  }

  set trackLastCell(bool value) {
    _ensureOpen();
    final out = calloc<ffi.Bool>()..value = value;
    try {
      _setOption(
        bindings
            .GhosttyMouseEncoderOption
            .GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,
        out.cast(),
      );
    } finally {
      calloc.free(out);
    }
  }

  void setOptionsFromTerminal(VtTerminal terminal) {
    _ensureOpen();
    terminal._ensureOpen();
    bindings.ghostty_mouse_encoder_setopt_from_terminal(
      _handle,
      terminal._handle,
    );
  }

  void reset() {
    _ensureOpen();
    bindings.ghostty_mouse_encoder_reset(_handle);
  }

  Uint8List encode(VtMouseEvent event) {
    _ensureOpen();
    event._ensureOpen();
    return _encodeCharSequence(
      'ghostty_mouse_encoder_encode',
      (buffer, length, outWritten) => bindings.ghostty_mouse_encoder_encode(
        _handle,
        event._handle,
        buffer,
        length,
        outWritten,
      ),
    );
  }

  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_mouse_encoder_free(_handle);
    _closed = true;
  }
}

/// Reusable formatter for a [VtTerminal].
final class VtTerminalFormatter {
  VtTerminalFormatter._(VtTerminal terminal, VtFormatterTerminalOptions options)
    : _terminal = terminal,
      _handle = _newFormatter(terminal, options);

  final VtTerminal _terminal;
  final bindings.GhosttyFormatter _handle;
  bool _closed = false;

  static bindings.GhosttyFormatter _newFormatter(
    VtTerminal terminal,
    VtFormatterTerminalOptions options,
  ) {
    final out = calloc<bindings.GhosttyFormatter>();
    final nativeOptions = calloc<bindings.GhosttyFormatterTerminalOptions>();
    try {
      final screen = options.extra.screen;
      nativeOptions.ref
        ..size = ffi.sizeOf<bindings.GhosttyFormatterTerminalOptions>()
        ..emitAsInt = options.emit.value
        ..unwrap = options.unwrap
        ..trim = options.trim
        ..extra.size = ffi.sizeOf<bindings.GhosttyFormatterTerminalExtra>()
        ..extra.palette = options.extra.palette
        ..extra.modes = options.extra.modes
        ..extra.scrolling_region = options.extra.scrollingRegion
        ..extra.tabstops = options.extra.tabstops
        ..extra.pwd = options.extra.pwd
        ..extra.keyboard = options.extra.keyboard
        ..extra.screen.size = ffi.sizeOf<bindings.GhosttyFormatterScreenExtra>()
        ..extra.screen.cursor = screen.cursor
        ..extra.screen.style = screen.style
        ..extra.screen.hyperlink = screen.hyperlink
        ..extra.screen.protection = screen.protection
        ..extra.screen.kitty_keyboard = screen.kittyKeyboard
        ..extra.screen.charsets = screen.charsets;

      final result = bindings.ghostty_formatter_terminal_new(
        ffi.nullptr,
        out,
        terminal._handle,
        nativeOptions.ref,
      );
      _checkResult(result, 'ghostty_formatter_terminal_new');
      return out.value;
    } finally {
      calloc.free(nativeOptions);
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtTerminalFormatter is already closed.');
    }
  }

  int _requiredSize() {
    final outWritten = calloc<ffi.Size>();
    try {
      final result = bindings.ghostty_formatter_format_buf(
        _handle,
        ffi.nullptr,
        0,
        outWritten,
      );
      if (result == bindings.GhosttyResult.GHOSTTY_SUCCESS) {
        return outWritten.value;
      }
      if (result != bindings.GhosttyResult.GHOSTTY_OUT_OF_SPACE) {
        _checkResult(result, 'ghostty_formatter_format_buf(size_probe)');
      }
      return outWritten.value;
    } finally {
      calloc.free(outWritten);
    }
  }

  /// Formats the terminal into a byte buffer.
  Uint8List formatBytes() {
    _ensureOpen();
    _terminal._ensureOpen();

    var required = _requiredSize();
    if (required == 0) {
      return Uint8List(0);
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      final buffer = calloc<ffi.Uint8>(required);
      final outWritten = calloc<ffi.Size>();
      try {
        final result = bindings.ghostty_formatter_format_buf(
          _handle,
          buffer,
          required,
          outWritten,
        );
        if (result == bindings.GhosttyResult.GHOSTTY_SUCCESS) {
          return Uint8List.fromList(buffer.asTypedList(outWritten.value));
        }
        if (result != bindings.GhosttyResult.GHOSTTY_OUT_OF_SPACE) {
          _checkResult(result, 'ghostty_formatter_format_buf');
        }
        required = outWritten.value;
        if (required == 0) {
          return Uint8List(0);
        }
      } finally {
        calloc.free(outWritten);
        calloc.free(buffer);
      }
    }

    throw StateError(
      'VtTerminalFormatter output changed while formatting. Retry the call.',
    );
  }

  /// Formats the terminal using `ghostty_formatter_format_alloc`.
  ///
  /// This path uses a Dart-owned allocator so the returned buffer can be
  /// safely released from Dart after copying it into a [Uint8List].
  Uint8List formatBytesAllocated() {
    return formatBytesAllocatedWith(VtAllocator.dartMalloc);
  }

  /// Formats the terminal using `ghostty_formatter_format_alloc` and [allocator].
  Uint8List formatBytesAllocatedWith(VtAllocator allocator) {
    _ensureOpen();
    _terminal._ensureOpen();

    final outPtr = calloc<ffi.Pointer<ffi.Uint8>>();
    final outLen = calloc<ffi.Size>();
    try {
      final result = bindings.ghostty_formatter_format_alloc(
        _handle,
        allocator.pointer,
        outPtr,
        outLen,
      );
      _checkResult(result, 'ghostty_formatter_format_alloc');

      return allocator.copyBytesAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// Formats the terminal and decodes the bytes into a Dart string.
  String formatText({Encoding encoding = utf8}) {
    final bytes = formatBytes();
    if (encoding == utf8) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return encoding.decode(bytes);
  }

  /// Formats via [formatBytesAllocated] and decodes the result.
  String formatTextAllocated({Encoding encoding = utf8}) {
    return formatTextAllocatedWith(VtAllocator.dartMalloc, encoding: encoding);
  }

  /// Formats via [formatBytesAllocatedWith] and decodes the result.
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

  /// Releases formatter resources.
  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_formatter_free(_handle);
    _terminal._detachFormatter(this);
    _closed = true;
  }
}

/// Streaming OSC (Operating System Command) parser.
///
/// Feeds terminal bytes through the parser to extract OSC sequences
/// such as window title changes.
///
/// ```dart
/// final parser = VtOscParser();
/// // Feed an OSC 2 (set window title) sequence byte by byte
/// parser.addText('\x1b]2;My Title\x07');
/// // ... or feed individual bytes with addByte()
///
/// final command = parser.end();
/// print(command.windowTitle); // 'My Title'
/// parser.close();
/// ```
final class VtOscParser {
  VtOscParser() : _handle = _newOscParser();

  final bindings.GhosttyOscParser _handle;
  bool _closed = false;

  static bindings.GhosttyOscParser _newOscParser() {
    final out = calloc<bindings.GhosttyOscParser>();
    try {
      final result = bindings.ghostty_osc_new(ffi.nullptr, out);
      _checkResult(result, 'ghostty_osc_new');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtOscParser is already closed.');
    }
  }

  /// Resets parser state.
  void reset() {
    _ensureOpen();
    bindings.ghostty_osc_reset(_handle);
  }

  /// Feeds one byte into the OSC parser.
  void addByte(int byte) {
    _ensureOpen();
    if (byte < 0 || byte > 255) {
      throw RangeError.range(byte, 0, 255, 'byte');
    }
    bindings.ghostty_osc_next(_handle, byte);
  }

  /// Feeds multiple bytes into the OSC parser.
  void addBytes(Iterable<int> bytes) {
    for (final byte in bytes) {
      addByte(byte);
    }
  }

  /// Feeds text bytes (UTF-8 by default) into the OSC parser.
  void addText(String text, {Encoding encoding = utf8}) {
    addBytes(encoding.encode(text));
  }

  /// Finalizes parsing and returns a stable command snapshot.
  ///
  /// Returns a [VtOscCommand] with type [GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID]
  /// if the fed bytes did not form a valid OSC sequence.
  VtOscCommand end({int terminator = 0x07}) {
    _ensureOpen();
    if (terminator < 0 || terminator > 255) {
      throw RangeError.range(terminator, 0, 255, 'terminator');
    }

    final command = bindings.ghostty_osc_end(_handle, terminator);

    // Guard: if the native call returned a null pointer, treat as invalid.
    if (command == ffi.nullptr) {
      return const VtOscCommand(
        type: bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID,
      );
    }

    final type = bindings.ghostty_osc_command_type(command);

    // Guard: don't attempt to extract data from invalid/unrecognised commands
    // — the native library may segfault if asked for data on a command that
    // doesn't carry it.
    if (type == bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID) {
      return VtOscCommand(type: type);
    }

    String? windowTitle;

    // Only query the window-title data field for command types that carry it.
    if (type ==
            bindings
                .GhosttyOscCommandType
                .GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE ||
        type ==
            bindings
                .GhosttyOscCommandType
                .GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON) {
      final out = calloc<ffi.Pointer<ffi.Char>>();
      try {
        final hasTitle = bindings.ghostty_osc_command_data(
          command,
          bindings
              .GhosttyOscCommandData
              .GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR,
          out.cast(),
        );
        final ptr = out.value;
        if (hasTitle && ptr != ffi.nullptr) {
          windowTitle = ptr.cast<Utf8>().toDartString();
        }
      } finally {
        calloc.free(out);
      }
    }

    return VtOscCommand(type: type, windowTitle: windowTitle);
  }

  /// Releases parser resources.
  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_osc_free(_handle);
    _closed = true;
  }
}

/// Parsed OSC command snapshot.
///
/// Contains the command [type] and optional data such as [windowTitle]
/// extracted during parsing.
final class VtOscCommand {
  const VtOscCommand({required this.type, this.windowTitle});

  final bindings.GhosttyOscCommandType type;

  /// Window title when available for title-changing OSC commands.
  final String? windowTitle;

  /// Whether this command represents a valid parsed OSC command.
  bool get isValid =>
      type != bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID;

  /// Whether this command changes the terminal window title or icon title.
  bool get isWindowTitleChange =>
      type ==
          bindings
              .GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE ||
      type ==
          bindings
              .GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON ||
      type ==
          bindings
              .GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_CONEMU_CHANGE_TAB_TITLE;

  /// Whether this command belongs to semantic prompt integration.
  bool get isSemanticPrompt =>
      type ==
      bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_SEMANTIC_PROMPT;

  /// Whether this command carries clipboard-related behavior.
  bool get isClipboardRelated =>
      type ==
      bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS;

  /// Whether this command reports the present working directory.
  bool get isPwdReport =>
      type == bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_REPORT_PWD;

  /// Whether this command starts or ends a hyperlink range.
  bool get isHyperlink =>
      type ==
          bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_HYPERLINK_START ||
      type == bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_HYPERLINK_END;

  /// Whether this command is part of color/palette negotiation.
  bool get isColorProtocol =>
      type ==
          bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_COLOR_OPERATION ||
      type ==
          bindings
              .GhosttyOscCommandType
              .GHOSTTY_OSC_COMMAND_KITTY_COLOR_PROTOCOL;

  /// Whether this command belongs to the ConEmu OSC extensions.
  bool get isConEmuExtension => switch (type) {
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_SLEEP ||
    bindings
        .GhosttyOscCommandType
        .GHOSTTY_OSC_COMMAND_CONEMU_SHOW_MESSAGE_BOX ||
    bindings
        .GhosttyOscCommandType
        .GHOSTTY_OSC_COMMAND_CONEMU_CHANGE_TAB_TITLE ||
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_PROGRESS_REPORT ||
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_WAIT_INPUT ||
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_GUIMACRO ||
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_RUN_PROCESS ||
    bindings
        .GhosttyOscCommandType
        .GHOSTTY_OSC_COMMAND_CONEMU_OUTPUT_ENVIRONMENT_VARIABLE ||
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_XTERM_EMULATION ||
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CONEMU_COMMENT => true,
    _ => false,
  };

  /// Whether this command belongs to Kitty-specific OSC extensions.
  bool get isKittyExtension => switch (type) {
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_KITTY_COLOR_PROTOCOL ||
    bindings.GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_KITTY_TEXT_SIZING =>
      true,
    _ => false,
  };
}

/// Parsed data for unknown SGR attributes.
final class VtSgrUnknownData {
  const VtSgrUnknownData({required this.full, required this.partial});

  final List<int> full;
  final List<int> partial;
}

/// High-level view of an SGR attribute.
final class VtSgrAttributeData {
  const VtSgrAttributeData._({
    required this.tag,
    this.unknown,
    this.underline,
    this.rgb,
    this.paletteIndex,
  });

  final bindings.GhosttySgrAttributeTag tag;
  final VtSgrUnknownData? unknown;
  final bindings.GhosttySgrUnderline? underline;
  final VtRgbColor? rgb;
  final int? paletteIndex;

  static VtSgrAttributeData fromPointer(
    ffi.Pointer<bindings.GhosttySgrAttribute> nativePtr,
  ) {
    final tag = bindings.ghostty_sgr_attribute_tag(nativePtr.ref);
    final value = bindings.ghostty_sgr_attribute_value(nativePtr).ref;
    switch (tag) {
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNKNOWN:
        final unknown = value.unknown;
        final fullOut = calloc<ffi.Pointer<ffi.Uint16>>();
        final partialOut = calloc<ffi.Pointer<ffi.Uint16>>();
        late final List<int> full;
        late final List<int> partial;
        try {
          final fullLen = bindings.ghostty_sgr_unknown_full(unknown, fullOut);
          final fullPtr = fullOut.value;
          full = fullLen == 0 || fullPtr == ffi.nullptr
              ? const <int>[]
              : List<int>.unmodifiable(fullPtr.asTypedList(fullLen));

          final partialLen = bindings.ghostty_sgr_unknown_partial(
            unknown,
            partialOut,
          );
          final partialPtr = partialOut.value;
          partial = partialLen == 0 || partialPtr == ffi.nullptr
              ? const <int>[]
              : List<int>.unmodifiable(partialPtr.asTypedList(partialLen));
        } finally {
          calloc.free(fullOut);
          calloc.free(partialOut);
        }
        return VtSgrAttributeData._(
          tag: tag,
          unknown: VtSgrUnknownData(full: full, partial: partial),
        );
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE:
        return VtSgrAttributeData._(tag: tag, underline: value.underline);
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR:
        return VtSgrAttributeData._(
          tag: tag,
          rgb: VtRgbColor.fromNative(value.underline_color),
        );
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG:
        return VtSgrAttributeData._(
          tag: tag,
          rgb: VtRgbColor.fromNative(value.direct_color_fg),
        );
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG:
        return VtSgrAttributeData._(
          tag: tag,
          rgb: VtRgbColor.fromNative(value.direct_color_bg),
        );
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_UNDERLINE_COLOR_256:
        return VtSgrAttributeData._(
          tag: tag,
          paletteIndex: value.underline_color_256,
        );
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_8:
        return VtSgrAttributeData._(tag: tag, paletteIndex: value.bg_8);
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_8:
        return VtSgrAttributeData._(tag: tag, paletteIndex: value.fg_8);
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_BG_8:
        return VtSgrAttributeData._(tag: tag, paletteIndex: value.bright_bg_8);
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BRIGHT_FG_8:
        return VtSgrAttributeData._(tag: tag, paletteIndex: value.bright_fg_8);
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_256:
        return VtSgrAttributeData._(tag: tag, paletteIndex: value.bg_256);
      case bindings.GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_256:
        return VtSgrAttributeData._(tag: tag, paletteIndex: value.fg_256);
      default:
        return VtSgrAttributeData._(tag: tag);
    }
  }
}

/// SGR (Select Graphic Rendition) parameter parser.
///
/// Parses CSI SGR parameter values into structured attribute data.
///
/// ```dart
/// final parser = VtSgrParser();
/// final attrs = parser.parseParams([1, 31]); // bold + red foreground
/// for (final attr in attrs) {
///   print(attr.tag);
/// }
/// parser.close();
/// ```
final class VtSgrParser {
  VtSgrParser()
    : _handle = _newSgrParser(),
      _attrPtr = calloc<bindings.GhosttySgrAttribute>();

  final bindings.GhosttySgrParser _handle;
  final ffi.Pointer<bindings.GhosttySgrAttribute> _attrPtr;
  bool _closed = false;

  static bindings.GhosttySgrParser _newSgrParser() {
    final out = calloc<bindings.GhosttySgrParser>();
    try {
      final result = bindings.ghostty_sgr_new(ffi.nullptr, out);
      _checkResult(result, 'ghostty_sgr_new');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtSgrParser is already closed.');
    }
  }

  /// Resets iteration state.
  void reset() {
    _ensureOpen();
    bindings.ghostty_sgr_reset(_handle);
  }

  /// Sets SGR parameter values and optional separators.
  ///
  /// If [separators] is set, it must match [params] length and should contain
  /// separator bytes such as `;` and `:`.
  void setParams(List<int> params, {String? separators}) {
    _ensureOpen();
    if (separators != null && separators.length != params.length) {
      throw ArgumentError.value(
        separators,
        'separators',
        'Must have same length as params.',
      );
    }

    final paramsPtr = calloc<ffi.Uint16>(params.length);
    ffi.Pointer<ffi.Char> separatorsPtr = ffi.nullptr;
    ffi.Pointer<ffi.Char>? allocatedSeparators;
    try {
      for (var i = 0; i < params.length; i++) {
        final value = params[i];
        if (value < 0 || value > 0xFFFF) {
          throw RangeError.range(value, 0, 0xFFFF, 'params[$i]');
        }
        paramsPtr[i] = value;
      }

      if (separators != null) {
        allocatedSeparators = calloc<ffi.Char>(separators.length);
        for (var i = 0; i < separators.length; i++) {
          final value = separators.codeUnitAt(i);
          if (value > 0xFF) {
            throw RangeError.range(value, 0, 0xFF, 'separators[$i]');
          }
          allocatedSeparators[i] = value;
        }
        separatorsPtr = allocatedSeparators;
      }

      final result = bindings.ghostty_sgr_set_params(
        _handle,
        paramsPtr,
        separatorsPtr,
        params.length,
      );
      _checkResult(result, 'ghostty_sgr_set_params');
    } finally {
      calloc.free(paramsPtr);
      if (allocatedSeparators != null) {
        calloc.free(allocatedSeparators);
      }
    }
  }

  /// Returns the next parsed attribute, or `null` if exhausted.
  VtSgrAttributeData? next() {
    _ensureOpen();
    final hasNext = bindings.ghostty_sgr_next(_handle, _attrPtr);
    if (!hasNext) {
      return null;
    }
    return VtSgrAttributeData.fromPointer(_attrPtr);
  }

  /// Parses all currently configured attributes.
  List<VtSgrAttributeData> parseAll() {
    final out = <VtSgrAttributeData>[];
    while (true) {
      final nextAttr = next();
      if (nextAttr == null) {
        break;
      }
      out.add(nextAttr);
    }
    return out;
  }

  /// Parses [params] and returns all attributes in one call.
  List<VtSgrAttributeData> parseParams(List<int> params, {String? separators}) {
    setParams(params, separators: separators);
    return parseAll();
  }

  /// Releases parser resources.
  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_sgr_free(_handle);
    calloc.free(_attrPtr);
    _closed = true;
  }
}

/// Mutable key event used with [VtKeyEncoder].
///
/// Configure the event's [action], [key], [mods], and [utf8Text] properties,
/// then pass it to [VtKeyEncoder.encode] to produce terminal escape bytes.
///
/// ```dart
/// final event = VtKeyEvent();
/// event
///   ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
///   ..key = GhosttyKey.GHOSTTY_KEY_ENTER
///   ..mods = 0;
/// // ... encode with VtKeyEncoder ...
/// event.close();
/// ```
final class VtKeyEvent {
  VtKeyEvent() : _handle = _newKeyEvent();

  final bindings.GhosttyKeyEvent _handle;
  bool _closed = false;
  ffi.Pointer<ffi.Uint8>? _utf8Storage;

  static bindings.GhosttyKeyEvent _newKeyEvent() {
    final out = calloc<bindings.GhosttyKeyEvent>();
    try {
      final result = bindings.ghostty_key_event_new(ffi.nullptr, out);
      _checkResult(result, 'ghostty_key_event_new');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtKeyEvent is already closed.');
    }
  }

  bindings.GhosttyKeyAction get action {
    _ensureOpen();
    return bindings.ghostty_key_event_get_action(_handle);
  }

  set action(bindings.GhosttyKeyAction value) {
    _ensureOpen();
    bindings.ghostty_key_event_set_action(_handle, value);
  }

  bindings.GhosttyKey get key {
    _ensureOpen();
    return bindings.ghostty_key_event_get_key(_handle);
  }

  set key(bindings.GhosttyKey value) {
    _ensureOpen();
    bindings.ghostty_key_event_set_key(_handle, value);
  }

  int get mods {
    _ensureOpen();
    return bindings.ghostty_key_event_get_mods(_handle);
  }

  set mods(int value) {
    _ensureOpen();
    bindings.ghostty_key_event_set_mods(_handle, value);
  }

  int get consumedMods {
    _ensureOpen();
    return bindings.ghostty_key_event_get_consumed_mods(_handle);
  }

  set consumedMods(int value) {
    _ensureOpen();
    bindings.ghostty_key_event_set_consumed_mods(_handle, value);
  }

  bool get composing {
    _ensureOpen();
    return bindings.ghostty_key_event_get_composing(_handle);
  }

  set composing(bool value) {
    _ensureOpen();
    bindings.ghostty_key_event_set_composing(_handle, value);
  }

  String get utf8Text {
    _ensureOpen();
    final lenPtr = calloc<ffi.Size>();
    try {
      final ptr = bindings.ghostty_key_event_get_utf8(_handle, lenPtr);
      final len = lenPtr.value;
      if (ptr == ffi.nullptr || len == 0) {
        return '';
      }
      final bytes = ptr.cast<ffi.Uint8>().asTypedList(len);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      calloc.free(lenPtr);
    }
  }

  set utf8Text(String value) {
    _ensureOpen();
    _freeUtf8Storage();

    if (value.isEmpty) {
      bindings.ghostty_key_event_set_utf8(_handle, ffi.nullptr, 0);
      return;
    }

    final bytes = utf8.encode(value);
    final ptr = calloc<ffi.Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    _utf8Storage = ptr;
    bindings.ghostty_key_event_set_utf8(
      _handle,
      ptr.cast<ffi.Char>(),
      bytes.length,
    );
  }

  int get unshiftedCodepoint {
    _ensureOpen();
    return bindings.ghostty_key_event_get_unshifted_codepoint(_handle);
  }

  set unshiftedCodepoint(int value) {
    _ensureOpen();
    if (value < 0 || value > 0x10FFFF) {
      throw RangeError.range(value, 0, 0x10FFFF, 'unshiftedCodepoint');
    }
    bindings.ghostty_key_event_set_unshifted_codepoint(_handle, value);
  }

  void _freeUtf8Storage() {
    final storage = _utf8Storage;
    if (storage != null) {
      calloc.free(storage);
      _utf8Storage = null;
    }
  }

  /// Releases key event resources.
  void close() {
    if (_closed) {
      return;
    }
    _freeUtf8Storage();
    bindings.ghostty_key_event_free(_handle);
    _closed = true;
  }
}

/// Terminal key encoder.
///
/// Converts [VtKeyEvent] objects into the byte sequences expected by
/// terminal applications, supporting legacy, xterm, and Kitty keyboard
/// protocol modes.
///
/// ```dart
/// final encoder = VtKeyEncoder();
/// encoder.kittyFlags = GhosttyKittyFlags.disambiguate;
///
/// final event = VtKeyEvent();
/// event
///   ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
///   ..key = GhosttyKey.GHOSTTY_KEY_A
///   ..utf8Text = 'a';
///
/// final bytes = encoder.encode(event);
/// terminal.writeBytes(bytes);
///
/// event.close();
/// encoder.close();
/// ```
final class VtKeyEncoder {
  VtKeyEncoder() : _handle = _newKeyEncoder();

  final bindings.GhosttyKeyEncoder _handle;
  bool _closed = false;

  static bindings.GhosttyKeyEncoder _newKeyEncoder() {
    final out = calloc<bindings.GhosttyKeyEncoder>();
    try {
      final result = bindings.ghostty_key_encoder_new(ffi.nullptr, out);
      _checkResult(result, 'ghostty_key_encoder_new');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('VtKeyEncoder is already closed.');
    }
  }

  void _setBoolOption(bindings.GhosttyKeyEncoderOption option, bool value) {
    final ptr = calloc<ffi.Bool>()..value = value;
    try {
      bindings.ghostty_key_encoder_setopt(_handle, option, ptr.cast());
    } finally {
      calloc.free(ptr);
    }
  }

  /// DEC mode 1: cursor key application mode.
  set cursorKeyApplication(bool enabled) {
    _ensureOpen();
    _setBoolOption(
      bindings
          .GhosttyKeyEncoderOption
          .GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION,
      enabled,
    );
  }

  /// DEC mode 66: keypad key application mode.
  set keypadKeyApplication(bool enabled) {
    _ensureOpen();
    _setBoolOption(
      bindings
          .GhosttyKeyEncoderOption
          .GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION,
      enabled,
    );
  }

  /// DEC mode 1035: ignore keypad with numlock.
  set ignoreKeypadWithNumLock(bool enabled) {
    _ensureOpen();
    _setBoolOption(
      bindings
          .GhosttyKeyEncoderOption
          .GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK,
      enabled,
    );
  }

  /// DEC mode 1036: alt sends escape prefix.
  set altEscPrefix(bool enabled) {
    _ensureOpen();
    _setBoolOption(
      bindings.GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX,
      enabled,
    );
  }

  /// xterm modifyOtherKeys mode 2.
  set modifyOtherKeysState2(bool enabled) {
    _ensureOpen();
    _setBoolOption(
      bindings
          .GhosttyKeyEncoderOption
          .GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2,
      enabled,
    );
  }

  /// Kitty keyboard protocol flags.
  set kittyFlags(int flags) {
    _ensureOpen();
    if (flags < 0 || flags > 0xFF) {
      throw RangeError.range(flags, 0, 0xFF, 'kittyFlags');
    }
    final ptr = calloc<ffi.Uint8>()..value = flags;
    try {
      bindings.ghostty_key_encoder_setopt(
        _handle,
        bindings.GhosttyKeyEncoderOption.GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS,
        ptr.cast(),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  /// macOS option-as-alt behavior.
  set macosOptionAsAlt(bindings.GhosttyOptionAsAlt value) {
    _ensureOpen();
    final ptr = calloc<ffi.UnsignedInt>()..value = value.value;
    try {
      bindings.ghostty_key_encoder_setopt(
        _handle,
        bindings
            .GhosttyKeyEncoderOption
            .GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
        ptr.cast(),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  /// Copies key encoder options from a terminal instance.
  ///
  /// This mirrors terminal modes such as cursor-key application mode and
  /// keyboard protocol settings onto the encoder.
  void setOptionsFromTerminal(VtTerminal terminal) {
    _ensureOpen();
    terminal._ensureOpen();
    bindings.ghostty_key_encoder_setopt_from_terminal(
      _handle,
      terminal._handle,
    );
  }

  /// Encodes a key event into terminal bytes.
  Uint8List encode(VtKeyEvent event) {
    _ensureOpen();
    event._ensureOpen();
    return _encodeCharSequence(
      'ghostty_key_encoder_encode',
      (buffer, length, outWritten) => bindings.ghostty_key_encoder_encode(
        _handle,
        event._handle,
        buffer,
        length,
        outWritten,
      ),
    );
  }

  /// Encodes a key event to a single Dart string of byte code units.
  String encodeToString(VtKeyEvent event) {
    return String.fromCharCodes(encode(event));
  }

  /// Releases key encoder resources.
  void close() {
    if (_closed) {
      return;
    }
    bindings.ghostty_key_encoder_free(_handle);
    _closed = true;
  }
}
