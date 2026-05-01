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

          return GestureDetector(
            onTap: () => controller.setVariant(variant),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: cardWidth,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isSelected ? palette.accent : palette.border,
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: palette.accent.withValues(alpha: 0.15),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _ColorDot(color: palette.accent),
                      const SizedBox(width: 6),
                      _ColorDot(color: palette.success),
                      const SizedBox(width: 6),
                      _ColorDot(color: palette.danger),
                      const SizedBox(width: 6),
                      _ColorDot(color: palette.info),
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
          );
        },
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
    );
  }
}
