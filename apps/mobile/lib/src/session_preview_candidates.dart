import 'models.dart';

class BrowserPreviewTargetCandidate {
  const BrowserPreviewTargetCandidate({
    required this.host,
    required this.port,
    required this.scheme,
    required this.sourceLabel,
    this.initialUrl,
    this.cwd,
  });

  final String host;
  final int port;
  final String scheme;
  final String sourceLabel;
  final String? initialUrl;
  final String? cwd;

  String get displayHost => host == '127.0.0.1' ? 'localhost' : host;

  String get targetUrl =>
      initialUrl ?? buildBrowserPreviewTargetUrl(scheme, host, port);

  String get endpointLabel {
    final parsed = Uri.tryParse(targetUrl);
    if (parsed == null || parsed.host.isEmpty) {
      return '$displayHost:$port';
    }
    final path = parsed.path.isNotEmpty && parsed.path != '/'
        ? parsed.path
        : '';
    final query = parsed.hasQuery ? '?${parsed.query}' : '';
    return '${_displayAuthority(parsed)}$path$query';
  }

  String get previewLabel => 'Browser $endpointLabel';

  String get stableKey => '$scheme|$host|$port|$_targetPathKey';

  @override
  bool operator ==(Object other) {
    return other is BrowserPreviewTargetCandidate &&
        other.host == host &&
        other.port == port &&
        other.scheme == scheme &&
        other.stableKey == stableKey &&
        other.cwd == cwd;
  }

  @override
  int get hashCode => Object.hash(stableKey, cwd);

  String get _targetPathKey {
    final parsed = Uri.tryParse(targetUrl);
    if (parsed == null) {
      return targetUrl;
    }
    final query = parsed.hasQuery ? '?${parsed.query}' : '';
    final fragment = parsed.hasFragment ? '#${parsed.fragment}' : '';
    return '${parsed.path}$query$fragment';
  }
}

class BrowserPreviewTargetInputResult {
  const BrowserPreviewTargetInputResult._({this.candidate, this.error});

  const BrowserPreviewTargetInputResult.valid(
    BrowserPreviewTargetCandidate candidate,
  ) : this._(candidate: candidate);

  const BrowserPreviewTargetInputResult.invalid(String error)
    : this._(error: error);

  final BrowserPreviewTargetCandidate? candidate;
  final String? error;

  bool get isValid => candidate != null;
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

  void addCandidate(String rawTarget, {String? cwd}) {
    final parsed = parseBrowserPreviewTargetInput(
      rawTarget,
      sourceLabel: sourceLabel,
      cwd: cwd,
      localOnly: true,
    );
    final candidate = parsed.candidate;
    if (candidate == null) {
      return;
    }
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
      addCandidate(match.group(0) ?? '', cwd: cwd);
    }
    for (final match in _bareHostPattern.allMatches(value)) {
      addCandidate(match.group(0) ?? '', cwd: cwd);
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
    final previewHost =
        normalizeBrowserPreviewHost(preview.targetHost) ??
        preview.targetHost.trim().toLowerCase();
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

BrowserPreviewTargetInputResult parseBrowserPreviewTargetInput(
  String input, {
  String sourceLabel = _manualBrowserTargetLabel,
  String? cwd,
  bool localOnly = false,
}) {
  final raw = input.trim();
  if (raw.isEmpty) {
    return const BrowserPreviewTargetInputResult.invalid('Enter a URL.');
  }
  if (RegExp(r'\s').hasMatch(raw)) {
    return const BrowserPreviewTargetInputResult.invalid(
      'URLs cannot contain spaces.',
    );
  }

  final String candidateUrl;
  if (_portOnlyPattern.hasMatch(raw)) {
    candidateUrl = 'http://127.0.0.1:$raw/';
  } else if (raw.startsWith('::1:')) {
    candidateUrl = 'http://[::1]${raw.substring(3)}';
  } else if (raw.contains('://')) {
    candidateUrl = raw;
  } else {
    candidateUrl = 'http://$raw';
  }
  final uri = Uri.tryParse(candidateUrl);
  if (uri == null || uri.scheme.isEmpty) {
    return const BrowserPreviewTargetInputResult.invalid(
      'Enter a URL like localhost:3000.',
    );
  }

  final rawScheme = uri.scheme.trim().toLowerCase();
  if (rawScheme != 'http' && rawScheme != 'https') {
    return const BrowserPreviewTargetInputResult.invalid(
      'Only HTTP and HTTPS URLs are supported.',
    );
  }
  if (uri.host.isEmpty) {
    return const BrowserPreviewTargetInputResult.invalid(
      'Enter a URL like localhost:3000.',
    );
  }
  final scheme = normalizeBrowserPreviewScheme(rawScheme);

  final port = uri.hasPort ? uri.port : _defaultPortForScheme(scheme);
  if (port < 1 || port > 65535) {
    return const BrowserPreviewTargetInputResult.invalid(
      'Enter a port between 1 and 65535.',
    );
  }

  final rawHost = uri.host.trim().toLowerCase();
  final normalizedLocalHost = normalizeBrowserPreviewHost(rawHost);
  if (localOnly && normalizedLocalHost == null) {
    return const BrowserPreviewTargetInputResult.invalid(
      'Use a localhost URL for detected app suggestions.',
    );
  }
  final host = normalizedLocalHost ?? rawHost;
  final urlHost = _targetUrlHost(rawHost, host);
  final normalizedUrl = uri
      .replace(
        scheme: scheme,
        host: urlHost,
        port: uri.hasPort || port != _defaultPortForScheme(scheme)
            ? port
            : null,
      )
      .toString();

  return BrowserPreviewTargetInputResult.valid(
    BrowserPreviewTargetCandidate(
      host: host,
      port: port,
      scheme: scheme,
      sourceLabel: sourceLabel == _manualBrowserTargetLabel
          ? _manualSourceLabel(Uri.parse(normalizedUrl))
          : sourceLabel,
      initialUrl: normalizedUrl,
      cwd: cwd,
    ),
  );
}

String browserPreviewProfileModeForTarget(
  BrowserPreviewTargetCandidate candidate,
) {
  return isBrowserPreviewLocalHost(candidate.host) ? 'sidemesh' : 'temporary';
}

bool isBrowserPreviewLocalHost(String raw) {
  return normalizeBrowserPreviewHost(raw) != null;
}

String? normalizeBrowserPreviewHost(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final lower = trimmed
      .toLowerCase()
      .replaceAll(RegExp(r'^\[|\]$'), '');
  if (lower == '0.0.0.0' || lower == '127.0.0.1') {
    return '127.0.0.1';
  }
  if (lower.startsWith('127.')) {
    return '127.0.0.1';
  }
  if (lower == 'localhost') {
    return '127.0.0.1';
  }
  if (_localhostSubdomainPattern.hasMatch(lower)) {
    return lower;
  }
  if (lower == '::1') {
    return '::1';
  }
  return null;
}

String normalizeBrowserPreviewScheme(String raw) {
  return raw.trim().toLowerCase() == 'https' ? 'https' : 'http';
}

String buildBrowserPreviewTargetUrl(String scheme, String host, int port) {
  final uri = Uri(
    scheme: normalizeBrowserPreviewScheme(scheme),
    host: host,
    port: port,
    path: '/',
  );
  return uri.toString();
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
  r"""https?:\/\/(?:(?:[a-z0-9-]+\.)*localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1\]|::1):\d{2,5}(?:[/?#][^\s\)\]\}"']*)?""",
  caseSensitive: false,
);

final RegExp _bareHostPattern = RegExp(
  r"""(?<![:/A-Za-z0-9.-])(?:(?:[a-z0-9-]+\.)*localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1\]|::1):\d{2,5}(?:[/?#][^\s\)\]\}"']*)?(?!\d)""",
  caseSensitive: false,
);

final RegExp _portOnlyPattern = RegExp(r'^\d{1,5}$');
const String _manualBrowserTargetLabel = 'Manual URL';
final RegExp _localhostSubdomainPattern = RegExp(
  r'^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.localhost$',
);

int _defaultPortForScheme(String scheme) => scheme == 'https' ? 443 : 80;

String _targetUrlHost(String rawHost, String normalizedHost) {
  if (normalizedHost == '127.0.0.1' && rawHost == 'localhost') {
    return 'localhost';
  }
  return normalizedHost;
}

String _displayAuthority(Uri uri) {
  final host = uri.host == '127.0.0.1' ? 'localhost' : uri.host;
  if (!uri.hasPort) {
    return host;
  }
  return '$host:${uri.port}';
}

String _manualSourceLabel(Uri uri) {
  final authority = _displayAuthority(uri);
  return authority.isEmpty ? 'Browser' : authority;
}
