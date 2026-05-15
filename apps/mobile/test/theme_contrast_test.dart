import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_colors.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/color_contrast.dart';
import 'package:sidemesh_mobile/src/widgets/mesh_widgets.dart';

Iterable<({String label, AppColors colors})> _allPalettes() sync* {
  for (final variant in ThemeVariant.values) {
    yield (label: '${variant.id} dark', colors: variant.dark);
    yield (label: '${variant.id} light', colors: variant.light);
  }
}

void main() {
  test('core palette action and message tokens meet AA contrast', () {
    for (final palette in _allPalettes()) {
      final colors = palette.colors;

      expect(
        contrastRatio(colors.accentOn, colors.accent),
        greaterThanOrEqualTo(minimumReadableTextContrast),
        reason: '${palette.label} accentOn/accent contrast is too low',
      );
      expect(
        contrastRatio(colors.userBubbleOn, colors.userBubble),
        greaterThanOrEqualTo(minimumReadableTextContrast),
        reason: '${palette.label} user bubble contrast is too low',
      );
      expect(
        contrastRatio(colors.userBubble, colors.accent),
        greaterThanOrEqualTo(2.0),
        reason: '${palette.label} user bubble is too close to accent',
      );
      expect(
        contrastRatio(colors.codeForeground, colors.codeBackground),
        greaterThanOrEqualTo(minimumReadableTextContrast),
        reason: '${palette.label} code contrast is too low',
      );
    }
  });

  test('computed action foregrounds meet AA contrast', () {
    for (final palette in _allPalettes()) {
      final colors = palette.colors;

      expect(
        contrastRatio(readableActionForeground(colors, colors.accent), colors.accent),
        greaterThanOrEqualTo(minimumReadableTextContrast),
        reason: '${palette.label} action foreground contrast is too low',
      );
    }
  });

  test('pills and status badges resolve readable foregrounds', () {
    for (final palette in _allPalettes()) {
      final colors = palette.colors;

      for (final tone in MeshPillTone.values) {
        final toneColors = meshPillColors(colors, tone);
        expect(
          contrastRatio(toneColors.foreground, toneColors.background),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${palette.label} $tone pill contrast is too low',
        );
      }

      for (final tone in MeshStatusTone.values) {
        final toneColors = meshStatusBadgeColors(colors, tone);
        expect(
          contrastRatio(toneColors.foreground, toneColors.background),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${palette.label} $tone status contrast is too low',
        );
      }
    }
  });

  test('shared helpers cover app chrome and component states', () {
    for (final palette in _allPalettes()) {
      final colors = palette.colors;
      final composerMuted = Color.alphaBlend(
        colors.surfaceMuted.withValues(alpha: 0.56),
        colors.composerBackground,
      );

      expect(
        contrastRatio(
          visibleUiColorOn(
            colors,
            background: colors.surfaceMuted,
            preferred: colors.textSecondary,
          ),
          colors.surfaceMuted,
        ),
        greaterThanOrEqualTo(minimumUiContrast),
        reason: '${palette.label} quiet composer controls are too low',
      );
      expect(
        contrastRatio(
          visibleUiColorOn(
            colors,
            background: composerMuted,
            preferred: colors.textSecondary,
          ),
          composerMuted,
        ),
        greaterThanOrEqualTo(minimumUiContrast),
        reason: '${palette.label} composer muted button icon is too low',
      );
      expect(
        contrastRatio(
          visibleUiColorOn(
            colors,
            background: colors.accentMuted,
            preferred: colors.accent,
          ),
          colors.accentMuted,
        ),
        greaterThanOrEqualTo(minimumUiContrast),
        reason: '${palette.label} selected composer icon is too low',
      );
      expect(
        contrastRatio(
          readableSemanticForeground(
            colors,
            background: colors.accentMuted,
            preferred: colors.accent,
          ),
          colors.accentMuted,
        ),
        greaterThanOrEqualTo(minimumReadableTextContrast),
        reason: '${palette.label} sheet/dialog icon well is too low',
      );
      expect(
        contrastRatio(
          visibleUiColorOn(
            colors,
            background: colors.success,
            preferred: colors.accentOn,
          ),
          colors.success,
        ),
        greaterThanOrEqualTo(minimumUiContrast),
        reason: '${palette.label} solid semantic action icon is too low',
      );
      expect(
        contrastRatio(
          readableSemanticForeground(
            colors,
            background: colors.dangerMuted,
            preferred: colors.danger,
          ),
          colors.dangerMuted,
        ),
        greaterThanOrEqualTo(minimumReadableTextContrast),
        reason: '${palette.label} muted danger action foreground is too low',
      );
      expect(
        contrastRatio(
          readableLinkOn(colors, background: colors.surface),
          colors.surface,
        ),
        greaterThanOrEqualTo(minimumReadableTextContrast),
        reason: '${palette.label} default markdown link is too low',
      );
      expect(
        contrastRatio(
          visibleBorderOn(
            colors,
            background: colors.surface,
            preferred: colors.border,
          ),
          colors.surface,
        ),
        greaterThanOrEqualTo(minimumUiContrast),
        reason: '${palette.label} control border is too low',
      );
    }
  });

  test('terminal palette resolves readable ANSI colors', () {
    for (final palette in _allPalettes()) {
      final colors = palette.colors;

      for (final preferred in <Color>[
        colors.textTertiary,
        colors.danger,
        colors.success,
        colors.warning,
        colors.accent,
        colors.info,
        colors.textSecondary,
      ]) {
        expect(
          contrastRatio(
            readableTerminalColorOn(colors, preferred: preferred),
            colors.codeBackground,
          ),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${palette.label} terminal color is too low',
        );
      }
    }
  });
}
