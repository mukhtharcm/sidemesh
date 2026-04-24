import 'models.dart';

class SessionMessageSeedStore {
  SessionMessageSeedStore._();

  static final SessionMessageSeedStore instance = SessionMessageSeedStore._();

  final Map<String, List<SessionMessage>> _messages =
      <String, List<SessionMessage>>{};

  void put(HostProfile host, String sessionId, SessionMessage message) {
    final key = _keyFor(host, sessionId);
    _messages[key] = [...?_messages[key], message];
  }

  List<SessionMessage> take(HostProfile host, String sessionId) {
    return _messages.remove(_keyFor(host, sessionId)) ??
        const <SessionMessage>[];
  }

  String _keyFor(HostProfile host, String sessionId) => '${host.id}:$sessionId';
}
