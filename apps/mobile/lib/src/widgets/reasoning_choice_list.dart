import 'package:flutter/material.dart';

import '../models.dart';
import 'app_primitives.dart';
import 'mesh_widgets.dart';

String reasoningEffortLabel(String value) {
  final normalized = value.trim();
  return switch (normalized) {
    'none' => 'None',
    'minimal' => 'Minimal',
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' => 'Extra high',
    _ => _titleCaseReasoningValue(normalized),
  };
}

String _titleCaseReasoningValue(String value) {
  if (value.isEmpty) return 'Default';
  return value
      .replaceAll(RegExp(r'[-_]'), ' ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map(
        (part) =>
            '${part.substring(0, 1).toUpperCase()}${part.substring(1).toLowerCase()}',
      )
      .join(' ');
}

class ReasoningChoiceList extends StatelessWidget {
  const ReasoningChoiceList({
    super.key,
    required this.options,
    required this.currentReasoning,
    required this.defaultReasoning,
    required this.onSelected,
    this.padding = EdgeInsets.zero,
  });

  final List<ModelReasoningEffortOption> options;
  final String currentReasoning;
  final String defaultReasoning;
  final ValueChanged<String> onSelected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: padding,
      itemCount: options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final option = options[index];
        final selected = option.reasoningEffort == currentReasoning;
        final isDefault = option.reasoningEffort == defaultReasoning;
        return AppChoiceRow(
          title: reasoningEffortLabel(option.reasoningEffort),
          subtitle: option.description,
          icon: Icons.psychology_alt_rounded,
          selected: selected,
          onTap: () => onSelected(option.reasoningEffort),
          trailing: !selected && isDefault
              ? const MeshInlineBadge(label: 'default')
              : null,
        );
      },
    );
  }
}
