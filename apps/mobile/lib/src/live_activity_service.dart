import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

class LiveActivityService {
  LiveActivityService._();

  static final LiveActivityService instance = LiveActivityService._();

  static const _channel = MethodChannel('dev.sidemesh/live_activity');
  // Keep the original ID so existing approval activities are updated in place.
  static const _primaryActivityId = 'sidemesh.pendingApprovals';

  bool? _supported;
  String? _activeSessionKey;
  String? _lastPrimarySignature;
  bool _sentEmptyPrimaryEnd = false;

  Future<void> syncPrimarySession({
    required HostProfile host,
    required SessionSummary session,
    required bool isRunning,
    required bool isThinking,
    required bool isResponding,
    required PendingAction? pendingAction,
    required SessionActivity? latestActivity,
  }) async {
    if (!_isEligiblePlatform) return;
    final sessionKey = _sessionKey(host, session.id);
    if (!isRunning && pendingAction == null) {
      if (_activeSessionKey == sessionKey) {
        _activeSessionKey = null;
        await _endPrimaryActivity();
      }
      return;
    }

    final payload = _sessionPayload(
      host: host,
      session: session,
      isThinking: isThinking,
      isResponding: isResponding,
      pendingAction: pendingAction,
      latestActivity: latestActivity,
    );
    final didSync = await _syncPrimaryActivity(payload);
    if (didSync) {
      _activeSessionKey = sessionKey;
    }
  }

  Future<void> endPrimarySession({
    required HostProfile host,
    required String sessionId,
  }) async {
    if (!_isEligiblePlatform) return;
    final sessionKey = _sessionKey(host, sessionId);
    if (_activeSessionKey != sessionKey) return;
    _activeSessionKey = null;
    await _endPrimaryActivity();
  }

  Future<void> syncPendingApprovals({
    required int count,
    required String hostLabel,
    required String title,
    required String sessionTitle,
  }) async {
    if (!_isEligiblePlatform) return;
    if (_activeSessionKey != null) return;
    if (count <= 0) {
      await endPendingApprovals();
      return;
    }

    final headline = count == 1
        ? 'Approval needed'
        : '$count approvals waiting';
    final detail = title.trim().isEmpty
        ? 'Codex is waiting for permission.'
        : title.trim();
    final footnote = sessionTitle.trim();
    await _syncPrimaryActivity({
      'headline': headline,
      'detail': detail,
      'footnote': footnote,
      'status': 'approval',
      'host': hostLabel,
      'count': count,
      'badge': count > 1 ? '$count' : '!',
    });
  }

  Future<void> endPendingApprovals() async {
    if (!_isEligiblePlatform || _activeSessionKey != null) return;
    await _endPrimaryActivity();
  }

  Future<bool> _syncPrimaryActivity(Map<String, Object> payload) async {
    _sentEmptyPrimaryEnd = false;
    final signature = _signature(payload);
    if (signature == _lastPrimarySignature) return true;

    final supported = await _isSupported();
    if (!supported) return false;

    try {
      final didSync = await _channel.invokeMethod<bool>('createOrUpdate', {
        'activityId': _primaryActivityId,
        ...payload,
        'updatedAtMillis': DateTime.now().millisecondsSinceEpoch.toDouble(),
      });
      if (didSync == true) {
        _lastPrimarySignature = signature;
        return true;
      }
    } on MissingPluginException {
      _supported = false;
    } catch (error) {
      debugPrint('Failed to sync Live Activity: $error');
    }
    return false;
  }

  Future<void> _endPrimaryActivity() async {
    if (!_isEligiblePlatform || _sentEmptyPrimaryEnd) return;
    _lastPrimarySignature = null;
    _sentEmptyPrimaryEnd = true;
    try {
      await _channel.invokeMethod<bool>('end', {
        'activityId': _primaryActivityId,
      });
    } on MissingPluginException {
      _supported = false;
    } catch (error) {
      debugPrint('Failed to end Live Activity: $error');
    }
  }

  bool get _isEligiblePlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<bool> _isSupported() async {
    final cached = _supported;
    if (cached != null) return cached;
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      _supported = supported ?? false;
    } on MissingPluginException {
      _supported = false;
    } catch (error) {
      debugPrint('Failed to check Live Activity support: $error');
      _supported = false;
    }
    return _supported ?? false;
  }

  Map<String, Object> _sessionPayload({
    required HostProfile host,
    required SessionSummary session,
    required bool isThinking,
    required bool isResponding,
    required PendingAction? pendingAction,
    required SessionActivity? latestActivity,
  }) {
    final title = _sessionTitle(session);
    final model = session.runtime?.model;
    final cwd = _lastPathSegment(session.cwd);
    final footnote = [
      if (model != null && model.trim().isNotEmpty) model.trim(),
      if (cwd.isNotEmpty) cwd,
    ].join(' - ');

    if (pendingAction != null) {
      return {
        'headline': 'Approval needed',
        'detail': _nonEmpty(
          pendingAction.title,
          fallback: 'Codex is waiting for permission.',
        ),
        'footnote': title,
        'status': 'approval',
        'host': host.label,
        'count': 1,
        'badge': '!',
      };
    }

    if (latestActivity != null && !_isTerminalActivity(latestActivity)) {
      final summary = _activitySummary(latestActivity, session.cwd);
      return {
        'headline': summary.headline,
        'detail': summary.detail,
        'footnote': footnote.isEmpty ? title : '$title - $footnote',
        'status': summary.status,
        'host': host.label,
        'count': 1,
        'badge': summary.badge,
      };
    }

    if (isResponding) {
      return {
        'headline': 'Writing reply',
        'detail': 'Assistant is composing the next message.',
        'footnote': footnote.isEmpty ? title : '$title - $footnote',
        'status': 'replying',
        'host': host.label,
        'count': 1,
        'badge': 'AI',
      };
    }

    if (isThinking) {
      return {
        'headline': 'Thinking',
        'detail': 'Codex is planning the next step.',
        'footnote': footnote.isEmpty ? title : '$title - $footnote',
        'status': 'thinking',
        'host': host.label,
        'count': 1,
        'badge': '...',
      };
    }

    return {
      'headline': 'Session running',
      'detail': _nonEmpty(session.preview, fallback: session.cwd),
      'footnote': footnote.isEmpty ? title : '$title - $footnote',
      'status': 'running',
      'host': host.label,
      'count': 1,
      'badge': 'RUN',
    };
  }

  _LiveActivitySummary _activitySummary(
    SessionActivity activity,
    String sessionCwd,
  ) {
    if (activity.isCommand) {
      final command = _nonEmpty(activity.command, fallback: 'Command running');
      final detail = activity.terminalStatus == 'waiting'
          ? 'Interactive command is waiting for input.'
          : _shorten(command, 96);
      return _LiveActivitySummary(
        headline: 'Running command',
        detail: detail,
        status: 'command',
        badge: 'CMD',
      );
    }
    if (activity.isWebSearch) {
      return _LiveActivitySummary(
        headline: 'Searching web',
        detail: _webSearchDetail(activity),
        status: 'search',
        badge: 'WEB',
      );
    }
    if (activity.isImageGeneration) {
      return _LiveActivitySummary(
        headline: 'Generating image',
        detail: _nonEmpty(
          activity.revisedPrompt,
          fallback: 'Image generation is running.',
        ),
        status: 'image',
        badge: 'IMG',
      );
    }
    if (activity.isFileChange || activity.changes.isNotEmpty) {
      final files = activity.changes
          .map((change) => _relativePath(change.path, sessionCwd))
          .where((path) => path.isNotEmpty)
          .toList(growable: false);
      return _LiveActivitySummary(
        headline: 'Editing files',
        detail: files.length == 1
            ? files.first
            : files.isEmpty
            ? 'Patch is being prepared.'
            : '${files.length} files changed',
        status: 'editing',
        badge: 'EDIT',
      );
    }
    if (activity.isTurnDiff) {
      return const _LiveActivitySummary(
        headline: 'Preparing diff',
        detail: 'Codex is summarizing the turn patch.',
        status: 'diff',
        badge: 'DIFF',
      );
    }
    return const _LiveActivitySummary(
      headline: 'Working',
      detail: 'Codex is running an activity.',
      status: 'running',
      badge: 'RUN',
    );
  }

  String _webSearchDetail(SessionActivity activity) {
    final query = _nonEmpty(activity.query);
    if (query.isNotEmpty) return _shorten(query, 96);
    if (activity.queries.isNotEmpty) {
      return _shorten(activity.queries.first, 96);
    }
    final targetUrl = _nonEmpty(activity.targetUrl);
    if (targetUrl.isNotEmpty) return _shorten(targetUrl, 96);
    return 'Live web search is running.';
  }

  bool _isTerminalActivity(SessionActivity activity) {
    return const {'completed', 'failed', 'declined'}.contains(activity.status);
  }

  String _sessionKey(HostProfile host, String sessionId) {
    return '${host.id}:$sessionId';
  }

  String _signature(Map<String, Object> payload) {
    final keys = payload.keys.toList()..sort();
    return keys.map((key) => '$key=${payload[key]}').join('\u001f');
  }

  String _sessionTitle(SessionSummary session) {
    return _nonEmpty(session.title, fallback: _lastPathSegment(session.cwd));
  }

  String _nonEmpty(String? value, {String fallback = ''}) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) return _shorten(trimmed, 120);
    return fallback;
  }

  String _lastPathSegment(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty) return '';
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? normalized : parts.last;
  }

  String _relativePath(String path, String base) {
    final normalizedPath = path.trim();
    final normalizedBase = base.trim();
    if (normalizedPath.isEmpty) return '';
    if (normalizedBase.isNotEmpty &&
        normalizedPath.startsWith('$normalizedBase/')) {
      return normalizedPath.substring(normalizedBase.length + 1);
    }
    return normalizedPath;
  }

  String _shorten(String value, int maxLength) {
    final trimmed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.length <= maxLength) return trimmed;
    return '${trimmed.substring(0, maxLength - 3)}...';
  }
}

class _LiveActivitySummary {
  const _LiveActivitySummary({
    required this.headline,
    required this.detail,
    required this.status,
    required this.badge,
  });

  final String headline;
  final String detail;
  final String status;
  final String badge;
}
