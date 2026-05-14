import 'package:flutter/material.dart';

import '../theme/app_palettes.dart';
import '../theme/theme_controller.dart';

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
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: isSelected ? palette.accent : palette.border,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Container(color: palette.canvas),
                            Positioned(
                              left: 12,
                              right: 12,
                              top: 12,
                              child: Container(
                                height: 42,
                                decoration: BoxDecoration(
                                  color: palette.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: palette.border),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 12,
                              bottom: 14,
                              child: Container(
                                width: 46,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: palette.accent,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 12,
                              bottom: 14,
                              child: Container(
                                width: 24,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: palette.surfaceElevated,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: palette.border),
                                ),
                              ),
                            ),
                            if (isSelected)
                              Positioned(
                                right: 10,
                                top: 10,
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  size: 18,
                                  color: palette.accent,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              variant.label,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: palette.textPrimary,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              variant.tagline,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: palette.textSecondary,
                                    height: 1.3,
                                  ),
                            ),
                          ],
                        ),
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
