import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_palettes.dart';
import '../theme/theme_controller.dart';
import 'mesh_widgets.dart';

/// Opens the Appearance sheet — a single surface holding brightness +
/// theme-variant controls. Used by both the mobile top-bar button and the
/// desktop sidebar footer.
Future<void> showAppearanceSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _AppearanceSheet(),
  );
}

class _AppearanceSheet extends StatelessWidget {
  const _AppearanceSheet();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final controller = ThemeScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final crossAxisCount = width >= 640 ? 3 : 2;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border(top: BorderSide(color: colors.border)),
            ),
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.85,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _grabHandle(colors),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            Icons.palette_rounded,
                            size: 20,
                            color: colors.accent,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Appearance',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          MeshIconButton(
                            icon: Icons.close_rounded,
                            tooltip: 'Close',
                            onTap: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _SectionLabel(text: 'Brightness'),
                      const SizedBox(height: 8),
                      _BrightnessSegmented(controller: controller),
                      const SizedBox(height: 22),
                      _SectionLabel(text: 'Theme'),
                      const SizedBox(height: 10),
                      _SwatchGrid(
                        controller: controller,
                        crossAxisCount: crossAxisCount,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _grabHandle(AppColors colors) => Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: colors.border,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.textTertiary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
    );
  }
}

class _BrightnessSegmented extends StatelessWidget {
  const _BrightnessSegmented({required this.controller});
  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget seg(ThemeMode mode, IconData icon, String label) {
      final selected = controller.mode == mode;
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => controller.setMode(mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? colors.accentMuted : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? colors.accent : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? colors.accent : colors.textSecondary,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style:
                        Theme.of(context).textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: selected
                                  ? colors.accent
                                  : colors.textSecondary,
                            ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          seg(ThemeMode.system, Icons.brightness_auto_rounded, 'System'),
          seg(ThemeMode.light, Icons.light_mode_rounded, 'Light'),
          seg(ThemeMode.dark, Icons.dark_mode_rounded, 'Dark'),
        ],
      ),
    );
  }
}

class _SwatchGrid extends StatelessWidget {
  const _SwatchGrid({
    required this.controller,
    required this.crossAxisCount,
  });

  final ThemeController controller;
  final int crossAxisCount;

  @override
  Widget build(BuildContext context) {
    // Preview the swatch in the active brightness so what-you-see-is-what-you-get.
    final isDark = controller.isDark(context);
    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.35,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: [
        for (final variant in ThemeVariant.values)
          _SwatchCard(
            variant: variant,
            selected: controller.variant == variant,
            isDark: isDark,
            onTap: () => controller.setVariant(variant),
          ),
      ],
    );
  }
}

class _SwatchCard extends StatelessWidget {
  const _SwatchCard({
    required this.variant,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  final ThemeVariant variant;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final frameColors = context.colors;
    final palette = isDark ? variant.dark : variant.light;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? frameColors.accent : frameColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    // Canvas background
                    Container(color: palette.canvas),
                    // Mini bubble / surface strip mimicking an assistant bubble
                    Positioned(
                      left: 10,
                      right: 10,
                      top: 10,
                      bottom: 10,
                      child: Container(
                        decoration: BoxDecoration(
                          color: palette.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: palette.border),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                _dot(palette.accent),
                                const SizedBox(width: 4),
                                _dot(palette.info),
                                const SizedBox(width: 4),
                                _dot(palette.success),
                              ],
                            ),
                            Container(
                              width: 34,
                              height: 5,
                              decoration: BoxDecoration(
                                color: palette.textPrimary.withValues(
                                  alpha: 0.7,
                                ),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                height: 14,
                                width: 40,
                                decoration: BoxDecoration(
                                  color: palette.userBubble,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (selected)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: frameColors.accent,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check_rounded,
                            size: 12,
                            color: frameColors.accentOn,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                color: frameColors.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      variant.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? frameColors.accent
                                : frameColors.textPrimary,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      variant.tagline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: frameColors.textTertiary,
                            fontSize: 11,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
