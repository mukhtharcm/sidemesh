import 'package:flutter/material.dart';

/// Canonical design tokens for the Sidemesh "Mesh" UI.
///
/// These tokens are the single source of truth for spacing, radii,
/// font weights, and letter-spacing across the app. New screens should
/// reference [AppSpacing] / [AppRadii] / [AppWeights] / [AppLetterSpacing]
/// directly. Existing screens are being migrated incrementally — see
/// `plan.md` task `typography-icon-pass`.
///
/// Rules of thumb:
///   * Use only the three weights in [AppWeights] for UI text.
///   * Use only the named radii in [AppRadii] for UI shapes.
///   * Use only the spacing values in [AppSpacing] for paddings/gaps.
///   * Prefer `*_rounded` Material icons everywhere.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AppRadii {
  /// Badges, compact chips, and tiny action targets.
  static const double badge = 8;
  /// Icon wells and compact square controls.
  static const double iconWell = 9;
  /// Primary square action buttons such as send controls.
  static const double action = 10;
  /// Inputs, small buttons, and nested controls.
  static const double control = 12;
  /// App surfaces, list rows, and primary grouped content.
  static const double surface = 16;
  /// Centered modal dialogs and desktop floating panels.
  static const double dialog = 18;
  /// Bottom sheets and mobile modal surfaces.
  static const double sheet = 20;

  /// Compact legacy chip radius. Prefer [badge] for new UI.
  static const double pill = badge;
  /// Legacy control radius. Prefer [control] for new UI.
  static const double input = control;
  /// Legacy card radius. Prefer [surface] for new UI.
  static const double card = surface;
}

abstract final class AppWeights {
  /// Default body text.
  static const FontWeight body = FontWeight.w500;
  /// Emphasized body / metadata / pill labels.
  static const FontWeight emphasis = FontWeight.w600;
  /// Titles and primary buttons.
  static const FontWeight title = FontWeight.w800;
}

abstract final class AppLetterSpacing {
  /// Headlines and large titles.
  static const double headline = -0.3;
  /// Default body text.
  static const double body = 0;
  /// ALL CAPS labels and pill text.
  static const double caps = 0.2;
}

/// Shorthand helpers for common shapes — keeps allocation light by reusing
/// the same `BorderRadius` values across rebuilds.
abstract final class AppShapes {
  static final BorderRadius badge = BorderRadius.circular(AppRadii.badge);
  static final BorderRadius pill = BorderRadius.circular(AppRadii.pill);
  static final BorderRadius iconWell = BorderRadius.circular(
    AppRadii.iconWell,
  );
  static final BorderRadius action = BorderRadius.circular(AppRadii.action);
  static final BorderRadius input = BorderRadius.circular(AppRadii.input);
  static final BorderRadius card = BorderRadius.circular(AppRadii.card);
  static final BorderRadius dialog = BorderRadius.circular(AppRadii.dialog);
  static final BorderRadius sheet = BorderRadius.circular(AppRadii.sheet);
  /// Bottom sheets only round their top corners.
  static final BorderRadius sheetTop = const BorderRadius.vertical(
    top: Radius.circular(AppRadii.sheet),
  );
}

/// Shared elevation recipes for floating app-owned surfaces.
abstract final class AppShadows {
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
}
