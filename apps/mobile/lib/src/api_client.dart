import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

import 'models.dart';

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<NodeInfo> fetchNode(HostProfile host) async {
    final response = await _get(host, '/api/node');
    return NodeInfo.fromJson(_decodeObject(response));
  }

  Future<List<WorkspaceSummary>> fetchWorkspaces(HostProfile host) async {
    final response = await _get(host, '/api/workspaces');
    return _decodeList(response).map(WorkspaceSummary.fromJson).toList();
  }

  Future<List<SessionSummary>> fetchSessions(
    HostProfile host, {
    int? limit,
  }) async {
    final response = await _get(
      host,
      '/api/sessions',
      queryParameters: limit == null ? null : {'limit': '$limit'},
    );
    return _decodeList(response).map(SessionSummary.fromJson).toList();
  }

  Future<List<PendingAction>> fetchPendingActions(HostProfile host) async {
    final response = await _get(host, '/api/actions');
    return _decodeList(response).map(PendingAction.fromJson).toList();
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
    );
    return SessionLog.fromJson(_decodeObject(response));
  }

  Future<SessionEventsDelta> fetchEvents(
    HostProfile host,
    String sessionId, {
    required int since,
  }) async {
    final response = await _get(
      host,
      '/api/sessions/$sessionId/events',
      queryParameters: {'since': '$since'},
    );
    return SessionEventsDelta.fromJson(_decodeObject(response));
  }

  Future<SessionStatus> fetchStatus(HostProfile host, String sessionId) async {
    final response = await _get(host, '/api/sessions/$sessionId/status');
    return SessionStatus.fromJson(_decodeObject(response));
  }

  Future<SessionSummary> createSession(
    HostProfile host, {
    required String cwd,
    required String prompt,
    String? model,
    String? approvalPolicy,
    String? sandboxMode,
    String? webSearch,
    String? profile,
  }) async {
    final body = <String, dynamic>{'cwd': cwd, 'prompt': prompt};
    if ((model ?? '').isNotEmpty) {
      body['model'] = model;
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
    final response = await _post(host, '/api/sessions/create', body: body);
    final payload = _decodeObject(response);
    return SessionSummary.fromJson(payload['session'] as Map<String, dynamic>);
  }

  Future<void> sendInput(
    HostProfile host, {
    required String sessionId,
    required String text,
    String? clientMessageId,
  }) async {
    await _post(
      host,
      '/api/sessions/$sessionId/input',
      body: {'text': text, 'clientMessageId': clientMessageId},
    );
  }

  Future<void> stopSession(HostProfile host, String sessionId) async {
    await _post(host, '/api/sessions/$sessionId/stop', body: const {});
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
    );
    final payload = _decodeObject(response);
    return SessionSummary.fromJson(payload['session'] as Map<String, dynamic>);
  }

  Future<void> archiveSession(HostProfile host, String sessionId) async {
    await _post(host, '/api/sessions/$sessionId/archive', body: const {});
  }

  Future<void> unarchiveSession(HostProfile host, String sessionId) async {
    await _post(host, '/api/sessions/$sessionId/unarchive', body: const {});
  }

  Future<void> respondToAction(
    HostProfile host, {
    required String actionId,
    required String decision,
  }) async {
    await _post(
      host,
      '/api/actions/$actionId/respond',
      body: {'decision': decision},
    );
  }

  IOWebSocketChannel openLive(HostProfile host, String sessionId) {
    final baseUri = Uri.parse(host.baseUrl);
    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/live',
      queryParameters: {'sessionId': sessionId},
    );

    return IOWebSocketChannel.connect(
      wsUri,
      headers: {'Authorization': 'Bearer ${host.token}'},
    );
  }

  Future<http.Response> _get(
    HostProfile host,
    String path, {
    Map<String, String>? queryParameters,
  }) {
    return _client.get(
      _uri(host, path, queryParameters: queryParameters),
      headers: _headers(host),
    );
  }

  Future<http.Response> _post(
    HostProfile host,
    String path, {
    required Map<String, dynamic> body,
  }) {
    return _client.post(
      _uri(host, path),
      headers: _headers(host),
      body: jsonEncode(body),
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

  Map<String, String> _headers(HostProfile host) => {
    'Authorization': 'Bearer ${host.token}',
    'Content-Type': 'application/json',
  };

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

/// Turns low-level errors (ApiException, SocketException, TimeoutException)
/// into short human-readable strings suitable for snackbars.
String friendlyError(Object error) {
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
  final trimmed = text.replaceFirst('Exception: ', '');
  return trimmed.length > 160 ? '${trimmed.substring(0, 157)}…' : trimmed;
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
