import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../theme/app_palettes.dart';
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
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 760),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceElevated,
              borderRadius: AppShapes.dialog,
              border: Border.all(color: colors.border),
              boxShadow: AppShadows.dialog(colors.textPrimary),
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
                  ? AppShapes.dialog
                  : AppShapes.sheetTop,
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
                  padding: EdgeInsets.fromLTRB(20, embedded ? 20 : 10, 20, 20),
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
                            Icons.tune_rounded,
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
                      const SizedBox(height: 6),
                      Text(
                        'Choose the color mode, accent, and text settings that feel easiest to use.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      _AppearanceSummaryCard(controller: controller),
                      const SizedBox(height: 18),
                      const _SectionLabel(
                        text: 'Color mode',
                        subtitle: 'Pick how bright the app should be.',
                      ),
                      const SizedBox(height: 8),
                      _BrightnessSegmented(controller: controller),
                      const SizedBox(height: 22),
                      const _SectionLabel(
                        text: 'Accent',
                        subtitle:
                            'Choose the palette used for highlights and status accents.',
                      ),
                      const SizedBox(height: 10),
                      _SwatchGrid(
                        controller: controller,
                        crossAxisCount: crossAxisCount,
                        compact: compactThemeGrid,
                      ),
                      SizedBox(height: compactThemeGrid ? 16 : 22),
                      const _SectionLabel(
                        text: 'Text',
                        subtitle:
                            'Adjust the app font and reading size without changing session content.',
                      ),
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
  const _SectionLabel({required this.text, this.subtitle});
  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.textSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}

class _AppearanceSummaryCard extends StatelessWidget {
  const _AppearanceSummaryCard({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Changes the app look only.',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Session content, code, and terminal output stay the same.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.colors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              MeshPill(
                label: _themeModeLabel(controller.mode),
                icon: Icons.brightness_6_rounded,
              ),
              MeshPill(
                label: controller.variant.label,
                icon: Icons.palette_outlined,
              ),
              MeshPill(
                label: controller.typography.interfaceScale.label,
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

String _themeModeLabel(ThemeMode mode) {
  return switch (mode) {
    ThemeMode.system => 'System mode',
    ThemeMode.light => 'Light mode',
    ThemeMode.dark => 'Dark mode',
  };
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
            borderRadius: AppShapes.action,
            onTap: () => controller.setMode(mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? colors.accentMuted : Colors.transparent,
                borderRadius: AppShapes.action,
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
    final radius = BorderRadius.circular(compact ? 12 : 14);
    final previewHeight = compact ? 32.0 : 74.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: frameColors.surface,
            borderRadius: radius,
            border: Border.all(
              color: selected ? frameColors.accent : frameColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(compact ? 10 : 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: previewHeight,
                  child: Stack(
                    children: [
                      Container(color: palette.canvas),
                      Positioned(
                        left: compact ? 8 : 10,
                        right: compact ? 8 : 10,
                        top: compact ? 6 : 10,
                        child: Container(
                          height: compact ? 14 : 28,
                          decoration: BoxDecoration(
                            color: palette.surface,
                            borderRadius: BorderRadius.circular(
                              compact ? 8 : 10,
                            ),
                            border: Border.all(color: palette.border),
                          ),
                        ),
                      ),
                      Positioned(
                        left: compact ? 8 : 10,
                        bottom: compact ? 6 : 14,
                        child: Container(
                          width: compact ? 28 : 42,
                          height: compact ? 6 : 10,
                          decoration: BoxDecoration(
                            color: palette.accent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      Positioned(
                        right: compact ? 8 : 10,
                        bottom: compact ? 6 : 14,
                        child: Container(
                          width: compact ? 18 : 24,
                          height: compact ? 6 : 10,
                          decoration: BoxDecoration(
                            color: palette.surfaceElevated,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: palette.border),
                          ),
                        ),
                      ),
                      if (selected)
                        Positioned(
                          right: compact ? 6 : 8,
                          top: compact ? 5 : 8,
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: compact ? 14 : 18,
                            color: frameColors.accent,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 8 : 10,
                    compact ? 5 : 8,
                    compact ? 8 : 10,
                    compact ? 6 : 10,
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
                          maxLines: 2,
                          overflow: TextOverflow.fade,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
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
        borderRadius: AppShapes.dialog,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Readability',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Choose the app font and reading size without changing session content.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          _TypographyPreview(controller: controller),
          const SizedBox(height: 14),
          _PreferenceLabel(text: 'App font'),
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
          _PreferenceLabel(text: 'Text size'),
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
            'Recent sessions are easy to scan.',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Titles, timestamps, and approval messages update right away.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Review failing notification tests',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Studio Mac · Waiting for approval · 2 min ago',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: typography.interfaceFont.label,
                icon: Icons.font_download_rounded,
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
        borderRadius: AppShapes.action,
        onTap: () => onSelected(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted : Colors.transparent,
            borderRadius: AppShapes.action,
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
