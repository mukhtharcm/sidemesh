import 'package:flutter/material.dart';

/// Canonical design tokens for the Sidemesh "Mesh" UI.
///
/// These tokens are the single source of truth for spacing, radii,
/// font weights, and letter-spacing across the app. New screens should
/// reference [AppSpacing] / [AppRadii] / [AppWeights] / [AppLetterSpacing]
/// directly. Screen and widget style literals are checked by the theme audit.
///
/// Rules of thumb:
///   * Use only the three weights in [AppWeights] for UI text.
///   * Use only the named radii in [AppRadii] for UI shapes.
///   * Use only the spacing values in [AppSpacing] for paddings/gaps.
///   * Prefer `*_rounded` Material icons everywhere.
abstract final class AppSpacing {
  static const double hairline = 1;
  static const double xxs = 2;
  static const double xs = 4;
  static const double tight = 6;
  static const double sm = 8;
  static const double compact = 10;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
}

/// Type roles shared by the Material text theme and dense tool surfaces.
abstract final class AppFontSizes {
  static const double micro = 10;
  static const double metadata = 11;
  static const double caption = 12;
  static const double code = 12.5;
  static const double compact = 13;
  static const double body = 14;
  static const double reading = 16;
  static const double picker = 18;
  static const double heading = 20;
  static const double page = 24;
}

abstract final class AppLineHeights {
  static const double solid = 1;
  static const double tight = 1.2;
  static const double title = 1.25;
  static const double label = 1.3;
  static const double caption = 1.35;
  static const double body = 1.4;
  static const double reading = 1.45;
  static const double code = 1.5;
  static const double prose = 1.55;
}

abstract final class AppFonts {
  static const String code = 'JetBrainsMono';
}

abstract final class AppStrokes {
  static const double scanner = 4;
  static const double hairline = 0.5;
  static const double border = 1;
  static const double focus = 1.5;
  static const double indicator = 2;
}

/// Canonical component geometry. Screen code should not invent control,
/// leading-icon, or content-width values when one of these roles applies.
abstract final class AppSizes {
  static const double statusDot = 5;
  static const double paletteSwatchRadius = 7;
  static const double touchFeedbackRadius = 20;
  static const double sessionToolbar = 52;
  static const double desktopChoiceRow = 36;
  static const double choiceRow = 52;
  static const double choiceRowWithDescription = 72;
  static const double mobileGutter = AppSpacing.lg;
  static const double desktopGutter = AppSpacing.xl;
  static const double control = 48;
  static const double menuItem = 44;
  static const double compactControl = 32;
  static const double toastWidth = 360;
  static const double desktopMenuItem = 32;
  static const double menuMinWidth = 210;
  static const double pickerWidth = 340;
  static const double pickerMaxHeight = 360;
  static const double confirmDialogWidth = 440;
  static const double settingsWidth = 780;
  static const double settingsHeight = 580;

  static bool usesPointerControls(TargetPlatform platform) =>
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;
  static const double rowMinHeight = 56;
  static const double icon = 20;
  static const double compactIcon = 16;
  static const double iconWell = 32;
  static const double emptyIconWell = 56;
  static const double contentMaxWidth = 840;
  static const double readingMaxWidth = 680;
  static const double actionMenuWidth = 220;
  static const double floatingActionClearance = 120;
  static const double previewGutter = 72;
  static const double nestedRowIndent = 52;
  static const double smallIcon = 14;
  static const double tinyIcon = 12;
  static const double featureIcon = 28;
  static const double heroIcon = 40;
  static const double inlineIcon = 18;
  static const double largeIcon = 24;
}

abstract final class AppRadii {
  static const double cursor = 1;
  static const double handle = 2;
  static const double capsule = 999;
  static const double floatingSheet = 32;

  /// Badges, compact chips, and tiny action targets.
  static const double badge = 8;

  /// Icon wells and compact square controls.
  static const double iconWell = 9;

  /// Primary square action buttons such as send controls.
  static const double action = 10;

  /// Inputs, small buttons, and nested controls.
  static const double control = 12;

  /// App surfaces, list rows, and primary grouped content.
  static const double surface = 18;

  /// Tool panels, previews, and grouped detail content.
  static const double panel = 12;

  /// Centered modal dialogs and desktop floating panels.
  static const double dialog = 12;

  /// Floating menus and anchored pickers.
  static const double menu = 10;

  /// Hover and selection surfaces inside controls.
  static const double hover = 6;

  /// Bottom sheets and mobile modal surfaces.
  static const double sheet = 24;

  /// Compact legacy chip radius. Prefer [badge] for new UI.
  static const double pill = badge;

  /// Legacy control radius. Prefer [control] for new UI.
  static const double input = control;

  /// Legacy card radius. Prefer [surface] for new UI.
  static const double card = surface;
}

abstract final class AppWeights {
  /// Default body text.
  static const FontWeight body = FontWeight.w400;

  /// Emphasized body / metadata / pill labels.
  static const FontWeight emphasis = FontWeight.w500;

  /// Titles and primary buttons.
  static const FontWeight title = FontWeight.w600;

  /// Reserved for page titles and rare high-emphasis values.
  static const FontWeight strong = FontWeight.w700;
}

abstract final class AppLetterSpacing {
  /// Headlines and large titles.
  static const double headline = 0;

  /// Default body text.
  static const double body = 0;

  /// ALL CAPS labels and pill text.
  static const double caps = 0.2;
}

/// Canonical timing and easing for app-owned state transitions.
abstract final class AppMotion {
  static const Duration quick = Duration(milliseconds: 160);
  static const Duration reveal = Duration(milliseconds: 220);
  static const Curve standard = Curves.easeOutCubic;
  static const Duration page = Duration(milliseconds: 400);
  static const Duration pulse = Duration(milliseconds: 1200);
  static const Duration breathe = Duration(milliseconds: 1500);
  static const Duration feedback = Duration(milliseconds: 1400);
  static const Curve continuous = Curves.easeInOut;
}

/// Shorthand helpers for common shapes — keeps allocation light by reusing
/// the same `BorderRadius` values across rebuilds.
abstract final class AppShapes {
  static final BorderRadius badge = BorderRadius.circular(AppRadii.badge);
  static final BorderRadius pill = BorderRadius.circular(AppRadii.pill);
  static final BorderRadius iconWell = BorderRadius.circular(AppRadii.iconWell);
  static final BorderRadius action = BorderRadius.circular(AppRadii.action);
  static final BorderRadius input = BorderRadius.circular(AppRadii.input);
  static final BorderRadius panel = BorderRadius.circular(AppRadii.panel);
  static final BorderRadius card = BorderRadius.circular(AppRadii.card);
  static final BorderRadius menu = BorderRadius.circular(AppRadii.menu);
  static final BorderRadius hover = BorderRadius.circular(AppRadii.hover);
  static final BorderRadius dialog = BorderRadius.circular(AppRadii.dialog);
  static final BorderRadius sheet = BorderRadius.circular(AppRadii.sheet);

  /// Bottom sheets only round their top corners.
  static final BorderRadius sheetTop = const BorderRadius.vertical(
    top: Radius.circular(AppRadii.sheet),
  );
}

/// Shared elevation recipes for floating app-owned surfaces.
abstract final class AppShadows {
  static BoxShadow surface(Color source) => BoxShadow(
    color: source.withValues(alpha: AppEmphasis.faint),
    blurRadius: 18,
    offset: const Offset(0, AppSpacing.sm),
  );
  static List<BoxShadow> dialog(Color source) => [
    BoxShadow(
      color: source.withValues(alpha: 0.12),
      blurRadius: 28,
      offset: const Offset(0, 16),
    ),
  ];

  static List<BoxShadow> sheet(Color source) => [
    BoxShadow(
      color: source.withValues(alpha: 0.12),
      blurRadius: 24,
      offset: const Offset(0, 14),
    ),
  ];
}

/// Common edge insets built from [AppSpacing] tokens.
abstract final class AppPadding {
  static const EdgeInsets cardSm = EdgeInsets.all(AppSpacing.md);
  static const EdgeInsets card = EdgeInsets.all(AppSpacing.lg);
  static const EdgeInsets cardLg = EdgeInsets.all(AppSpacing.xl);
  static const EdgeInsets pill = EdgeInsets.symmetric(
    horizontal: AppSpacing.md,
    vertical: AppSpacing.xs,
  );
  static const EdgeInsets mobilePage = EdgeInsets.fromLTRB(
    AppSizes.mobileGutter,
    AppSpacing.sm,
    AppSizes.mobileGutter,
    AppSpacing.xxl,
  );
  static const EdgeInsets desktopPage = EdgeInsets.fromLTRB(
    AppSizes.desktopGutter,
    AppSpacing.lg,
    AppSizes.desktopGutter,
    AppSpacing.xxl,
  );
  static const EdgeInsets listRow = EdgeInsets.symmetric(
    horizontal: AppSpacing.md,
    vertical: AppSpacing.md,
  );
}

/// Shared interaction emphasis and elevation.
abstract final class AppEmphasis {
  static const double hover = 0.04;
  static const double focus = 0.08;
  static const double popupShadow = 0.12;
  static const double popupElevation = 6;
  static const double faint = 0.06;
  static const double tint = 0.12;
  static const double soft = 0.18;
  static const double borderTint = 0.28;
  static const double muted = 0.4;
  static const double disabled = 0.48;
  static const double medium = 0.62;
  static const double secondary = 0.72;
  static const double strong = 0.86;
  static const double full = 1;
}

/// Fields inside a surface that already owns the border and focus state.
/// Clear every state: InputDecoration.border alone does not override the theme.
abstract final class AppInputDecorations {
  static const borderless = InputDecoration(
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    filled: false,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    isDense: true,
    contentPadding: EdgeInsets.zero,
    constraints: BoxConstraints(),
  );
}
