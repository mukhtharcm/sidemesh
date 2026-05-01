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
///   * Use only the four radii in [AppRadii] for UI shapes.
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
  /// Pills and small chips.
  static const double pill = 10;
  /// Inputs, small buttons.
  static const double input = 14;
  /// Cards and primary surfaces.
  static const double card = 18;
  /// Bottom sheets and modal dialogs.
  static const double sheet = 24;
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
  static final BorderRadius pill = BorderRadius.circular(AppRadii.pill);
  static final BorderRadius input = BorderRadius.circular(AppRadii.input);
  static final BorderRadius card = BorderRadius.circular(AppRadii.card);
  static final BorderRadius sheet = BorderRadius.circular(AppRadii.sheet);
  /// Bottom sheets only round their top corners.
  static final BorderRadius sheetTop = const BorderRadius.vertical(
    top: Radius.circular(AppRadii.sheet),
  );
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
