import 'models.dart';

String? agentProviderDisplayLabel(String? providerKind, {String? providerId, NodeInfo? nodeInfo}) {
  final kind = (providerKind ?? '').trim();
  if (kind.isEmpty) {
    return null;
  }

  final summary = nodeInfo?.providerSummary(providerId ?? kind);
  if (summary != null && summary.displayName.trim().isNotEmpty) {
    return summary.label;
  }
  if (nodeInfo != null && kind == nodeInfo.provider) {
    return nodeInfo.providerDisplayName;
  }

  final name = switch (kind) {
    'codex' => 'Codex',
    'pi' => 'Pi',
    'copilot' => 'GitHub Copilot',
    'fake' => 'Fake',
    _ => _titleCaseProviderKind(kind),
  };
  return providerId == null || providerId == kind ? name : '$name · $providerId';
}

String _titleCaseProviderKind(String kind) {
  final words = kind
      .split(RegExp(r'[-_\s]+'))
      .where((word) => word.trim().isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) {
    return kind;
  }
  return words
      .map((word) {
        if (word.length == 1) {
          return word.toUpperCase();
        }
        return '${word[0].toUpperCase()}${word.substring(1)}';
      })
      .join(' ');
}
