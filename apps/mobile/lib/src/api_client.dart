import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'fs_models.dart';
import 'usage_models.dart';

const _defaultWriteRequestTimeout = Duration(seconds: 45);
const _webSocketAppProtocol = 'sidemesh';
const _webSocketAuthProtocolPrefix = 'sidemesh.auth.';

class ApiClient {
  ApiClient({
    http.Client? client,
    Duration defaultWriteTimeout = _defaultWriteRequestTimeout,
  }) : assert(defaultWriteTimeout > Duration.zero),
       _client = client ?? http.Client(),
       _defaultWriteTimeout = defaultWriteTimeout;

  static const Duration _quickReadTimeout = Duration(seconds: 6);
  static const Duration _standardReadTimeout = Duration(seconds: 12);
  static const Duration _transcriptReadTimeout = Duration(seconds: 25);
  static const Duration _diffReadTimeout = Duration(seconds: 25);
  static const Duration _turnWriteTimeout = Duration(seconds: 45);
  static const Duration _webSocketConnectTimeout = Duration(seconds: 8);
  static const Duration _interactiveWebSocketPingInterval = Duration(
    seconds: 20,
  );
  static const Duration _backgroundWebSocketPingInterval = Duration(minutes: 1);

  final http.Client _client;
  final Duration _defaultWriteTimeout;

  Future<NodeInfo> fetchNode(HostProfile host) async {
    final response = await _get(
      host,
      '/api/node',
      timeout: _quickReadTimeout,
      operation: 'reach ${host.label}',
    );
    return NodeInfo.fromJson(_decodeObject(response));
  }

  Future<ProviderMetadata> fetchProviders(HostProfile host) async {
    final response = await _get(
      host,
      '/api/providers',
      timeout: _quickReadTimeout,
      operation: 'load providers',
    );
    return ProviderMetadata.fromJson(_decodeObject(response));
  }

  Future<HostUsageSnapshot> fetchUsage(HostProfile host) async {
    final response = await _get(
      host,
      '/api/usage',
      timeout: _standardReadTimeout,
      operation: 'load usage',
    );
    return HostUsageSnapshot.fromJson(host, _decodeObject(response));
  }

  Future<List<WorkspaceSummary>> fetchWorkspaces(HostProfile host) async {
    final response = await _get(
      host,
      '/api/workspaces',
      operation: 'load workspaces',
    );
    return _decodeList(response).map(WorkspaceSummary.fromJson).toList();
  }

  Future<SkillCatalog> fetchSkills(
    HostProfile host, {
    required String cwd,
    bool forceReload = false,
    String? agentProvider,
  }) async {
    final response = await _get(
      host,
      '/api/skills',
      queryParameters: <String, String>{
        'cwd': cwd,
        if (forceReload) 'forceReload': 'true',
        if ((agentProvider ?? '').isNotEmpty) 'agentProvider': agentProvider!,
      },
      timeout: _standardReadTimeout,
      operation: 'load skills',
    );
    return SkillCatalog.fromJson(_decodeObject(response));
  }

  Future<List<ModelCatalogEntry>> fetchModels(
    HostProfile host, {
    String? cwd,
    String? profile,
    String? agentProvider,
    String? provider,
  }) async {
    final queryParameters = <String, String>{
      if ((cwd ?? '').isNotEmpty) 'cwd': cwd!,
      if ((profile ?? '').isNotEmpty) 'profile': profile!,
      if ((agentProvider ?? '').isNotEmpty) 'agentProvider': agentProvider!,
      if ((provider ?? '').isNotEmpty) 'provider': provider!,
    };
    final response = await _get(
      host,
      '/api/models',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
      operation: 'load models',
    );
    return _decodeList(response).map(ModelCatalogEntry.fromJson).toList();
  }

  Future<ProviderProfileCatalog> fetchProfiles(
    HostProfile host, {
    String? cwd,
    String? agentProvider,
  }) async {
    final queryParameters = <String, String>{
      if ((cwd ?? '').isNotEmpty) 'cwd': cwd!,
      if ((agentProvider ?? '').isNotEmpty) 'agentProvider': agentProvider!,
    };
    final response = await _get(
      host,
      '/api/profiles',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
      timeout: _standardReadTimeout,
      operation: 'load profiles',
    );
    return ProviderProfileCatalog.fromJson(_decodeObject(response));
  }

  Future<ProviderModeCatalog> fetchModes(
    HostProfile host, {
    String? cwd,
    String? agentProvider,
  }) async {
    final queryParameters = <String, String>{
      if ((cwd ?? '').isNotEmpty) 'cwd': cwd!,
      if ((agentProvider ?? '').isNotEmpty) 'agentProvider': agentProvider!,
    };
    final response = await _get(
      host,
      '/api/modes',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
      timeout: _standardReadTimeout,
      operation: 'load modes',
    );
    return ProviderModeCatalog.fromJson(_decodeObject(response));
  }

  Future<List<SessionSummary>> fetchSessions(
    HostProfile host, {
    int? limit,
  }) async {
    final response = await _get(
      host,
      '/api/sessions',
      queryParameters: limit == null ? null : {'limit': '$limit'},
      operation: 'load recent sessions',
    );
    return _decodeList(response).map(SessionSummary.fromJson).toList();
  }

  Future<List<SessionSummary>> searchSessions(
    HostProfile host, {
    required String query,
    int? limit,
  }) async {
    final queryParameters = <String, String>{
      'q': query,
      if (limit != null) 'limit': '$limit',
    };
    final response = await _get(
      host,
      '/api/sessions/search',
      queryParameters: queryParameters,
      timeout: _standardReadTimeout,
      operation: 'search sessions',
    );
    return _decodeList(response).map(SessionSummary.fromJson).toList();
  }

  Future<List<PendingAction>> fetchPendingActions(HostProfile host) async {
    final response = await _get(
      host,
      '/api/actions',
      timeout: _quickReadTimeout,
      operation: 'load approvals',
    );
    return _decodeList(response).map(PendingAction.fromJson).toList();
  }

  Future<List<HostTerminalInfo>> fetchTerminals(HostProfile host) async {
    final response = await _get(
      host,
      '/api/terminals',
      timeout: _quickReadTimeout,
      operation: 'load terminals',
    );
    final decoded = _decodeObject(response);
    return ((decoded['terminals'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => HostTerminalInfo.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  // -------------------------- Admin diagnostics --------------------------

  Future<void> restartProvider(HostProfile host, String kind) async {
    await _post(
      host,
      '/api/admin/provider/$kind/restart',
      body: const {},
      timeout: const Duration(seconds: 15),
      operation: 'restart provider',
    );
  }

  Future<void> restartDaemon(HostProfile host) async {
    await _post(
      host,
      '/api/admin/restart',
      body: const {},
      timeout: const Duration(seconds: 15),
      operation: 'restart daemon',
    );
  }

  Future<UpdateOperation?> updateDaemon(
    HostProfile host, {
    String? updateChannel,
  }) async {
    final response = await _post(
      host,
      '/api/admin/update',
      body: {if ((updateChannel ?? '').isNotEmpty) 'channel': updateChannel},
      timeout: const Duration(seconds: 15),
      operation: 'update daemon',
    );
    final decoded = _decodeObject(response);
    return UpdateOperation.fromJsonValue(decoded['update']);
  }

  Future<UpdateOperation?> fetchUpdateStatus(HostProfile host) async {
    final response = await _get(
      host,
      '/api/admin/update-status',
      timeout: _quickReadTimeout,
      operation: 'check update status',
    );
    final decoded = _decodeObject(response);
    return UpdateOperation.fromJsonValue(decoded['update']);
  }

  Future<void> setUpdateChannel(HostProfile host, String updateChannel) async {
    await _post(
      host,
      '/api/admin/update-channel',
      body: {'channel': updateChannel},
      timeout: const Duration(seconds: 15),
      operation: 'set update channel',
    );
  }

  Future<UpdateInfo> refreshUpdateInfo(HostProfile host) async {
    final response = await _post(
      host,
      '/api/admin/update-check',
      body: const {},
      timeout: const Duration(seconds: 20),
      operation: 'check for updates',
    );
    return UpdateInfo.fromJson(_decodeObject(response));
  }

  Future<HostTerminalInfo> createTerminal(
    HostProfile host, {
    required String cwd,
    String? sessionId,
    String? title,
    int? cols,
    int? rows,
    bool replaceExisting = false,
  }) async {
    final body = <String, dynamic>{
      'cwd': cwd,
      if ((sessionId ?? '').isNotEmpty) 'sessionId': sessionId,
      if ((title ?? '').isNotEmpty) 'title': title,
      if (replaceExisting) 'replaceExisting': true,
    };
    if (cols != null) {
      body['cols'] = cols;
    }
    if (rows != null) {
      body['rows'] = rows;
    }
    final response = await _post(
      host,
      '/api/terminals',
      body: body,
      timeout: _standardReadTimeout,
      operation: 'start terminal',
    );
    return HostTerminalInfo.fromJson(_decodeObject(response));
  }

  Future<HostTerminalInfo> resizeTerminal(
    HostProfile host,
    String terminalId, {
    required int cols,
    required int rows,
  }) async {
    final response = await _post(
      host,
      '/api/terminals/$terminalId/resize',
      body: {'cols': cols, 'rows': rows},
      timeout: _quickReadTimeout,
      operation: 'resize terminal',
    );
    return HostTerminalInfo.fromJson(_decodeObject(response));
  }

  Future<HostTerminalInfo> killTerminal(
    HostProfile host,
    String terminalId,
  ) async {
    final response = await _post(
      host,
      '/api/terminals/$terminalId/kill',
      body: const {},
      timeout: _quickReadTimeout,
      operation: 'stop terminal',
    );
    return HostTerminalInfo.fromJson(_decodeObject(response));
  }

  Future<List<HostBrowserPreviewInfo>> fetchBrowserPreviews(
    HostProfile host,
  ) async {
    final response = await _get(
      host,
      '/api/browser-previews',
      timeout: _quickReadTimeout,
      operation: 'load browser tabs',
    );
    final decoded = _decodeObject(response);
    return ((decoded['previews'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              HostBrowserPreviewInfo.fromJson(item.cast<String, dynamic>()),
        )
        .toList();
  }

  Future<HostBrowserPreviewInfo> createBrowserPreview(
    HostProfile host, {
    int? targetPort,
    String targetHost = '127.0.0.1',
    String? targetUrl,
    String scheme = 'http',
    String? label,
    String? cwd,
    String? sessionId,
    int? width,
    int? height,
    String profileMode = 'temporary',
    bool reuseExisting = true,
  }) async {
    final normalizedTargetUrl = (targetUrl ?? '').trim();
    if (targetPort == null && normalizedTargetUrl.isEmpty) {
      throw ArgumentError('targetPort or targetUrl is required');
    }
    final body = <String, dynamic>{
      'targetHost': targetHost,
      'scheme': scheme,
      'profileMode': profileMode,
      'targetPort': ?targetPort,
      if (normalizedTargetUrl.isNotEmpty) 'targetUrl': normalizedTargetUrl,
      if ((label ?? '').isNotEmpty) 'label': label,
      if ((cwd ?? '').isNotEmpty) 'cwd': cwd,
      if ((sessionId ?? '').isNotEmpty) 'sessionId': sessionId,
      if (!reuseExisting) 'reuseExisting': false,
    };
    if (width != null) {
      body['width'] = width;
    }
    if (height != null) {
      body['height'] = height;
    }
    final response = await _post(
      host,
      '/api/browser-previews',
      body: body,
      timeout: _standardReadTimeout,
      operation: 'open browser',
    );
    return HostBrowserPreviewInfo.fromJson(_decodeObject(response));
  }

  Future<void> stopBrowserPreview(HostProfile host, String previewId) async {
    final response = await _delete(
      host,
      '/api/browser-previews/$previewId',
      timeout: _quickReadTimeout,
      operation: 'close browser tab',
    );
    _throwIfBadStatus(response);
  }

  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async {
    final queryParameters = <String, String>{};
    if (messageLimit != null) {
      queryParameters['messageLimit'] = '$messageLimit';
    }
    if (activityLimit != null) {
      queryParameters['activityLimit'] = '$activityLimit';
    }
    final response = await _get(
      host,
      '/api/sessions/$sessionId/log',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
      timeout: _transcriptReadTimeout,
      operation: 'load session transcript',
    );
    return SessionLog.fromJson(_decodeObject(response));
  }

  Future<SessionResourcesResponse> fetchResources(
    HostProfile host,
    String sessionId,
  ) async {
    final response = await _get(
      host,
      '/api/sessions/$sessionId/resources',
      timeout: _transcriptReadTimeout,
      operation: 'load session resources',
    );
    return SessionResourcesResponse.fromJson(_decodeObject(response));
  }

  Future<SessionEventsDelta> fetchEvents(
    HostProfile host,
    String sessionId, {
    required int since,
    int? baseUpdatedAt,
  }) async {
    final response = await _get(
      host,
      '/api/sessions/$sessionId/events',
      queryParameters: {
        'since': '$since',
        if (baseUpdatedAt != null) 'baseUpdatedAt': '$baseUpdatedAt',
      },
      operation: 'catch up session events',
    );
    return SessionEventsDelta.fromJson(_decodeObject(response));
  }

  Future<SessionStatus> fetchStatus(HostProfile host, String sessionId) async {
    final response = await _get(
      host,
      '/api/sessions/$sessionId/status',
      timeout: _quickReadTimeout,
      operation: 'load session status',
    );
    return SessionStatus.fromJson(_decodeObject(response));
  }

  Future<SessionGitStatus> fetchGitStatus(
    HostProfile host,
    String sessionId,
  ) async {
    final response = await _get(
      host,
      '/api/sessions/$sessionId/git',
      operation: 'load git status',
    );
    return SessionGitStatus.fromJson(_decodeObject(response));
  }

  Future<SessionGitDiff> fetchGitDiff(
    HostProfile host,
    String sessionId, {
    required String kind,
  }) async {
    final response = await _get(
      host,
      '/api/sessions/$sessionId/git/diff',
      queryParameters: {'kind': kind},
      timeout: _diffReadTimeout,
      operation: 'load git diff',
    );
    return SessionGitDiff.fromJson(_decodeObject(response));
  }

  Future<SessionSummary> createSession(
    HostProfile host, {
    required String cwd,
    required String prompt,
    String? provider,
    List<SessionInputItem>? input,
    String? model,
    String? mode,
    String? reasoningEffort,
    bool? fastMode,
    String? approvalPolicy,
    String? sandboxMode,
    String? webSearch,
    String? profile,
  }) async {
    final body = <String, dynamic>{'cwd': cwd, 'prompt': prompt};
    if ((provider ?? '').isNotEmpty) {
      body['provider'] = provider;
    }
    if (input != null && input.isNotEmpty) {
      body['input'] = input.map((item) => item.toJson()).toList();
    }
    if ((model ?? '').isNotEmpty) {
      body['model'] = model;
    }
    if ((mode ?? '').isNotEmpty) {
      body['mode'] = mode;
    }
    if ((reasoningEffort ?? '').isNotEmpty) {
      body['reasoningEffort'] = reasoningEffort;
    }
    if (fastMode != null) {
      body['fastMode'] = fastMode;
    }
    if ((approvalPolicy ?? '').isNotEmpty) {
      body['approvalPolicy'] = approvalPolicy;
    }
    if ((sandboxMode ?? '').isNotEmpty) {
      body['sandboxMode'] = sandboxMode;
    }
    if ((webSearch ?? '').isNotEmpty) {
      body['webSearch'] = webSearch;
    }
    if ((profile ?? '').isNotEmpty) {
      body['profile'] = profile;
    }
    final response = await _post(
      host,
      '/api/sessions/create',
      body: body,
      operation: 'start session',
    );
    final payload = _decodeObject(response);
    return SessionSummary.fromJson(payload['session'] as Map<String, dynamic>);
  }

  Future<void> sendInput(
    HostProfile host, {
    required String sessionId,
    String text = '',
    List<SessionInputItem>? input,
    String? clientMessageId,
    String? model,
    String? mode,
    String? reasoningEffort,
    bool? fastMode,
    String? approvalPolicy,
    String? sandboxMode,
    bool? networkAccess,
  }) async {
    final body = <String, dynamic>{
      if (text.isNotEmpty) 'text': text,
      if (input != null && input.isNotEmpty)
        'input': input.map((item) => item.toJson()).toList(),
      ...?clientMessageId == null
          ? null
          : <String, dynamic>{'clientMessageId': clientMessageId},
      ...?(model ?? '').isEmpty ? null : <String, dynamic>{'model': model},
      ...?(mode ?? '').isEmpty ? null : <String, dynamic>{'mode': mode},
      ...?(reasoningEffort ?? '').isEmpty
          ? null
          : <String, dynamic>{'reasoningEffort': reasoningEffort},
      ...?fastMode == null ? null : <String, dynamic>{'fastMode': fastMode},
      ...?approvalPolicy == null
          ? null
          : <String, dynamic>{'approvalPolicy': approvalPolicy},
      ...?sandboxMode == null
          ? null
          : <String, dynamic>{'sandbox': sandboxMode},
      ...?networkAccess == null
          ? null
          : <String, dynamic>{'networkAccess': networkAccess},
    };
    await _post(
      host,
      '/api/sessions/$sessionId/input',
      body: body,
      timeout: _turnWriteTimeout,
      operation: 'send message',
    );
  }

  Future<void> stopSession(HostProfile host, String sessionId) async {
    await _post(
      host,
      '/api/sessions/$sessionId/stop',
      body: const {},
      operation: 'stop session',
    );
  }

  Future<void> compactSession(HostProfile host, String sessionId) async {
    await _post(
      host,
      '/api/sessions/$sessionId/compact',
      body: const {},
      operation: 'compact session',
    );
  }

  Future<SessionSummary> renameSession(
    HostProfile host, {
    required String sessionId,
    required String name,
  }) async {
    final response = await _post(
      host,
      '/api/sessions/$sessionId/name',
      body: {'name': name},
      operation: 'rename session',
    );
    final payload = _decodeObject(response);
    return SessionSummary.fromJson(payload['session'] as Map<String, dynamic>);
  }

  Future<void> archiveSession(HostProfile host, String sessionId) async {
    await _post(
      host,
      '/api/sessions/$sessionId/archive',
      body: const {},
      operation: 'archive session',
    );
  }

  Future<void> unarchiveSession(HostProfile host, String sessionId) async {
    await _post(
      host,
      '/api/sessions/$sessionId/unarchive',
      body: const {},
      operation: 'unarchive session',
    );
  }

  Future<void> respondToAction(
    HostProfile host, {
    required String actionId,
    required PendingActionResponseDraft response,
  }) async {
    await _post(
      host,
      '/api/actions/$actionId/respond',
      body: response.payload,
      operation: 'respond to agent request',
    );
  }

  WebSocketChannel openLive(HostProfile host, String sessionId) {
    _ensureHostEnabled(host);
    final baseUri = Uri.parse(host.baseUrl);
    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/live',
      queryParameters: {'sessionId': sessionId},
    );

    return _connectWebSocket(
      host,
      wsUri,
      pingInterval: _interactiveWebSocketPingInterval,
    );
  }

  WebSocketChannel openActionsLive(HostProfile host) {
    _ensureHostEnabled(host);
    final baseUri = Uri.parse(host.baseUrl);
    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/actions/live',
    );

    return _connectWebSocket(
      host,
      wsUri,
      pingInterval: _backgroundWebSocketPingInterval,
    );
  }

  WebSocketChannel openSessionsLive(HostProfile host) {
    _ensureHostEnabled(host);
    final baseUri = Uri.parse(host.baseUrl);
    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/sessions/live',
    );

    return _connectWebSocket(
      host,
      wsUri,
      pingInterval: _backgroundWebSocketPingInterval,
    );
  }

  WebSocketChannel openTerminalLive(
    HostProfile host,
    String terminalId, {
    int since = -1,
  }) {
    _ensureHostEnabled(host);
    final baseUri = Uri.parse(host.baseUrl);
    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/terminals/$terminalId/live',
      queryParameters: {'since': '$since'},
    );

    return _connectWebSocket(
      host,
      wsUri,
      pingInterval: _interactiveWebSocketPingInterval,
    );
  }

  WebSocketChannel openBrowserPreviewLive(HostProfile host, String previewId) {
    _ensureHostEnabled(host);
    final baseUri = Uri.parse(host.baseUrl);
    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/browser-previews/$previewId/live',
    );

    return _connectWebSocket(
      host,
      wsUri,
      pingInterval: _interactiveWebSocketPingInterval,
    );
  }

  Uri fsBlobUri(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) {
    _ensureHostEnabled(host);
    return _uri(
      host,
      '/api/fs/blob',
      queryParameters: _fsQuery(path: path, sessionId: sessionId),
    );
  }

  Future<Uint8List> fetchFsBlob(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    final response = await _get(
      host,
      '/api/fs/blob',
      queryParameters: _fsQuery(path: path, sessionId: sessionId),
      timeout: _transcriptReadTimeout,
      operation: 'load image',
    );
    _throwIfBadStatus(response);
    return response.bodyBytes;
  }

  Map<String, String> authHeaders(HostProfile host) {
    _ensureHostEnabled(host);
    return {'Authorization': 'Bearer ${host.token}'};
  }

  // -------------------------- Workspace filesystem --------------------------

  Future<List<String>> fetchFsRoots(
    HostProfile host, {
    String? agentProvider,
    String? sessionId,
  }) async {
    final response = await _get(
      host,
      '/api/fs/roots',
      queryParameters: _fsQuery(sessionId: sessionId),
      operation: 'load roots',
    );
    final decoded = _decodeObject(response);
    return ((decoded['roots'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  Future<List<FsSearchResult>> searchFiles(
    HostProfile host, {
    required String query,
    String? sessionId,
    int? limit,
  }) async {
    final response = await _post(
      host,
      '/api/fs/search',
      body: {'query': query, 'sessionId': sessionId, 'limit': limit},
      operation: 'search files',
    );
    final decoded = _decodeObject(response);
    return ((decoded['files'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(FsSearchResult.fromJson)
        .toList();
  }

  Future<FsListing> listDirectory(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    final response = await _get(
      host,
      '/api/fs/list',
      queryParameters: _fsQuery(path: path, sessionId: sessionId),
      operation: 'list directory',
    );
    return FsListing.fromJson(_decodeObject(response));
  }

  Future<FsMetadata> fetchMetadata(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    final response = await _get(
      host,
      '/api/fs/metadata',
      queryParameters: _fsQuery(path: path, sessionId: sessionId),
      operation: 'load file metadata',
    );
    return FsMetadata.fromJson(_decodeObject(response));
  }

  Future<FsFile> readFile(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    final response = await _get(
      host,
      '/api/fs/read',
      queryParameters: _fsQuery(path: path, sessionId: sessionId),
      timeout: _transcriptReadTimeout,
      operation: 'read file',
    );
    return FsFile.fromJson(_decodeObject(response));
  }

  Future<void> writeFile(
    HostProfile host, {
    required String path,
    required String contents,
    String? agentProvider,
    String? sessionId,
  }) async {
    await _post(
      host,
      '/api/fs/write',
      body: {
        'path': path,
        'contents': contents,
        if ((sessionId ?? '').isNotEmpty) 'sessionId': sessionId,
      },
      operation: 'write file',
    );
  }

  Future<void> createDirectory(
    HostProfile host, {
    required String path,
    bool recursive = true,
    String? agentProvider,
    String? sessionId,
  }) async {
    await _post(
      host,
      '/api/fs/createDir',
      body: {
        'path': path,
        'recursive': recursive,
        if ((sessionId ?? '').isNotEmpty) 'sessionId': sessionId,
      },
      operation: 'create directory',
    );
  }

  Future<void> remove(
    HostProfile host, {
    required String path,
    bool recursive = true,
    bool force = true,
    String? agentProvider,
    String? sessionId,
  }) async {
    await _post(
      host,
      '/api/fs/remove',
      body: {
        'path': path,
        'recursive': recursive,
        'force': force,
        if ((sessionId ?? '').isNotEmpty) 'sessionId': sessionId,
      },
      operation: 'remove file',
    );
  }

  Future<void> copy(
    HostProfile host, {
    required String sourcePath,
    required String destinationPath,
    bool recursive = false,
    String? agentProvider,
    String? sessionId,
  }) async {
    await _post(
      host,
      '/api/fs/copy',
      body: {
        'sourcePath': sourcePath,
        'destinationPath': destinationPath,
        'recursive': recursive,
        if ((sessionId ?? '').isNotEmpty) 'sessionId': sessionId,
      },
      operation: 'copy file',
    );
  }

  WebSocketChannel openFsLive(
    HostProfile host, {
    String? agentProvider,
    String? sessionId,
  }) {
    _ensureHostEnabled(host);
    final baseUri = Uri.parse(host.baseUrl);
    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/fs/live',
      queryParameters: _fsQuery(sessionId: sessionId),
    );
    return _connectWebSocket(
      host,
      wsUri,
      pingInterval: _backgroundWebSocketPingInterval,
    );
  }

  WebSocketChannel _connectWebSocket(
    HostProfile host,
    Uri uri, {
    required Duration pingInterval,
  }) {
    if (kIsWeb) {
      final encodedToken = base64Url
          .encode(utf8.encode(host.token))
          .replaceAll('=', '');
      return WebSocketChannel.connect(
        uri,
        protocols: <String>[
          _webSocketAppProtocol,
          '$_webSocketAuthProtocolPrefix$encodedToken',
        ],
      );
    }
    return IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer ${host.token}'},
      connectTimeout: _webSocketConnectTimeout,
      pingInterval: pingInterval,
    );
  }

  Map<String, String>? _fsQuery({String? path, String? sessionId}) {
    final query = <String, String>{
      if ((path ?? '').isNotEmpty) 'path': path!,
      if ((sessionId ?? '').isNotEmpty) 'sessionId': sessionId!,
    };
    return query.isEmpty ? null : query;
  }

  Future<http.Response> _get(
    HostProfile host,
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
    String? operation,
  }) {
    _ensureHostEnabled(host);
    final resolvedTimeout = timeout ?? _standardReadTimeout;
    return _withTimeout(
      _client.get(
        _uri(host, path, queryParameters: queryParameters),
        headers: authHeaders(host),
      ),
      timeout: resolvedTimeout,
      operation: operation ?? 'load data',
    );
  }

  Future<http.Response> _post(
    HostProfile host,
    String path, {
    required Map<String, dynamic> body,
    Duration? timeout,
    String? operation,
  }) {
    _ensureHostEnabled(host);
    final resolvedTimeout = timeout ?? _defaultWriteTimeout;
    final request = _client.post(
      _uri(host, path),
      headers: _jsonHeaders(host),
      body: jsonEncode(body),
    );
    return _withTimeout(
      request,
      timeout: resolvedTimeout,
      operation: operation ?? 'send request',
    );
  }

  Future<http.Response> _delete(
    HostProfile host,
    String path, {
    Duration? timeout,
    String? operation,
  }) {
    _ensureHostEnabled(host);
    final resolvedTimeout = timeout ?? _defaultWriteTimeout;
    final request = _client.delete(
      _uri(host, path),
      headers: authHeaders(host),
    );
    return _withTimeout(
      request,
      timeout: resolvedTimeout,
      operation: operation ?? 'delete request',
    );
  }

  Future<T> _withTimeout<T>(
    Future<T> request, {
    required Duration timeout,
    required String operation,
  }) {
    return request.timeout(
      timeout,
      onTimeout: () => throw ApiTimeoutException(operation, timeout),
    );
  }

  Uri _uri(
    HostProfile host,
    String path, {
    Map<String, String>? queryParameters,
  }) {
    final base = Uri.parse(host.baseUrl);
    return base.replace(path: path, queryParameters: queryParameters);
  }

  Map<String, String> _jsonHeaders(HostProfile host) => {
    ...authHeaders(host),
    'Content-Type': 'application/json',
  };

  void _ensureHostEnabled(HostProfile host) {
    if (!host.enabled) {
      throw StateError('Host "${host.label}" is disabled.');
    }
    final browserIssue = browserHostUrlIssue(host.baseUrl);
    if (browserIssue != null) {
      throw BrowserHostConnectionException(browserIssue);
    }
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    _throwIfBadStatus(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return decoded;
  }

  List<Map<String, dynamic>> _decodeList(http.Response response) {
    _throwIfBadStatus(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! List<dynamic>) {
      throw const FormatException('Expected a JSON array');
    }
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  void _throwIfBadStatus(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw ApiException(
      response.statusCode,
      response.body.isEmpty ? 'Request failed' : response.body,
    );
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode): $body';
}

class ApiTimeoutException implements Exception {
  const ApiTimeoutException(this.operation, this.timeout);

  final String operation;
  final Duration timeout;

  int get seconds => timeout.inSeconds;

  @override
  String toString() => 'ApiTimeoutException($operation, ${seconds}s)';
}

class BrowserHostConnectionException implements Exception {
  const BrowserHostConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns low-level errors (ApiException, SocketException, TimeoutException)
/// into short human-readable strings suitable for snackbars.
String friendlyError(Object error) {
  if (error is ApiTimeoutException) {
    return 'Timed out trying to ${error.operation} after ${error.seconds}s.';
  }
  if (error is ApiException) {
    final parsed = _tryExtractMessage(error.body);
    if (parsed != null && parsed.isNotEmpty) {
      return parsed;
    }
    switch (error.statusCode) {
      case 401:
      case 403:
        return 'Not authorized (${error.statusCode}). Check the host token.';
      case 404:
        return 'Not found on the host.';
      case 408:
      case 504:
        return 'The host took too long to respond.';
      case 500:
      case 502:
      case 503:
        return 'The host reported a server error (${error.statusCode}).';
    }
    return 'Request failed (${error.statusCode}).';
  }
  final text = error.toString();
  if (text.contains('SocketException') ||
      text.contains('Connection refused') ||
      text.contains('Failed host lookup')) {
    return "Couldn't reach the host. Is the Sidemesh daemon running?";
  }
  if (text.contains('TimeoutException')) {
    return 'Request timed out.';
  }
  if (text.startsWith('Bad state: Host ') && text.contains(' is disabled.')) {
    return text.replaceFirst('Bad state: ', '');
  }
  final trimmed = text.replaceFirst('Exception: ', '');
  return trimmed.length > 160 ? '${trimmed.substring(0, 157)}…' : trimmed;
}

bool isRetryableSendError(Object error) {
  if (error is ApiTimeoutException ||
      error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException) {
    return true;
  }
  if (error is ApiException) {
    return error.statusCode == 408 ||
        error.statusCode == 429 ||
        error.statusCode >= 500;
  }
  return false;
}

String? _tryExtractMessage(String body) {
  if (body.isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      for (final key in const ['message', 'error', 'detail']) {
        final v = decoded[key];
        if (v is String && v.isNotEmpty) return v;
      }
    }
    if (decoded is String && decoded.isNotEmpty) return decoded;
  } catch (_) {
    // Not JSON — fall through.
  }
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > 160) return '${trimmed.substring(0, 157)}…';
  return trimmed;
}

String normalizeBaseUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final uri = Uri.parse(withScheme);
  final normalized = uri.replace(path: '', query: '', fragment: '');
  return normalized.toString().replaceFirst(RegExp(r'/$'), '');
}

String? browserHostUrlIssue(String raw) {
  if (!kIsWeb) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'http') return null;
  final hostname = uri.host.toLowerCase();
  final loopback =
      hostname == 'localhost' ||
      hostname == '127.0.0.1' ||
      hostname == '::1' ||
      hostname.endsWith('.localhost');
  if (loopback) return null;
  return 'The web app requires an HTTPS host. Use Tailscale Serve or another trusted HTTPS/WSS endpoint.';
}
