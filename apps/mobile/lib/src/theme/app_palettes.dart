import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Built-in theme variants shipped with Sidemesh. Each variant provides a
/// matched dark and light [AppColors] palette so the active brightness can
/// flip independently of the user's chosen variant.
enum ThemeVariant {
  codexAmber,
  nord,
  dracula,
  catppuccin,
  rosePine,
  tokyoNight;

  /// Stable identifier used for preferences persistence. Must not change once
  /// shipped — adding new variants is fine, renaming old ones breaks existing
  /// installs.
  String get id => switch (this) {
        ThemeVariant.codexAmber => 'codex_amber',
        ThemeVariant.nord => 'nord',
        ThemeVariant.dracula => 'dracula',
        ThemeVariant.catppuccin => 'catppuccin',
        ThemeVariant.rosePine => 'rose_pine',
        ThemeVariant.tokyoNight => 'tokyo_night',
      };

  /// Human-readable label shown in the Appearance picker.
  String get label => switch (this) {
        ThemeVariant.codexAmber => 'Codex Amber',
        ThemeVariant.nord => 'Nord',
        ThemeVariant.dracula => 'Dracula',
        ThemeVariant.catppuccin => 'Catppuccin',
        ThemeVariant.rosePine => 'Rosé Pine',
        ThemeVariant.tokyoNight => 'Tokyo Night',
      };

  /// One-line vibe blurb shown below the label in the picker.
  String get tagline => switch (this) {
        ThemeVariant.codexAmber => 'Warm terminal, CRT-inspired',
        ThemeVariant.nord => 'Cool arctic, desaturated',
        ThemeVariant.dracula => 'Neon gothic, high contrast',
        ThemeVariant.catppuccin => 'Soothing pastel, community favorite',
        ThemeVariant.rosePine => 'Muted warm, tasteful',
        ThemeVariant.tokyoNight => 'Cool blue, editor classic',
      };

  AppColors get dark => switch (this) {
        ThemeVariant.codexAmber => _codexAmberDark,
        ThemeVariant.nord => _nordDark,
        ThemeVariant.dracula => _draculaDark,
        ThemeVariant.catppuccin => _catppuccinMocha,
        ThemeVariant.rosePine => _rosePineDark,
        ThemeVariant.tokyoNight => _tokyoNightDark,
      };

  AppColors get light => switch (this) {
        ThemeVariant.codexAmber => _codexAmberLight,
        ThemeVariant.nord => _nordLight,
        ThemeVariant.dracula => _draculaLight,
        ThemeVariant.catppuccin => _catppuccinLatte,
        ThemeVariant.rosePine => _rosePineDawn,
        ThemeVariant.tokyoNight => _tokyoDay,
      };

  static ThemeVariant fromId(String? id, {ThemeVariant fallback = ThemeVariant.codexAmber}) {
    for (final variant in ThemeVariant.values) {
      if (variant.id == id) return variant;
    }
    return fallback;
  }
}

// ---------------------------------------------------------------------------
// Codex Amber — ships as the default; identical to what pre-palette builds had.
// ---------------------------------------------------------------------------

const _codexAmberDark = AppColors(
  canvas: Color(0xFF0B0F14),
  surface: Color(0xFF12171F),
  surfaceElevated: Color(0xFF171D27),
  surfaceMuted: Color(0xFF1D242F),
  border: Color(0xFF232B37),
  borderStrong: Color(0xFF30394A),
  textPrimary: Color(0xFFE6EDF3),
  textSecondary: Color(0xFF9AA7B4),
  textTertiary: Color(0xFF6E7A87),
  accent: Color(0xFFE78A3C),
  accentMuted: Color(0xFF3A2818),
  accentOn: Color(0xFF0B0F14),
  success: Color(0xFF3FB950),
  successMuted: Color(0xFF133A20),
  danger: Color(0xFFF85149),
  dangerMuted: Color(0xFF3B1418),
  warning: Color(0xFFD29922),
  warningMuted: Color(0xFF3A2E10),
  info: Color(0xFF58A6FF),
  infoMuted: Color(0xFF102A4A),
  codeBackground: Color(0xFF0E131A),
  codeBorder: Color(0xFF232B37),
  codeForeground: Color(0xFFD6DEE6),
  diffAddLine: Color(0xFF0F2A1A),
  diffAddGutter: Color(0xFF123A22),
  diffAddGlyph: Color(0xFF3FB950),
  diffDelLine: Color(0xFF2C0F11),
  diffDelGutter: Color(0xFF3B1418),
  diffDelGlyph: Color(0xFFF85149),
  diffMetaLine: Color(0xFF9AA7B4),
  diffHunkLine: Color(0xFF58A6FF),
  diffGutterText: Color(0xFF6E7A87),
  userBubble: Color(0xFFE78A3C),
  userBubbleOn: Color(0xFF0B0F14),
  assistantBubble: Color(0xFF12171F),
  assistantBubbleBorder: Color(0xFF232B37),
  composerBackground: Color(0xFF12171F),
);

const _codexAmberLight = AppColors(
  canvas: Color(0xFFF6EFE2),
  surface: Color(0xFFFFFBF3),
  surfaceElevated: Color(0xFFFFFFFF),
  surfaceMuted: Color(0xFFF1E7D3),
  border: Color(0xFFE6D9BF),
  borderStrong: Color(0xFFD1BF9E),
  textPrimary: Color(0xFF1C1812),
  textSecondary: Color(0xFF6D5B49),
  textTertiary: Color(0xFF9A8A75),
  accent: Color(0xFFCA6B1F),
  accentMuted: Color(0xFFF4DCC0),
  accentOn: Color(0xFFFFFBF3),
  success: Color(0xFF1A7F37),
  successMuted: Color(0xFFDCF3E0),
  danger: Color(0xFFCF222E),
  dangerMuted: Color(0xFFFBD6D3),
  warning: Color(0xFF9A6700),
  warningMuted: Color(0xFFFBEAC0),
  info: Color(0xFF0969DA),
  infoMuted: Color(0xFFDDEAFA),
  codeBackground: Color(0xFFF6EEDD),
  codeBorder: Color(0xFFE6D9BF),
  codeForeground: Color(0xFF1C1812),
  diffAddLine: Color(0xFFDAFBE1),
  diffAddGutter: Color(0xFFACEEBB),
  diffAddGlyph: Color(0xFF1A7F37),
  diffDelLine: Color(0xFFFFEBE9),
  diffDelGutter: Color(0xFFFFCECB),
  diffDelGlyph: Color(0xFFCF222E),
  diffMetaLine: Color(0xFF6D5B49),
  diffHunkLine: Color(0xFF0969DA),
  diffGutterText: Color(0xFF1F2328),
  userBubble: Color(0xFFCA6B1F),
  userBubbleOn: Color(0xFFFFFBF3),
  assistantBubble: Color(0xFFFBF3E1),
  assistantBubbleBorder: Color(0xFFD9C8A8),
  composerBackground: Color(0xFFFFFBF3),
);

// ---------------------------------------------------------------------------
// Nord — https://www.nordtheme.com/docs/colors-and-palettes
// Polar Night / Snow Storm / Frost / Aurora.
// ---------------------------------------------------------------------------

const _nordDark = AppColors(
  canvas: Color(0xFF242933),            // darker than nord0 for contrast
  surface: Color(0xFF2E3440),           // nord0
  surfaceElevated: Color(0xFF3B4252),   // nord1
  surfaceMuted: Color(0xFF353B48),
  border: Color(0xFF434C5E),            // nord2
  borderStrong: Color(0xFF4C566A),      // nord3
  textPrimary: Color(0xFFECEFF4),       // nord6
  textSecondary: Color(0xFFD8DEE9),     // nord4
  textTertiary: Color(0xFF8892A6),
  accent: Color(0xFF88C0D0),            // nord8 (frost)
  accentMuted: Color(0xFF2A3A44),
  accentOn: Color(0xFF1C232D),
  success: Color(0xFFA3BE8C),           // nord14
  successMuted: Color(0xFF2A3528),
  danger: Color(0xFFBF616A),            // nord11
  dangerMuted: Color(0xFF3A2226),
  warning: Color(0xFFEBCB8B),           // nord13
  warningMuted: Color(0xFF3A331E),
  info: Color(0xFF81A1C1),              // nord9
  infoMuted: Color(0xFF233040),
  codeBackground: Color(0xFF292E39),
  codeBorder: Color(0xFF434C5E),
  codeForeground: Color(0xFFE5E9F0),    // nord5
  diffAddLine: Color(0xFF2E3C2C),
  diffAddGutter: Color(0xFF3A4C34),
  diffAddGlyph: Color(0xFFA3BE8C),
  diffDelLine: Color(0xFF3E2A2E),
  diffDelGutter: Color(0xFF4E3238),
  diffDelGlyph: Color(0xFFBF616A),
  diffMetaLine: Color(0xFFD8DEE9),
  diffHunkLine: Color(0xFF81A1C1),
  diffGutterText: Color(0xFF8892A6),
  userBubble: Color(0xFF5E81AC),        // nord10 (frost deep)
  userBubbleOn: Color(0xFFECEFF4),
  assistantBubble: Color(0xFF2E3440),
  assistantBubbleBorder: Color(0xFF434C5E),
  composerBackground: Color(0xFF2E3440),
);

const _nordLight = AppColors(
  canvas: Color(0xFFECEFF4),            // nord6
  surface: Color(0xFFF8F9FB),
  surfaceElevated: Color(0xFFFFFFFF),
  surfaceMuted: Color(0xFFE5E9F0),      // nord5
  border: Color(0xFFD8DEE9),            // nord4
  borderStrong: Color(0xFFB9C1CF),
  textPrimary: Color(0xFF2E3440),       // nord0
  textSecondary: Color(0xFF4C566A),     // nord3
  textTertiary: Color(0xFF7B8594),
  accent: Color(0xFF5E81AC),            // nord10
  accentMuted: Color(0xFFD7E1EE),
  accentOn: Color(0xFFFFFFFF),
  success: Color(0xFF4A7A3F),
  successMuted: Color(0xFFDDEBD3),
  danger: Color(0xFF8B3A43),
  dangerMuted: Color(0xFFF4D6D9),
  warning: Color(0xFF8C6D1C),
  warningMuted: Color(0xFFF5E8C7),
  info: Color(0xFF4C6E8D),
  infoMuted: Color(0xFFD9E3ED),
  codeBackground: Color(0xFFE5E9F0),
  codeBorder: Color(0xFFD8DEE9),
  codeForeground: Color(0xFF2E3440),
  diffAddLine: Color(0xFFE2EED8),
  diffAddGutter: Color(0xFFC9DDB7),
  diffAddGlyph: Color(0xFF4A7A3F),
  diffDelLine: Color(0xFFF4DEE1),
  diffDelGutter: Color(0xFFE8BFC5),
  diffDelGlyph: Color(0xFF8B3A43),
  diffMetaLine: Color(0xFF4C566A),
  diffHunkLine: Color(0xFF5E81AC),
  diffGutterText: Color(0xFF7B8594),
  userBubble: Color(0xFF5E81AC),
  userBubbleOn: Color(0xFFFFFFFF),
  assistantBubble: Color(0xFFF8F9FB),
  assistantBubbleBorder: Color(0xFFD8DEE9),
  composerBackground: Color(0xFFFFFFFF),
);

// ---------------------------------------------------------------------------
// Dracula — https://draculatheme.com/contribute
// Dark: #282A36 bg, #F8F8F2 fg, accents pink/purple/cyan/green.
// Light: Dracula "Alucard" (official light companion).
// ---------------------------------------------------------------------------

const _draculaDark = AppColors(
  canvas: Color(0xFF1E1F29),
  surface: Color(0xFF282A36),
  surfaceElevated: Color(0xFF343746),
  surfaceMuted: Color(0xFF2E303E),
  border: Color(0xFF44475A),
  borderStrong: Color(0xFF6272A4),
  textPrimary: Color(0xFFF8F8F2),
  textSecondary: Color(0xFFBFBFC2),
  textTertiary: Color(0xFF6272A4),
  accent: Color(0xFFBD93F9),            // purple
  accentMuted: Color(0xFF3A2E5C),
  accentOn: Color(0xFF1E1F29),
  success: Color(0xFF50FA7B),
  successMuted: Color(0xFF1F3A2A),
  danger: Color(0xFFFF5555),
  dangerMuted: Color(0xFF3F1E24),
  warning: Color(0xFFF1FA8C),
  warningMuted: Color(0xFF3A3A1E),
  info: Color(0xFF8BE9FD),
  infoMuted: Color(0xFF1E3A40),
  codeBackground: Color(0xFF21222C),
  codeBorder: Color(0xFF44475A),
  codeForeground: Color(0xFFF8F8F2),
  diffAddLine: Color(0xFF1F3A2A),
  diffAddGutter: Color(0xFF2C5239),
  diffAddGlyph: Color(0xFF50FA7B),
  diffDelLine: Color(0xFF3F1E24),
  diffDelGutter: Color(0xFF5A262F),
  diffDelGlyph: Color(0xFFFF5555),
  diffMetaLine: Color(0xFFBFBFC2),
  diffHunkLine: Color(0xFF8BE9FD),
  diffGutterText: Color(0xFF6272A4),
  userBubble: Color(0xFFFF79C6),        // pink
  userBubbleOn: Color(0xFF1E1F29),
  assistantBubble: Color(0xFF282A36),
  assistantBubbleBorder: Color(0xFF44475A),
  composerBackground: Color(0xFF282A36),
);

const _draculaLight = AppColors(
  canvas: Color(0xFFF4F4F8),
  surface: Color(0xFFFFFFFF),
  surfaceElevated: Color(0xFFFFFFFF),
  surfaceMuted: Color(0xFFEDEDF3),
  border: Color(0xFFD9D9E3),
  borderStrong: Color(0xFFBFBFCC),
  textPrimary: Color(0xFF22212C),
  textSecondary: Color(0xFF575360),
  textTertiary: Color(0xFF8A8894),
  accent: Color(0xFF7F4FC7),            // dracula purple, darkened
  accentMuted: Color(0xFFE9DEF8),
  accentOn: Color(0xFFFFFFFF),
  success: Color(0xFF2C8B45),
  successMuted: Color(0xFFDCF0E2),
  danger: Color(0xFFC92C4B),
  dangerMuted: Color(0xFFF8D4DA),
  warning: Color(0xFF8F7A18),
  warningMuted: Color(0xFFF6ECC4),
  info: Color(0xFF1F93AD),
  infoMuted: Color(0xFFD4ECF1),
  codeBackground: Color(0xFFF4F4F8),
  codeBorder: Color(0xFFD9D9E3),
  codeForeground: Color(0xFF22212C),
  diffAddLine: Color(0xFFDCF0E2),
  diffAddGutter: Color(0xFFB6E2C4),
  diffAddGlyph: Color(0xFF2C8B45),
  diffDelLine: Color(0xFFF8D4DA),
  diffDelGutter: Color(0xFFECB3BC),
  diffDelGlyph: Color(0xFFC92C4B),
  diffMetaLine: Color(0xFF575360),
  diffHunkLine: Color(0xFF1F93AD),
  diffGutterText: Color(0xFF8A8894),
  userBubble: Color(0xFFC23B88),        // dracula pink, darkened for light bg
  userBubbleOn: Color(0xFFFFFFFF),
  assistantBubble: Color(0xFFFFFFFF),
  assistantBubbleBorder: Color(0xFFD9D9E3),
  composerBackground: Color(0xFFFFFFFF),
);

// ---------------------------------------------------------------------------
// Catppuccin — https://catppuccin.com/palette
// Mocha (dark) + Latte (light).
// ---------------------------------------------------------------------------

const _catppuccinMocha = AppColors(
  canvas: Color(0xFF181825),            // mantle
  surface: Color(0xFF1E1E2E),           // base
  surfaceElevated: Color(0xFF313244),   // surface0
  surfaceMuted: Color(0xFF45475A),      // surface1
  border: Color(0xFF313244),
  borderStrong: Color(0xFF585B70),      // surface2
  textPrimary: Color(0xFFCDD6F4),       // text
  textSecondary: Color(0xFFA6ADC8),     // subtext0
  textTertiary: Color(0xFF7F849C),      // overlay1
  accent: Color(0xFFCBA6F7),            // mauve
  accentMuted: Color(0xFF3C2E4E),
  accentOn: Color(0xFF1E1E2E),
  success: Color(0xFFA6E3A1),           // green
  successMuted: Color(0xFF243828),
  danger: Color(0xFFF38BA8),            // red
  dangerMuted: Color(0xFF3E212A),
  warning: Color(0xFFF9E2AF),           // yellow
  warningMuted: Color(0xFF3D3620),
  info: Color(0xFF89B4FA),              // blue
  infoMuted: Color(0xFF1F2C47),
  codeBackground: Color(0xFF181825),
  codeBorder: Color(0xFF313244),
  codeForeground: Color(0xFFCDD6F4),
  diffAddLine: Color(0xFF243828),
  diffAddGutter: Color(0xFF335438),
  diffAddGlyph: Color(0xFFA6E3A1),
  diffDelLine: Color(0xFF3E212A),
  diffDelGutter: Color(0xFF5A2F3C),
  diffDelGlyph: Color(0xFFF38BA8),
  diffMetaLine: Color(0xFFA6ADC8),
  diffHunkLine: Color(0xFF89B4FA),
  diffGutterText: Color(0xFF7F849C),
  userBubble: Color(0xFFCBA6F7),        // mauve
  userBubbleOn: Color(0xFF1E1E2E),
  assistantBubble: Color(0xFF1E1E2E),
  assistantBubbleBorder: Color(0xFF313244),
  composerBackground: Color(0xFF1E1E2E),
);

const _catppuccinLatte = AppColors(
  canvas: Color(0xFFE6E9EF),            // mantle
  surface: Color(0xFFEFF1F5),           // base
  surfaceElevated: Color(0xFFFFFFFF),
  surfaceMuted: Color(0xFFDCE0E8),      // crust
  border: Color(0xFFCCD0DA),            // surface0
  borderStrong: Color(0xFFBCC0CC),      // surface1
  textPrimary: Color(0xFF4C4F69),       // text
  textSecondary: Color(0xFF6C6F85),     // subtext0
  textTertiary: Color(0xFF8C8FA1),      // overlay2
  accent: Color(0xFF8839EF),            // mauve
  accentMuted: Color(0xFFE9DBFB),
  accentOn: Color(0xFFFFFFFF),
  success: Color(0xFF40A02B),
  successMuted: Color(0xFFD9ECD0),
  danger: Color(0xFFD20F39),
  dangerMuted: Color(0xFFF6D0D6),
  warning: Color(0xFFDF8E1D),
  warningMuted: Color(0xFFF8E4C2),
  info: Color(0xFF1E66F5),
  infoMuted: Color(0xFFD4E0FB),
  codeBackground: Color(0xFFE6E9EF),
  codeBorder: Color(0xFFCCD0DA),
  codeForeground: Color(0xFF4C4F69),
  diffAddLine: Color(0xFFDAEFD0),
  diffAddGutter: Color(0xFFB6DFA4),
  diffAddGlyph: Color(0xFF40A02B),
  diffDelLine: Color(0xFFF6D0D6),
  diffDelGutter: Color(0xFFE9A9B2),
  diffDelGlyph: Color(0xFFD20F39),
  diffMetaLine: Color(0xFF6C6F85),
  diffHunkLine: Color(0xFF1E66F5),
  diffGutterText: Color(0xFF8C8FA1),
  userBubble: Color(0xFF8839EF),
  userBubbleOn: Color(0xFFFFFFFF),
  assistantBubble: Color(0xFFFFFFFF),
  assistantBubbleBorder: Color(0xFFCCD0DA),
  composerBackground: Color(0xFFFFFFFF),
);

// ---------------------------------------------------------------------------
// Rosé Pine — https://rosepinetheme.com/palette
// Main (dark) + Dawn (light).
// ---------------------------------------------------------------------------

const _rosePineDark = AppColors(
  canvas: Color(0xFF191724),            // base
  surface: Color(0xFF1F1D2E),           // surface
  surfaceElevated: Color(0xFF26233A),   // overlay
  surfaceMuted: Color(0xFF2A273F),
  border: Color(0xFF393552),
  borderStrong: Color(0xFF524F67),      // highlight-high
  textPrimary: Color(0xFFE0DEF4),       // text
  textSecondary: Color(0xFFA9A4BA),
  textTertiary: Color(0xFF6E6A86),      // muted
  accent: Color(0xFFEBBCBA),            // rose
  accentMuted: Color(0xFF3C2B30),
  accentOn: Color(0xFF191724),
  success: Color(0xFF31748F),           // pine (used as "info"-ish in rp; repurposed)
  successMuted: Color(0xFF1B2F3A),
  danger: Color(0xFFEB6F92),            // love
  dangerMuted: Color(0xFF3A1D2A),
  warning: Color(0xFFF6C177),           // gold
  warningMuted: Color(0xFF3A2E1C),
  info: Color(0xFF9CCFD8),              // foam
  infoMuted: Color(0xFF1C3036),
  codeBackground: Color(0xFF1F1D2E),
  codeBorder: Color(0xFF393552),
  codeForeground: Color(0xFFE0DEF4),
  diffAddLine: Color(0xFF1B3528),
  diffAddGutter: Color(0xFF2A4F3A),
  diffAddGlyph: Color(0xFF56B290),
  diffDelLine: Color(0xFF3A1D2A),
  diffDelGutter: Color(0xFF522A3B),
  diffDelGlyph: Color(0xFFEB6F92),
  diffMetaLine: Color(0xFFA9A4BA),
  diffHunkLine: Color(0xFF9CCFD8),
  diffGutterText: Color(0xFF6E6A86),
  userBubble: Color(0xFFC4A7E7),        // iris
  userBubbleOn: Color(0xFF191724),
  assistantBubble: Color(0xFF1F1D2E),
  assistantBubbleBorder: Color(0xFF393552),
  composerBackground: Color(0xFF1F1D2E),
);

const _rosePineDawn = AppColors(
  canvas: Color(0xFFFAF4ED),            // base
  surface: Color(0xFFFFFAF3),           // surface
  surfaceElevated: Color(0xFFFFFFFF),
  surfaceMuted: Color(0xFFF2E9E1),      // overlay
  border: Color(0xFFDFDAD9),            // highlight-med-ish
  borderStrong: Color(0xFFCECACD),
  textPrimary: Color(0xFF575279),       // text
  textSecondary: Color(0xFF797593),     // subtle
  textTertiary: Color(0xFF9893A5),      // muted
  accent: Color(0xFFD7827E),            // rose
  accentMuted: Color(0xFFF4DDDB),
  accentOn: Color(0xFFFFFFFF),
  success: Color(0xFF286983),           // pine
  successMuted: Color(0xFFD2E0E9),
  danger: Color(0xFFB4637A),            // love
  dangerMuted: Color(0xFFF0D2DA),
  warning: Color(0xFFEA9D34),           // gold
  warningMuted: Color(0xFFFBE6C7),
  info: Color(0xFF56949F),              // foam
  infoMuted: Color(0xFFD2E4E8),
  codeBackground: Color(0xFFF2E9E1),
  codeBorder: Color(0xFFDFDAD9),
  codeForeground: Color(0xFF575279),
  diffAddLine: Color(0xFFDCEAD9),
  diffAddGutter: Color(0xFFB6D2B0),
  diffAddGlyph: Color(0xFF3F7A4E),
  diffDelLine: Color(0xFFF0D2DA),
  diffDelGutter: Color(0xFFDDABB9),
  diffDelGlyph: Color(0xFFB4637A),
  diffMetaLine: Color(0xFF797593),
  diffHunkLine: Color(0xFF56949F),
  diffGutterText: Color(0xFF9893A5),
  userBubble: Color(0xFF907AA9),        // iris
  userBubbleOn: Color(0xFFFFFFFF),
  assistantBubble: Color(0xFFFFFAF3),
  assistantBubbleBorder: Color(0xFFDFDAD9),
  composerBackground: Color(0xFFFFFAF3),
);

// ---------------------------------------------------------------------------
// Tokyo Night — https://github.com/enkia/tokyo-night-vscode-theme
// Night (dark) + Day (light).
// ---------------------------------------------------------------------------

const _tokyoNightDark = AppColors(
  canvas: Color(0xFF16161E),
  surface: Color(0xFF1A1B26),
  surfaceElevated: Color(0xFF24283B),
  surfaceMuted: Color(0xFF1F2335),
  border: Color(0xFF2F334D),
  borderStrong: Color(0xFF414868),
  textPrimary: Color(0xFFC0CAF5),
  textSecondary: Color(0xFF9AA5CE),
  textTertiary: Color(0xFF565F89),
  accent: Color(0xFF7AA2F7),            // blue
  accentMuted: Color(0xFF1F2C4D),
  accentOn: Color(0xFF1A1B26),
  success: Color(0xFF9ECE6A),
  successMuted: Color(0xFF233322),
  danger: Color(0xFFF7768E),
  dangerMuted: Color(0xFF3A1E29),
  warning: Color(0xFFE0AF68),
  warningMuted: Color(0xFF3A2E1E),
  info: Color(0xFF7DCFFF),
  infoMuted: Color(0xFF1C3545),
  codeBackground: Color(0xFF16161E),
  codeBorder: Color(0xFF2F334D),
  codeForeground: Color(0xFFC0CAF5),
  diffAddLine: Color(0xFF1F2E23),
  diffAddGutter: Color(0xFF2E4630),
  diffAddGlyph: Color(0xFF9ECE6A),
  diffDelLine: Color(0xFF3A1E29),
  diffDelGutter: Color(0xFF522A3A),
  diffDelGlyph: Color(0xFFF7768E),
  diffMetaLine: Color(0xFF9AA5CE),
  diffHunkLine: Color(0xFF7DCFFF),
  diffGutterText: Color(0xFF565F89),
  userBubble: Color(0xFF7AA2F7),
  userBubbleOn: Color(0xFF16161E),
  assistantBubble: Color(0xFF1A1B26),
  assistantBubbleBorder: Color(0xFF2F334D),
  composerBackground: Color(0xFF1A1B26),
);

const _tokyoDay = AppColors(
  canvas: Color(0xFFE1E2E7),
  surface: Color(0xFFE9E9EE),
  surfaceElevated: Color(0xFFFFFFFF),
  surfaceMuted: Color(0xFFD6D8E0),
  border: Color(0xFFC1C5D4),
  borderStrong: Color(0xFFA8AEC0),
  textPrimary: Color(0xFF3760BF),       // tokyo-day uses blue primary for text-ish
  textSecondary: Color(0xFF6172B0),
  textTertiary: Color(0xFF8990B3),
  accent: Color(0xFF2E7DE9),            // blue
  accentMuted: Color(0xFFD4E1FA),
  accentOn: Color(0xFFFFFFFF),
  success: Color(0xFF587539),
  successMuted: Color(0xFFDBE6CB),
  danger: Color(0xFFF52A65),
  dangerMuted: Color(0xFFFBD2DD),
  warning: Color(0xFF8C6C3E),
  warningMuted: Color(0xFFF2E2C8),
  info: Color(0xFF007197),
  infoMuted: Color(0xFFCCE3EC),
  codeBackground: Color(0xFFD6D8E0),
  codeBorder: Color(0xFFC1C5D4),
  codeForeground: Color(0xFF3760BF),
  diffAddLine: Color(0xFFDBE6CB),
  diffAddGutter: Color(0xFFBAD29F),
  diffAddGlyph: Color(0xFF587539),
  diffDelLine: Color(0xFFFBD2DD),
  diffDelGutter: Color(0xFFEFA9BC),
  diffDelGlyph: Color(0xFFF52A65),
  diffMetaLine: Color(0xFF6172B0),
  diffHunkLine: Color(0xFF2E7DE9),
  diffGutterText: Color(0xFF8990B3),
  userBubble: Color(0xFF2E7DE9),
  userBubbleOn: Color(0xFFFFFFFF),
  assistantBubble: Color(0xFFE9E9EE),
  assistantBubbleBorder: Color(0xFFC1C5D4),
  composerBackground: Color(0xFFE9E9EE),
);
