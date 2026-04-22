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

  Future<SessionLog> fetchLog(HostProfile host, String sessionId) async {
    final response = await _get(host, '/api/sessions/$sessionId/log');
    return SessionLog.fromJson(_decodeObject(response));
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
