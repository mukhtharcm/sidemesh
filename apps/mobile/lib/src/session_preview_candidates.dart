import 'models.dart';

class BrowserPreviewTargetCandidate {
  const BrowserPreviewTargetCandidate({
    required this.host,
    required this.port,
    required this.scheme,
    required this.sourceLabel,
    this.cwd,
  });

  final String host;
  final int port;
  final String scheme;
  final String sourceLabel;
  final String? cwd;

  String get displayHost => host == '127.0.0.1' ? 'localhost' : host;

  String get endpointLabel => '$displayHost:$port';

  String get previewLabel => 'Preview :$port';

  String get stableKey => '$scheme|$host|$port';

  @override
  bool operator ==(Object other) {
    return other is BrowserPreviewTargetCandidate &&
        other.host == host &&
        other.port == port &&
        other.scheme == scheme &&
        other.cwd == cwd;
  }

  @override
  int get hashCode => Object.hash(host, port, scheme, cwd);
}

List<BrowserPreviewTargetCandidate> collectBrowserPreviewCandidates(
  Iterable<SessionActivity> activities, {
  int limit = 6,
}) {
  final ordered = activities.toList(growable: false)
    ..sort((left, right) {
      final bySeq = right.seq.compareTo(left.seq);
      if (bySeq != 0) return bySeq;
      return right.createdAt.compareTo(left.createdAt);
    });

  final seen = <String>{};
  final candidates = <BrowserPreviewTargetCandidate>[];
  for (final activity in ordered) {
    for (final candidate in browserPreviewCandidatesForActivity(activity)) {
      if (!seen.add(candidate.stableKey)) {
        continue;
      }
      candidates.add(candidate);
      if (candidates.length >= limit) {
        return candidates;
      }
    }
  }
  return candidates;
}

List<BrowserPreviewTargetCandidate> browserPreviewCandidatesForActivity(
  SessionActivity activity,
) {
  final sourceLabel = _activitySourceLabel(activity);
  final candidates = <BrowserPreviewTargetCandidate>[];
  final seen = <String>{};

  void addCandidate(String scheme, String host, int port, {String? cwd}) {
    if (port < 1 || port > 65535) {
      return;
    }
    final normalizedHost = normalizeBrowserPreviewHost(host);
    if (normalizedHost == null) {
      return;
    }
    final normalizedScheme = normalizeBrowserPreviewScheme(scheme);
    final candidate = BrowserPreviewTargetCandidate(
      host: normalizedHost,
      port: port,
      scheme: normalizedScheme,
      sourceLabel: sourceLabel,
      cwd: cwd,
    );
    if (!seen.add(candidate.stableKey)) {
      return;
    }
    candidates.add(candidate);
  }

  void scanText(String? text, {String? cwd}) {
    final value = text?.trim();
    if (value == null || value.isEmpty) {
      return;
    }
    for (final match in _urlPattern.allMatches(value)) {
      final scheme = match.group(1) ?? 'http';
      final host = match.group(2) ?? '';
      final port = int.tryParse(match.group(3) ?? '');
      if (port != null) {
        addCandidate(scheme, host, port, cwd: cwd);
      }
    }
    for (final match in _bareHostPattern.allMatches(value)) {
      final host = match.group(1) ?? '';
      final port = int.tryParse(match.group(2) ?? '');
      if (port != null) {
        addCandidate('http', host, port, cwd: cwd);
      }
    }
  }

  scanText(activity.targetUrl, cwd: activity.cwd);
  scanText(activity.toolUrl, cwd: activity.cwd);
  scanText(activity.command, cwd: activity.cwd);
  scanText(activity.output, cwd: activity.cwd);
  scanText(activity.terminalInput, cwd: activity.cwd);
  scanText(activity.query, cwd: activity.cwd);
  for (final query in activity.queries) {
    scanText(query, cwd: activity.cwd);
  }

  return candidates;
}

HostBrowserPreviewInfo? findReusableBrowserPreview(
  Iterable<HostBrowserPreviewInfo> previews,
  BrowserPreviewTargetCandidate candidate, {
  required String? sessionId,
  required String? cwd,
  String profileMode = 'sidemesh',
}) {
  final normalizedCwd = (candidate.cwd ?? cwd ?? '').trim();
  final normalizedSessionId = (sessionId ?? '').trim();
  for (final preview in previews) {
    final previewCwd = (preview.cwd ?? '').trim();
    final previewSessionId = (preview.sessionId ?? '').trim();
    final previewHost = normalizeBrowserPreviewHost(preview.targetHost);
    if (previewHost != candidate.host ||
        preview.targetPort != candidate.port ||
        preview.scheme != candidate.scheme ||
        preview.profileMode != profileMode ||
        previewCwd != normalizedCwd ||
        previewSessionId != normalizedSessionId) {
      continue;
    }
    if (preview.status == 'running' || preview.status == 'starting') {
      return preview;
    }
  }
  return null;
}

String? normalizeBrowserPreviewHost(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final lower = trimmed.toLowerCase();
  if (lower == '0.0.0.0' || lower == '127.0.0.1') {
    return '127.0.0.1';
  }
  if (lower.startsWith('127.')) {
    return '127.0.0.1';
  }
  if (lower == 'localhost') {
    return '127.0.0.1';
  }
  if (lower == '[::1]' || lower == '::1') {
    return '::1';
  }
  return null;
}

String normalizeBrowserPreviewScheme(String raw) {
  return raw.trim().toLowerCase() == 'https' ? 'https' : 'http';
}

String _activitySourceLabel(SessionActivity activity) {
  final command = (activity.command ?? '').trim();
  if (command.isNotEmpty) {
    return command;
  }
  final toolTitle = (activity.toolTitle ?? '').trim();
  if (toolTitle.isNotEmpty) {
    return toolTitle;
  }
  final toolName = (activity.toolName ?? '').trim();
  if (toolName.isNotEmpty) {
    return toolName;
  }
  return switch (activity.type) {
    'web_search' => 'Web activity',
    'image_generation' => 'Generated image',
    'file_change' => 'Edited files',
    _ => 'Session activity',
  };
}

final RegExp _urlPattern = RegExp(
  r'(https?):\/\/((?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1\]|::1))(?::(\d{2,5}))',
  caseSensitive: false,
);

final RegExp _bareHostPattern = RegExp(
  r'(?<![:/A-Za-z0-9])((?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|::1)):(\d{2,5})(?!\d)',
  caseSensitive: false,
);
