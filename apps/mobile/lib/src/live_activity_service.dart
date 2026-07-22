import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class LiveActivityService {
  LiveActivityService._();

  static final LiveActivityService instance = LiveActivityService._();

  static const _channel = MethodChannel('dev.sidemesh/live_activity');
  // Keep the original ID so existing approval activities are updated in place.
  static const _primaryActivityId = 'sidemesh.pendingApprovals';
  static const _primaryOwnerKey = 'sidemesh_live_activity_primary_owner_v1';
  static const _primaryOwnerUpdatedAtKey =
      'sidemesh_live_activity_primary_owner_updated_at_v1';
  static const _primaryOwnerHostIdKey =
      'sidemesh_live_activity_primary_owner_host_id_v1';
  static const _primaryOwnerSessionIdKey =
      'sidemesh_live_activity_primary_owner_session_id_v1';
  static const _primaryOwnerTitleKey =
      'sidemesh_live_activity_primary_owner_title_v1';
  static const _primaryOwnerPreviewKey =
      'sidemesh_live_activity_primary_owner_preview_v1';
  static const _primaryOwnerCwdKey =
      'sidemesh_live_activity_primary_owner_cwd_v1';
  static const _primaryOwnerModelKey =
      'sidemesh_live_activity_primary_owner_model_v1';
  static const _primaryOwnerTtl = Duration(hours: 1);
  static const _ownerRefreshInterval = Duration(minutes: 5);

  bool? _supported;
  String? _activeSessionKey;
  String? _lastPrimarySignature;
  DateTime? _lastOwnerPersistedAt;
  bool _sentEmptyPrimaryEnd = false;

  Future<bool> isSupportedForCurrentDevice() async {
    if (!_isEligiblePlatform) return false;
    return _isSupported();
  }

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
      final shouldPersist =
          _activeSessionKey != sessionKey ||
          _lastOwnerPersistedAt == null ||
          DateTime.now().difference(_lastOwnerPersistedAt!) >
              _ownerRefreshInterval;
      _activeSessionKey = sessionKey;
      if (shouldPersist) {
        await _persistPrimaryOwner(sessionKey, host: host, session: session);
      }
    }
  }

  Future<void> endPrimarySession({
    required HostProfile host,
    required String sessionId,
  }) async {
    if (!_isEligiblePlatform) return;
    final sessionKey = _sessionKey(host, sessionId);
    if (_activeSessionKey != null && _activeSessionKey != sessionKey) return;
    if (_activeSessionKey == null && !await _primaryOwnerMatches(sessionKey)) {
      return;
    }
    _activeSessionKey = null;
    await _clearPrimaryOwner();
    await _endPrimaryActivity();
  }

  Future<void> clearPrimarySessionContext() async {
    if (!_isEligiblePlatform) return;
    _activeSessionKey = null;
    await _clearPrimaryOwner();
    await _endPrimaryActivity();
  }

  Future<void> clearPrimarySessionForHost(String hostId) async {
    if (!_isEligiblePlatform) return;
    if (_activeSessionKey?.startsWith('$hostId:') == true) {
      _activeSessionKey = null;
      await _clearPrimaryOwner();
      await _endPrimaryActivity();
      return;
    }
    if (_activeSessionKey != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_primaryOwnerHostIdKey) != hostId) return;
      await _clearPrimaryOwner();
      await _endPrimaryActivity();
    } catch (error) {
      debugPrint('Failed to clear Live Activity host context: $error');
    }
  }

  Future<void> syncPendingApprovals({
    required int count,
    required String hostLabel,
    required String title,
    required String sessionTitle,
  }) async {
    if (!_isEligiblePlatform) return;
    if (_activeSessionKey != null || await _hasRecentPrimaryOwner()) return;
    if (count <= 0) {
      await endPendingApprovals();
      return;
    }

    final headline = count == 1
        ? 'Agent needs input'
        : '$count requests waiting';
    final detail = title.trim().isEmpty
        ? 'Agent is waiting for a reply.'
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
    if (!_isEligiblePlatform ||
        _activeSessionKey != null ||
        await _hasRecentPrimaryOwner()) {
      return;
    }
    await _endPrimaryActivity();
  }

  Future<PrimaryLiveActivitySession?> loadPrimarySessionContext() async {
    if (!_isEligiblePlatform) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final owner = prefs.getString(_primaryOwnerKey);
      final updatedAtMillis = prefs.getInt(_primaryOwnerUpdatedAtKey);
      final hostId = prefs.getString(_primaryOwnerHostIdKey);
      final sessionId = prefs.getString(_primaryOwnerSessionIdKey);
      if (owner == null ||
          owner.isEmpty ||
          updatedAtMillis == null ||
          hostId == null ||
          hostId.isEmpty ||
          sessionId == null ||
          sessionId.isEmpty) {
        return null;
      }
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
      if (DateTime.now().difference(updatedAt) > _primaryOwnerTtl) {
        await _clearPrimaryOwner();
        return null;
      }
      return PrimaryLiveActivitySession(
        hostId: hostId,
        sessionId: sessionId,
        title: prefs.getString(_primaryOwnerTitleKey) ?? '',
        preview: prefs.getString(_primaryOwnerPreviewKey) ?? '',
        cwd: prefs.getString(_primaryOwnerCwdKey) ?? '',
        model: prefs.getString(_primaryOwnerModelKey),
        updatedAt: updatedAt,
      );
    } catch (error) {
      debugPrint('Failed to load Live Activity session context: $error');
      return null;
    }
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

  Future<void> _persistPrimaryOwner(
    String sessionKey, {
    required HostProfile host,
    required SessionSummary session,
  }) async {
    try {
      final now = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_primaryOwnerKey, sessionKey);
      await prefs.setInt(_primaryOwnerUpdatedAtKey, now.millisecondsSinceEpoch);
      await prefs.setString(_primaryOwnerHostIdKey, host.id);
      await prefs.setString(_primaryOwnerSessionIdKey, session.id);
      await prefs.setString(_primaryOwnerTitleKey, session.title);
      await prefs.setString(_primaryOwnerPreviewKey, session.preview);
      await prefs.setString(_primaryOwnerCwdKey, session.cwd);
      final model = session.runtime?.model?.trim();
      if (model == null || model.isEmpty) {
        await prefs.remove(_primaryOwnerModelKey);
      } else {
        await prefs.setString(_primaryOwnerModelKey, model);
      }
      _lastOwnerPersistedAt = now;
    } catch (error) {
      debugPrint('Failed to persist Live Activity owner: $error');
    }
  }

  Future<void> _clearPrimaryOwner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_primaryOwnerKey);
      await prefs.remove(_primaryOwnerUpdatedAtKey);
      await prefs.remove(_primaryOwnerHostIdKey);
      await prefs.remove(_primaryOwnerSessionIdKey);
      await prefs.remove(_primaryOwnerTitleKey);
      await prefs.remove(_primaryOwnerPreviewKey);
      await prefs.remove(_primaryOwnerCwdKey);
      await prefs.remove(_primaryOwnerModelKey);
      _lastOwnerPersistedAt = null;
    } catch (error) {
      debugPrint('Failed to clear Live Activity owner: $error');
    }
  }

  Future<bool> _hasRecentPrimaryOwner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final owner = prefs.getString(_primaryOwnerKey);
      if (owner == null || owner.isEmpty) return false;
      final updatedAtMillis = prefs.getInt(_primaryOwnerUpdatedAtKey);
      if (updatedAtMillis == null) return false;
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
      if (DateTime.now().difference(updatedAt) <= _primaryOwnerTtl) {
        return true;
      }
      await _clearPrimaryOwner();
    } catch (error) {
      debugPrint('Failed to read Live Activity owner: $error');
    }
    return false;
  }

  Future<bool> _primaryOwnerMatches(String sessionKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final owner = prefs.getString(_primaryOwnerKey);
      if (owner != sessionKey) return false;
      final updatedAtMillis = prefs.getInt(_primaryOwnerUpdatedAtKey);
      if (updatedAtMillis == null) return false;
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
      if (DateTime.now().difference(updatedAt) <= _primaryOwnerTtl) {
        return true;
      }
      await _clearPrimaryOwner();
    } catch (error) {
      debugPrint('Failed to match Live Activity owner: $error');
    }
    return false;
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
        'headline': pendingAction.isApproval
            ? 'Approval needed'
            : 'Input needed',
        'detail': _nonEmpty(
          pendingAction.title,
          fallback: pendingAction.isApproval
              ? 'Agent is waiting for permission.'
              : 'Agent is waiting for a reply.',
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
        'detail': 'Agent is planning the next step.',
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
    if (activity.isTool) {
      final title = _toolActivityDetail(activity, sessionCwd);
      final toolHeadline = _toolActivityHeadline(activity);
      return _LiveActivitySummary(
        headline: toolHeadline,
        detail: _shorten(title, 96),
        status: 'tool',
        badge: _toolActivityBadge(activity),
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
    if (activity.isContextCompaction) {
      return const _LiveActivitySummary(
        headline: 'Compacting context',
        detail: 'Summarizing older conversation history.',
        status: 'compacting',
        badge: 'CTX',
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
        detail: 'Agent is summarizing the turn patch.',
        status: 'diff',
        badge: 'DIFF',
      );
    }
    return const _LiveActivitySummary(
      headline: 'Working',
      detail: 'Agent is running an activity.',
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

  String _toolActivityHeadline(SessionActivity activity) {
    if (activity.toolAction == 'mode_change') {
      return 'Changing mode';
    }
    if (activity.toolCategory == 'filesystem') {
      return switch (activity.toolAction) {
        'read' => 'Reading file',
        'write' => 'Editing file',
        'list' => 'Listing files',
        'search' => 'Searching files',
        _ => 'Using filesystem tool',
      };
    }
    if (activity.toolCategory == 'network') {
      return activity.toolAction == 'search' ? 'Searching web' : 'Fetching page';
    }
    if (activity.toolCategory == 'command') {
      return 'Running command tool';
    }
    return 'Running tool';
  }

  String _toolActivityBadge(SessionActivity activity) {
    if (activity.toolAction == 'mode_change') {
      return 'MODE';
    }
    if (activity.toolCategory == 'filesystem') {
      return 'FILE';
    }
    if (activity.toolCategory == 'network') {
      return 'WEB';
    }
    if (activity.toolCategory == 'command') {
      return 'CMD';
    }
    return 'TOOL';
  }

  String _toolActivityDetail(SessionActivity activity, String sessionCwd) {
    final mode = _nonEmpty(activity.toolMode);
    if (mode.isNotEmpty) {
      return 'Switching to $mode mode';
    }
    final query = _nonEmpty(activity.toolQuery);
    if (query.isNotEmpty) {
      return query;
    }
    final url = _nonEmpty(activity.toolUrl);
    if (url.isNotEmpty) {
      return _shorten(url, 96);
    }
    final target = _nonEmpty(activity.toolTarget);
    if (target.isNotEmpty) {
      return _relativePath(target, sessionCwd);
    }
    return _nonEmpty(
      activity.toolTitle,
      fallback: _nonEmpty(activity.toolName, fallback: 'Tool running'),
    );
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

class PrimaryLiveActivitySession {
  const PrimaryLiveActivitySession({
    required this.hostId,
    required this.sessionId,
    required this.title,
    required this.preview,
    required this.cwd,
    required this.model,
    required this.updatedAt,
  });

  final String hostId;
  final String sessionId;
  final String title;
  final String preview;
  final String cwd;
  final String? model;
  final DateTime updatedAt;

  SessionSummary toSessionSummary({required bool isRunning}) {
    final now = DateTime.now();
    final modelValue = model?.trim();
    return SessionSummary(
      id: sessionId,
      title: title,
      preview: preview,
      cwd: cwd,
      createdAt: updatedAt,
      updatedAt: now,
      source: '',
      provider: null,
      status: isRunning ? 'running' : 'completed',
      runtime: modelValue == null || modelValue.isEmpty
          ? null
          : SessionRuntimeSummary(model: modelValue),
      gitInfo: null,
    );
  }
}
