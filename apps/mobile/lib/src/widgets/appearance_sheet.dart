import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../theme/app_palettes.dart';
import '../theme/theme_controller.dart';
import 'app_primitives.dart';
import 'app_menu.dart';

/// Appearance uses page navigation so it never stacks a dialog on Settings.
Future<void> showAppearanceSheet(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const AppearanceSettings()));

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final controller = ThemeScope.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final colors = context.colors;
        final typography = controller.typography;
        final content = AppContentColumn(
          maxWidth: 680,
          child: ListView(
            padding: AppPadding.mobilePage,
            children: [
              const Text('Color mode'),
              const SizedBox(height: AppSpacing.md),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {controller.mode},
                onSelectionChanged: (selection) =>
                    controller.setMode(selection.single),
              ),
              const SizedBox(height: AppSpacing.xl),
              const Text('Palette'),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final variant in ThemeVariant.values)
                    ChoiceChip(
                      avatar: CircleAvatar(
                        radius: AppSizes.paletteSwatchRadius,
                        backgroundColor: controller.isDark(context)
                            ? variant.dark.accent
                            : variant.light.accent,
                      ),
                      label: Text(variant.label),
                      selected: controller.variant == variant,
                      onSelected: (_) => controller.setVariant(variant),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              AppSettingsRow(
                icon: Icons.text_fields_rounded,
                title: 'App font',
                trailing: AppSelect<InterfaceFontFamily>(
                  value: typography.interfaceFont,
                  values: InterfaceFontFamily.values,
                  label: (family) => family.label,
                  onChanged: controller.setInterfaceFont,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const Text('Text size'),
              const SizedBox(height: AppSpacing.md),
              SegmentedButton<TextSizePreset>(
                segments: [
                  for (final preset in TextSizePreset.values)
                    ButtonSegment(value: preset, label: Text(preset.label)),
                ],
                selected: {typography.interfaceScale},
                onSelectionChanged: (selection) =>
                    controller.setInterfaceScale(selection.single),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'The next step is yours.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'This is how messages will look with these settings.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: controller.resetTypography,
                  child: const Text('Reset typography'),
                ),
              ),
            ],
          ),
        );
        return embedded
            ? content
            : Scaffold(
                appBar: AppBar(title: const Text('Appearance')),
                body: content,
              );
      },
    );
  }
}
