import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_colors.dart';
import 'app_primitives.dart';

class ProviderAccessModeChoices extends StatelessWidget {
  const ProviderAccessModeChoices({
    super.key,
    required this.modes,
    required this.selectedModeId,
    required this.onSelected,
  });

  final List<ProviderAccessModeSummary> modes;
  final String? selectedModeId;
  final ValueChanged<ProviderAccessModeSummary> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Column(
      children: [
        for (var index = 0; index < modes.length; index++) ...[
          AppChoiceRow(
            title: modes[index].label,
            subtitle: modes[index].disabledReason ?? modes[index].description,
            icon: providerAccessModeIcon(modes[index].icon),
            selected: selectedModeId == modes[index].id,
            enabled: modes[index].enabled,
            selectedColor: modes[index].isDangerous ? colors.danger : null,
            selectedBackground: modes[index].isDangerous
                ? colors.dangerMuted
                : null,
            trailing: modes[index].enabled
                ? null
                : Text(
                    'Unavailable',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
            onTap: modes[index].enabled ? () => onSelected(modes[index]) : null,
          ),
          if (index != modes.length - 1)
            Divider(height: 1, color: colors.border.withValues(alpha: 0.65)),
        ],
      ],
    );
  }
}

ProviderAccessModeSummary? providerAccessModeById(
  ProviderAccessModeCatalog catalog,
  String? id,
) {
  final normalized = id?.trim() ?? '';
  if (normalized.isEmpty) return null;
  for (final mode in catalog.modes) {
    if (mode.id == normalized) return mode;
  }
  return null;
}

String? resolveEnabledProviderAccessModeId(
  ProviderAccessModeCatalog catalog, {
  String? preferred,
}) {
  final preferredMode = providerAccessModeById(catalog, preferred);
  if (preferredMode?.enabled ?? false) return preferredMode!.id;

  final defaultMode = providerAccessModeById(catalog, catalog.defaultMode);
  if (defaultMode?.enabled ?? false) return defaultMode!.id;

  for (final mode in catalog.modes) {
    if (mode.enabled) return mode.id;
  }
  return null;
}

IconData providerAccessModeIcon(String icon) {
  return switch (icon) {
    'prompt' => Icons.pan_tool_outlined,
    'automatic' => Icons.shield_outlined,
    'read-only' => Icons.visibility_outlined,
    'unrestricted' => Icons.gpp_maybe_outlined,
    _ => Icons.settings_outlined,
  };
}
