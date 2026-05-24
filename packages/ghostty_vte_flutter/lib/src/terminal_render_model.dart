import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_vte/ghostty_vte.dart';
import 'terminal_snapshot.dart';

/// Resolved cell style derived from Ghostty render-state data.
@immutable
final class GhosttyTerminalResolvedStyle {
  const GhosttyTerminalResolvedStyle({
    required this.foreground,
    required this.background,
    required this.underlineColor,
    this.foregroundToken,
    this.backgroundToken,
    this.underlineColorToken,
    required this.bold,
    required this.italic,
    required this.blink,
    required this.overline,
    required this.strikethrough,
    required this.underline,
    required this.inverse,
    required this.invisible,
    required this.faint,
    this.hasExplicitUnderlineColor = false,
    this.hasExplicitForeground = false,
    this.hasExplicitBackground = false,
  });

  final Color foreground;
  final Color background;
  final Color underlineColor;
  final GhosttyTerminalColor? foregroundToken;
  final GhosttyTerminalColor? backgroundToken;
  final GhosttyTerminalColor? underlineColorToken;
  final bool bold;
  final bool italic;
  final bool blink;
  final bool overline;
  final bool strikethrough;
  final GhosttySgrUnderline underline;
  final bool inverse;
  final bool invisible;
  final bool faint;
  final bool hasExplicitUnderlineColor;
  final bool hasExplicitForeground;
  final bool hasExplicitBackground;

  /// Resolves a formatter-driven style using a Flutter palette and defaults.
  factory GhosttyTerminalResolvedStyle.fromFormattedStyle({
    required GhosttyTerminalStyle style,
    required List<Color> palette,
    required Color defaultForeground,
    required Color defaultBackground,
  }) {
    Color resolveStyleColor({
      required GhosttyTerminalColor? color,
      required Color fallback,
      required List<Color> palette,
    }) {
      if (color == null) {
        return fallback;
      }
      final rgb = color.rgb;
      if (rgb != null) {
        return Color.fromARGB(
          0xFF,
          (rgb >> 16) & 0xFF,
          (rgb >> 8) & 0xFF,
          rgb & 0xFF,
        );
      }
      final index = color.paletteIndex;
      if (index == null) {
        return fallback;
      }
      if (index >= 0 && index < palette.length) {
        return palette[index];
      }
      return GhosttyTerminalPalette.xterm.resolve(
        GhosttyTerminalColor.palette(index),
        fallback: fallback,
      );
    }

    final hasExplicitForeground = style.foreground != null;
    final hasExplicitBackground = style.background != null;
    final hasExplicitUnderlineColor = style.underlineColor != null;
    const transparent = Color(0x00000000);

    var foreground = hasExplicitForeground
        ? resolveStyleColor(
            color: style.foreground,
            fallback: defaultForeground,
            palette: palette,
          )
        : transparent;
    var background = hasExplicitBackground
        ? resolveStyleColor(
            color: style.background,
            fallback: defaultBackground,
            palette: palette,
          )
        : transparent;
    if (style.inverse) {
      final swappedForeground = background;
      background = hasExplicitForeground
          ? foreground
          : (foreground == transparent ? defaultForeground : foreground);
      foreground = hasExplicitBackground
          ? swappedForeground
          : (swappedForeground == transparent
                ? defaultBackground
                : swappedForeground);
    }
    if (style.invisible) {
      foreground = background == transparent ? defaultBackground : background;
    }
    if (style.faint) {
      foreground = foreground.withValues(alpha: 0.72);
    }
    if (foreground == transparent) {
      foreground = defaultForeground;
    }

    return GhosttyTerminalResolvedStyle(
      foreground: foreground,
      background: background,
      underlineColor: resolveStyleColor(
        color: style.underlineColor,
        fallback: hasExplicitUnderlineColor ? defaultForeground : transparent,
        palette: palette,
      ),
      foregroundToken: style.foreground,
      backgroundToken: style.background,
      underlineColorToken: style.underlineColor,
      bold: style.bold,
      italic: style.italic,
      blink: style.blink,
      overline: style.overline,
      strikethrough: style.strikethrough,
      underline:
          style.underline ?? GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE,
      inverse: style.inverse,
      invisible: style.invisible,
      faint: style.faint,
      hasExplicitUnderlineColor: hasExplicitUnderlineColor,
      hasExplicitForeground: hasExplicitForeground,
      hasExplicitBackground: hasExplicitBackground,
    );
  }

  factory GhosttyTerminalResolvedStyle.fromNativeStyle({
    required VtStyle style,
    required List<Color> palette,
    required Color defaultForeground,
    required Color defaultBackground,
  }) {
    Color resolveStyleColor(
      VtStyleColor color, {
      required Color fallback,
      required List<Color> palette,
    }) {
      if (!color.isSet) {
        return fallback;
      }
      final rgb = color.rgb;
      if (rgb != null) {
        return Color.fromARGB(0xFF, rgb.r, rgb.g, rgb.b);
      }
      final index = color.paletteIndex;
      if (index == null) {
        return fallback;
      }
      if (index >= 0 && index < palette.length) {
        return palette[index];
      }
      return GhosttyTerminalPalette.xterm.resolve(
        GhosttyTerminalColor.palette(index),
        fallback: fallback,
      );
    }

    final hasExplicitForeground = style.foreground.isSet;
    final hasExplicitBackground = style.background.isSet;
    final hasExplicitUnderlineColor = style.underlineColor.isSet;
    const transparent = Color(0x00000000);

    var foreground = hasExplicitForeground
        ? resolveStyleColor(
            style.foreground,
            fallback: defaultForeground,
            palette: palette,
          )
        : transparent;
    var background = hasExplicitBackground
        ? resolveStyleColor(
            style.background,
            fallback: defaultBackground,
            palette: palette,
          )
        : transparent;

    if (style.inverse) {
      final swappedForeground = background;
      background = hasExplicitForeground
          ? foreground
          : (foreground == transparent ? defaultForeground : foreground);
      foreground = hasExplicitBackground
          ? swappedForeground
          : (swappedForeground == transparent
                ? defaultBackground
                : swappedForeground);
    }
    if (style.invisible) {
      foreground = background == transparent ? defaultBackground : background;
    }
    if (style.faint) {
      foreground = foreground.withValues(alpha: 0.72);
    }
    if (foreground == transparent) {
      foreground = defaultForeground;
    }

    return GhosttyTerminalResolvedStyle(
      foreground: foreground,
      background: background,
      underlineColor: resolveStyleColor(
        style.underlineColor,
        fallback: hasExplicitUnderlineColor ? defaultForeground : transparent,
        palette: palette,
      ),
      foregroundToken: _toTerminalColor(style.foreground),
      backgroundToken: _toTerminalColor(style.background),
      underlineColorToken: _toTerminalColor(style.underlineColor),
      hasExplicitUnderlineColor: hasExplicitUnderlineColor,
      hasExplicitForeground: hasExplicitForeground,
      hasExplicitBackground: hasExplicitBackground,
      inverse: style.inverse,
      invisible: style.invisible,
      faint: style.faint,
      blink: style.blink,
      bold: style.bold,
      italic: style.italic,
      overline: style.overline,
      strikethrough: style.strikethrough,
      underline: style.underline,
    );
  }

  /// Resolves a native [VtStyle] using shared [VtRenderColors] palette data.
  ///
  /// This keeps Flutter's native render path aligned with the VT package's
  /// palette and default-color resolution rules instead of re-implementing
  /// them locally.
  factory GhosttyTerminalResolvedStyle.fromNativeStyleWithRenderColors({
    required VtStyle style,
    required VtRenderColors colors,
  }) {
    Color toColor(VtRgbColor color) =>
        Color.fromARGB(0xFF, color.r, color.g, color.b);

    final hasExplicitForeground = style.foreground.isSet;
    final hasExplicitBackground = style.background.isSet;
    final hasExplicitUnderlineColor = style.underlineColor.isSet;
    const transparent = Color(0x00000000);

    var foreground = hasExplicitForeground
        ? toColor(colors.resolveForeground(style)!)
        : transparent;
    var background = hasExplicitBackground
        ? toColor(colors.resolveBackground(style)!)
        : transparent;

    if (style.inverse) {
      final swappedForeground = background;
      background = hasExplicitForeground
          ? foreground
          : (foreground == transparent
                ? toColor(colors.foreground)
                : foreground);
      foreground = hasExplicitBackground
          ? swappedForeground
          : (swappedForeground == transparent
                ? toColor(colors.background)
                : swappedForeground);
    }
    if (style.invisible) {
      foreground = background == transparent
          ? toColor(colors.background)
          : background;
    }
    if (style.faint) {
      foreground = foreground.withValues(alpha: 0.72);
    }
    if (foreground == transparent) {
      foreground = toColor(colors.foreground);
    }

    return GhosttyTerminalResolvedStyle(
      foreground: foreground,
      background: background,
      underlineColor: hasExplicitUnderlineColor
          ? toColor(colors.resolveUnderlineColor(style)!)
          : transparent,
      foregroundToken: _toTerminalColor(style.foreground),
      backgroundToken: _toTerminalColor(style.background),
      underlineColorToken: _toTerminalColor(style.underlineColor),
      hasExplicitUnderlineColor: hasExplicitUnderlineColor,
      hasExplicitForeground: hasExplicitForeground,
      hasExplicitBackground: hasExplicitBackground,
      inverse: style.inverse,
      invisible: style.invisible,
      faint: style.faint,
      blink: style.blink,
      bold: style.bold,
      italic: style.italic,
      overline: style.overline,
      strikethrough: style.strikethrough,
      underline: style.underline,
    );
  }

  /// Resolves this style's colors for paint-time use.
  ///
  /// When [metadataColor] is provided and this style has no explicit
  /// background, the metadata color becomes the effective background.
  static ({Color foreground, Color background}) resolveNativeStyleColors({
    required GhosttyTerminalResolvedStyle style,
    required Color defaultForeground,
    required Color defaultBackground,
    Color? metadataColor,
  }) {
    final resolvedBackground =
        metadataColor == null || style.hasExplicitBackground
        ? style.background
        : metadataColor;
    return (foreground: style.foreground, background: resolvedBackground);
  }

  static GhosttyTerminalColor? _toTerminalColor(VtStyleColor color) {
    if (!color.isSet) {
      return null;
    }
    final rgb = color.rgb;
    if (rgb != null) {
      return GhosttyTerminalColor.rgb(rgb.r, rgb.g, rgb.b);
    }
    final paletteIndex = color.paletteIndex;
    if (paletteIndex != null) {
      return GhosttyTerminalColor.palette(paletteIndex);
    }
    return null;
  }
}

/// Cell-level metadata derived from the raw Ghostty cell snapshot.
@immutable
final class GhosttyTerminalRenderCellMetadata {
  const GhosttyTerminalRenderCellMetadata({
    required this.codepoint,
    required this.contentTag,
    required this.styleId,
    required this.colorPaletteIndex,
    required this.colorRgb,
    required this.wide,
    required this.hasBackgroundColor,
    this.backgroundColor,
  });

  /// The raw codepoint stored in this cell.
  final int codepoint;

  /// The raw cell content tag reported by Ghostty.
  final GhosttyCellContentTag contentTag;

  /// The Ghostty style identifier associated with this cell.
  final int styleId;

  /// The palette index for this cell's explicit background color, if any.
  final int? colorPaletteIndex;

  /// The RGB color payload for this cell's explicit background, if any.
  final Color? colorRgb;

  /// The wide-cell state for this cell.
  final GhosttyCellWide wide;

  /// Whether this cell carries an explicit background color payload.
  final bool hasBackgroundColor;

  /// The resolved background color for this cell, if one exists.
  final Color? backgroundColor;
}

/// Visible cell snapshot derived from Ghostty render-state rows.
@immutable
final class GhosttyTerminalRenderCell {
  const GhosttyTerminalRenderCell({
    required this.text,
    required this.width,
    required this.hasText,
    required this.hasStyling,
    required this.hasHyperlink,
    required this.isProtected,
    required this.semanticContent,
    required this.metadata,
    required this.style,
  });

  /// The visible grapheme text for this cell.
  final String text;

  /// The number of terminal columns this cell occupies.
  final int width;

  /// Whether this cell contains visible text.
  final bool hasText;

  /// Whether this cell uses non-default styling.
  final bool hasStyling;

  /// Whether this cell participates in a hyperlink.
  final bool hasHyperlink;

  /// Whether this cell is protected from erase operations.
  final bool isProtected;

  /// The semantic content classification for this cell.
  final GhosttyCellSemanticContent semanticContent;

  /// The raw metadata extracted for this cell.
  final GhosttyTerminalRenderCellMetadata metadata;

  /// The resolved style for this cell.
  final GhosttyTerminalResolvedStyle style;

  /// Whether this cell is marked as shell prompt text.
  bool get isPromptText =>
      semanticContent ==
      GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_PROMPT;

  /// Whether this cell is marked as user input.
  bool get isPromptInput =>
      semanticContent == GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_INPUT;

  /// Whether this cell is marked as command output.
  bool get isPromptOutput =>
      semanticContent ==
      GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_OUTPUT;
}

/// Visible row snapshot derived from Ghostty render-state rows.
@immutable
final class GhosttyTerminalRenderRow {
  const GhosttyTerminalRenderRow({
    required this.dirty,
    required this.wrap,
    required this.wrapContinuation,
    required this.hasGrapheme,
    required this.styled,
    required this.hasHyperlink,
    required this.semanticPrompt,
    required this.kittyVirtualPlaceholder,
    required this.cells,
  });

  /// Whether this row is dirty in the current render pass.
  final bool dirty;

  /// Whether this row soft-wraps into the next row.
  final bool wrap;

  /// Whether this row continues a previous soft-wrapped row.
  final bool wrapContinuation;

  /// Whether this row contains any grapheme-cluster cells.
  final bool hasGrapheme;

  /// Whether this row contains styled cells.
  final bool styled;

  /// Whether this row contains hyperlink cells.
  final bool hasHyperlink;

  /// The shell prompt semantics reported for this row.
  final GhosttyRowSemanticPrompt semanticPrompt;

  /// Whether this row contains a Kitty virtual placeholder.
  final bool kittyVirtualPlaceholder;

  /// The visible cells in this row.
  final List<GhosttyTerminalRenderCell> cells;

  /// Whether this row is marked as a primary semantic prompt row.
  bool get isPrompt =>
      semanticPrompt == GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_PROMPT;

  /// Whether this row continues semantic prompt content from a previous row.
  bool get isPromptContinuation =>
      semanticPrompt ==
      GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION;

  /// Whether this row participates in semantic prompt markup.
  bool get hasSemanticPrompt => isPrompt || isPromptContinuation;
}

/// Cursor viewport state derived from Ghostty render-state data.
@immutable
final class GhosttyTerminalRenderCursor {
  const GhosttyTerminalRenderCursor({
    required this.visualStyle,
    required this.visible,
    required this.blinking,
    required this.passwordInput,
    required this.hasViewportPosition,
    this.row,
    this.col,
    this.onWideTail = false,
    this.color,
  });

  /// The visual cursor shape.
  final GhosttyRenderStateCursorVisualStyle visualStyle;

  /// Whether the cursor should currently be shown.
  final bool visible;

  /// Whether the cursor should blink.
  final bool blinking;

  /// Whether the cursor is positioned over password input.
  final bool passwordInput;

  /// Whether the cursor has a viewport position.
  final bool hasViewportPosition;

  /// The cursor row within the visible viewport, if available.
  final int? row;

  /// The cursor column within the visible viewport, if available.
  final int? col;

  /// Whether the cursor is positioned on the tail half of a wide cell.
  final bool onWideTail;

  /// The explicit cursor color, if Ghostty exposed one.
  final Color? color;
}

/// High-fidelity visible render-state snapshot from Ghostty.
@immutable
final class GhosttyTerminalRenderSnapshot {
  const GhosttyTerminalRenderSnapshot({
    required this.cols,
    required this.rows,
    required this.dirty,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.cursor,
    required this.rowsData,
  });

  /// The visible viewport width in cells.
  final int cols;

  /// The visible viewport height in cells.
  final int rows;

  /// The overall dirty state for this snapshot.
  final GhosttyRenderStateDirty dirty;

  /// The resolved default background color.
  final Color backgroundColor;

  /// The resolved default foreground color.
  final Color foregroundColor;

  /// The current cursor snapshot.
  final GhosttyTerminalRenderCursor cursor;

  /// The visible render rows.
  final List<GhosttyTerminalRenderRow> rowsData;

  /// Whether this snapshot contains row data for the current viewport.
  bool get hasViewportData => rowsData.isNotEmpty;
}
