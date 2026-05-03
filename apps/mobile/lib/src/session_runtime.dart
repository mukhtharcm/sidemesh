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
  if ((runtime.modelProvider ?? '').isNotEmpty &&
      runtime.modelProvider != 'openai') {
    labels.add(runtime.modelProvider!);
  }
  if ((runtime.mode ?? '').isNotEmpty) {
    labels.add(sessionModeLabel(runtime.mode!));
  }
  if ((runtime.serviceTier ?? '').isNotEmpty) {
    labels.add(
      runtime.serviceTier == 'fast' ? 'fast mode' : runtime.serviceTier!,
    );
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
  final context = runtime.telemetry?.contextWindow;
  if (context != null && context.tokenLimit > 0) {
    if (context.currentTokens == null) {
      labels.add('ctx ?/${context.tokenLimit} left');
    } else {
      final percent = ((1 - (context.currentTokens! / context.tokenLimit)) * 100)
          .clamp(0, 100)
          .round();
      labels.add('ctx $percent% left');
    }
  }
  final compaction = runtime.telemetry?.compaction;
  if (compaction?.status == 'running') {
    labels.add('compacting');
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

String runtimeServiceTierValue(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Unknown';
  }
  return switch (value) {
    'fast' => 'Fast',
    _ => value,
  };
}

/// Trims the highlights to just the two signals that matter at list level:
/// which model, and which mode. Everything else (approval policy, network,
/// context %, …) is detail for the session header, not the session row.
List<String> buildRuntimeCardHighlights(SessionRuntimeSummary? runtime) {
  if (runtime == null) return const [];
  final labels = <String>[];
  if ((runtime.model ?? '').isNotEmpty) labels.add(runtime.model!);
  if ((runtime.mode ?? '').isNotEmpty) labels.add(sessionModeLabel(runtime.mode!));
  return labels;
}

/// Compact runtime indicator for list cards — shows only model + mode.
class SessionRuntimeCardWrap extends StatelessWidget {
  const SessionRuntimeCardWrap({super.key, required this.runtime});

  final SessionRuntimeSummary? runtime;

  @override
  Widget build(BuildContext context) {
    final labels = buildRuntimeCardHighlights(runtime);
    if (labels.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: labels
          .map(
            (label) =>
                MeshPill(label: label, tone: MeshPillTone.accent, mono: true),
          )
          .toList(),
    );
  }
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
            (label) =>
                MeshPill(label: label, tone: MeshPillTone.accent, mono: true),
          )
          .toList(),
    );
  }
}
