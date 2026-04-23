import 'package:flutter/material.dart';

/// Shows a floating snackbar that caps its width on wide windows (desktop)
/// and stays edge-to-edge-ish on phones. The global SnackBarTheme already
/// sets `behavior: floating`, background, shape and text style — this
/// helper layers on responsive margin so snackbars don't stretch across
/// the entire macOS window.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  Duration duration = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return null;
  final width = MediaQuery.of(context).size.width;
  // Target ~440px content width on desktop; on tight mobile screens we fall
  // back to a thin horizontal gutter.
  final margin = width > 520
      ? EdgeInsets.only(
          left: (width - 440).clamp(16, width).toDouble() / 2,
          right: (width - 440).clamp(16, width).toDouble() / 2,
          bottom: 16,
        )
      : const EdgeInsets.fromLTRB(12, 0, 12, 12);
  return messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      margin: margin,
      action: action,
      duration: duration,
    ),
  );
}
