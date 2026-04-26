import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_palettes.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'mesh_widgets.dart';

/// Opens the Appearance sheet — a single surface holding brightness,
/// palette, and typography controls. Used by both the mobile top-bar button
/// and the desktop sidebar footer.
Future<void> showAppearanceSheet(BuildContext context) {
  final desktop = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  if (desktop) {
    final colors = context.colors;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 760),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colors.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 36,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: const _AppearanceSheet(embedded: true),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _AppearanceSheet(),
  );
}

class _AppearanceSheet extends StatelessWidget {
  const _AppearanceSheet({this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final controller = ThemeScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compactThemeGrid = embedded || width < 560;
    final crossAxisCount = compactThemeGrid
        ? width >= 760
              ? 4
              : width >= 360
              ? 3
              : 2
        : width >= 640
        ? 3
        : 2;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: embedded ? 0 : MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: embedded
                  ? BorderRadius.circular(24)
                  : const BorderRadius.vertical(top: Radius.circular(24)),
              border: embedded
                  ? null
                  : Border(top: BorderSide(color: colors.border)),
            ),
            child: SafeArea(
              top: !embedded,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: embedded
                      ? 760
                      : MediaQuery.sizeOf(context).height * 0.85,
                ),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    embedded ? 20 : 10,
                    20,
                    20,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!embedded) ...[
                        _grabHandle(colors),
                        const SizedBox(height: 12),
                      ],
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
                            style: Theme.of(context).textTheme.titleMedium
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
                        compact: compactThemeGrid,
                      ),
                      SizedBox(height: compactThemeGrid ? 16 : 22),
                      _SectionLabel(text: 'Typography'),
                      const SizedBox(height: 10),
                      _TypographyCard(controller: controller),
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
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: selected ? colors.accent : colors.textSecondary,
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
    this.compact = false,
  });

  final ThemeController controller;
  final int crossAxisCount;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // Preview the swatch in the active brightness so what-you-see-is-what-you-get.
    final isDark = controller.isDark(context);
    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: compact
          ? (crossAxisCount >= 4
                ? 1.55
                : crossAxisCount == 3
                ? 1.38
                : 1.26)
          : (crossAxisCount == 3 ? 1.15 : 1.05),
      mainAxisSpacing: compact ? 10 : 12,
      crossAxisSpacing: compact ? 10 : 12,
      children: [
        for (final variant in ThemeVariant.values)
          _SwatchCard(
            variant: variant,
            selected: controller.variant == variant,
            isDark: isDark,
            compact: compact,
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
    this.compact = false,
    required this.onTap,
  });

  final ThemeVariant variant;
  final bool selected;
  final bool isDark;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final frameColors = context.colors;
    final palette = isDark ? variant.dark : variant.light;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(compact ? 12 : 14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: frameColors.surface,
            borderRadius: BorderRadius.circular(compact ? 12 : 14),
            border: Border.all(
              color: selected ? frameColors.accent : frameColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              compact
                  ? (selected ? 10 : 11)
                  : (selected ? 12 : 13),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (compact)
                  SizedBox(
                    height: 40,
                    child: Stack(
                      children: [
                        Container(color: palette.canvas),
                        Positioned(
                          left: 8,
                          right: 8,
                          top: 6,
                          bottom: 6,
                          child: Container(
                            decoration: BoxDecoration(
                              color: palette.surface,
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(color: palette.border),
                            ),
                            padding: const EdgeInsets.all(5),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    _dot(palette.accent, compact: true),
                                    const SizedBox(width: 3),
                                    _dot(palette.info, compact: true),
                                    const SizedBox(width: 3),
                                    _dot(palette.success, compact: true),
                                  ],
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Container(
                                    height: 7,
                                    width: 24,
                                    decoration: BoxDecoration(
                                      color: palette.userBubble,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (selected)
                          Positioned(
                            right: 4,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(
                                color: frameColors.accent,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.check_rounded,
                                size: 10,
                                color: frameColors.accentOn,
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                else
                  Expanded(
                  child: Stack(
                    children: [
                      // Canvas background
                      Container(color: palette.canvas),
                      // Mini bubble / surface strip mimicking an assistant bubble
                      Positioned(
                        left: compact ? 8 : 10,
                        right: compact ? 8 : 10,
                        top: compact ? 8 : 10,
                        bottom: compact ? 8 : 10,
                        child: Container(
                          decoration: BoxDecoration(
                            color: palette.surface,
                            borderRadius: BorderRadius.circular(compact ? 7 : 8),
                            border: Border.all(color: palette.border),
                          ),
                          padding: EdgeInsets.all(compact ? 7 : 8),
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
                                width: compact ? 28 : 34,
                                height: compact ? 4 : 5,
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
                                  height: compact ? 12 : 14,
                                  width: compact ? 32 : 40,
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
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 9 : 10,
                    compact ? 7 : 8,
                    compact ? 9 : 10,
                    compact ? 8 : 10,
                  ),
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
                          fontSize: compact ? 11.8 : null,
                          color: selected
                              ? frameColors.accent
                              : frameColors.textPrimary,
                        ),
                      ),
                      if (!compact) ...[
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
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dot(Color color, {bool compact = false}) => Container(
    width: compact ? 4 : 6,
    height: compact ? 4 : 6,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _TypographyCard extends StatelessWidget {
  const _TypographyCard({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typography = controller.typography;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Typography',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Tune the interface voice and reading density without changing session content.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          _TypographyPreview(controller: controller),
          const SizedBox(height: 14),
          _PreferenceLabel(text: 'Interface font'),
          const SizedBox(height: 8),
          for (final family in InterfaceFontFamily.values)
            Padding(
              padding: EdgeInsets.only(
                bottom: family == InterfaceFontFamily.values.last ? 0 : 8,
              ),
              child: _ChoiceCard(
                selected: typography.interfaceFont == family,
                title: family.label,
                subtitle: family.description,
                onTap: () => controller.setInterfaceFont(family),
              ),
            ),
          const SizedBox(height: 16),
          _PreferenceLabel(text: 'Interface size'),
          const SizedBox(height: 8),
          _SegmentedChoiceRow<TextSizePreset>(
            groupValue: typography.interfaceScale,
            options: TextSizePreset.values,
            labelFor: (preset) => preset.label,
            onSelected: controller.setInterfaceScale,
          ),
          const SizedBox(height: 6),
          Text(
            typography.interfaceScale.description,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => controller.resetTypography(),
              child: const Text('Reset typography'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypographyPreview extends StatelessWidget {
  const _TypographyPreview({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typography = controller.typography;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent sessions stay readable at a glance.',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Approval prompts, transcripts, and host controls all pick up these preferences immediately.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 10),
          Text(
            '~/workspace/sidemesh/apps/mobile',
            style: monoStyle(color: colors.accent, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: typography.interfaceFont.label,
                icon: Icons.font_download_outlined,
              ),
              MeshPill(
                label: 'UI ${typography.interfaceScale.label.toLowerCase()}',
                icon: Icons.format_size_rounded,
                tone: MeshPillTone.neutral,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreferenceLabel extends StatelessWidget {
  const _PreferenceLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted : colors.surfaceMuted,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? colors.accent : colors.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? colors.accent : colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 18,
                color: selected ? colors.accent : colors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentedChoiceRow<T> extends StatelessWidget {
  const _SegmentedChoiceRow({
    required this.groupValue,
    required this.options,
    required this.labelFor,
    required this.onSelected,
  });

  final T groupValue;
  final List<T> options;
  final String Function(T) labelFor;
  final Future<void> Function(T) onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: _SegmentedChoiceButton<T>(
                value: options[i],
                groupValue: groupValue,
                label: labelFor(options[i]),
                onSelected: onSelected,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SegmentedChoiceButton<T> extends StatelessWidget {
  const _SegmentedChoiceButton({
    required this.value,
    required this.groupValue,
    required this.label,
    required this.onSelected,
  });

  final T value;
  final T groupValue;
  final String label;
  final Future<void> Function(T) onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = value == groupValue;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onSelected(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? colors.accent : Colors.transparent,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: selected ? colors.accent : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
