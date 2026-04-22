import 'package:flutter/material.dart';

import 'models.dart';
import 'widgets/mesh_widgets.dart';

List<String> buildRuntimeHighlights(SessionRuntimeSummary? runtime) {
  if (runtime == null) {
    return const [];
  }

  final labels = <String>[];
  if ((runtime.model ?? '').isNotEmpty) {
    labels.add(runtime.model!);
  }
  if ((runtime.reasoningEffort ?? '').isNotEmpty) {
    labels.add(runtime.reasoningEffort!);
  }
  if ((runtime.approvalPolicy ?? '').isNotEmpty) {
    labels.add('approval ${runtime.approvalPolicy}');
  }
  if ((runtime.sandboxMode ?? '').isNotEmpty) {
    labels.add(runtime.sandboxMode!);
  }
  if (runtime.networkAccess != null) {
    labels.add(runtime.networkAccess! ? 'network on' : 'network off');
  }
  return labels;
}

String runtimeValue(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Unknown';
  }
  return value;
}

String runtimeNetworkValue(bool? value) {
  if (value == null) {
    return 'Unknown';
  }
  return value ? 'Enabled' : 'Blocked';
}

class SessionRuntimeWrap extends StatelessWidget {
  const SessionRuntimeWrap({super.key, required this.runtime});

  final SessionRuntimeSummary? runtime;

  @override
  Widget build(BuildContext context) {
    final labels = buildRuntimeHighlights(runtime);
    if (labels.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: labels
          .map(
            (label) => MeshPill(
              label: label,
              tone: MeshPillTone.accent,
              mono: true,
            ),
          )
          .toList(),
    );
  }
}
