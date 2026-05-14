import 'package:flutter/material.dart';

import '../theme/app_palettes.dart';
import '../theme/theme_controller.dart';
import 'mesh_widgets.dart';

/// A horizontal scrollable theme-variant picker that previews each palette
/// live and lets the user tap to select.
class ThemePicker extends StatelessWidget {
  const ThemePicker({
    super.key,
    required this.controller,
    this.height = 280,
    this.cardWidth = 160,
  });

  final ThemeController controller;
  final double height;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: ThemeVariant.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final variant = ThemeVariant.values[index];
          final isSelected = controller.variant == variant;
          final palette = Theme.of(context).brightness == Brightness.dark
              ? variant.dark
              : variant.light;
          final borderRadius = BorderRadius.circular(18);

          return Semantics(
            button: true,
            selected: isSelected,
            label: variant.label,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: borderRadius,
                onTap: () => controller.setVariant(variant),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: cardWidth,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: isSelected ? palette.accent : palette.border,
                      width: isSelected ? 2 : 1,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: palette.accent.withValues(alpha: 0.12),
                              blurRadius: 14,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _ColorDot(color: palette.accent, border: palette.border),
                          const SizedBox(width: 6),
                          _ColorDot(color: palette.success, border: palette.border),
                          const SizedBox(width: 6),
                          _ColorDot(color: palette.danger, border: palette.border),
                          const SizedBox(width: 6),
                          _ColorDot(color: palette.info, border: palette.border),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        variant.label,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        variant.tagline,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textSecondary,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (isSelected)
                        MeshPill(
                          label: 'Selected',
                          tone: MeshPillTone.accent,
                          icon: Icons.check_rounded,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.border});

  final Color color;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: border.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
    );
  }
}
