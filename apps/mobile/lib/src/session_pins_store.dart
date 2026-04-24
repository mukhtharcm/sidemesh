import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

@immutable
class PinnedSessionMessage {
  const PinnedSessionMessage({
    required this.messageId,
    required this.role,
    required this.text,
    required this.textTruncated,
    required this.attachmentCount,
    required this.createdAt,
    required this.pinnedAt,
    required this.seq,
    this.phase,
  });

  static const int maxStoredTextLength = 6000;

  final String messageId;
  final String role;
  final String text;
  final bool textTruncated;
  final int attachmentCount;
  final DateTime createdAt;
  final DateTime pinnedAt;
  final int seq;
  final String? phase;

  bool get hasText => text.trim().isNotEmpty;

  String get roleLabel {
    if (role == 'assistant') return 'Assistant';
    if (role == 'user') return 'You';
    return role.isEmpty ? 'Message' : role;
  }

  String get preview {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isNotEmpty) {
      return compact.length <= 180
          ? compact
          : '${compact.substring(0, 180)}...';
    }
    if (attachmentCount == 1) return '1 attachment';
    if (attachmentCount > 1) return '$attachmentCount attachments';
    return 'Pinned message';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'messageId': messageId,
    'role': role,
    'text': text,
    'textTruncated': textTruncated,
    'attachmentCount': attachmentCount,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'pinnedAt': pinnedAt.millisecondsSinceEpoch,
    'seq': seq,
    if (phase != null) 'phase': phase,
  };

  factory PinnedSessionMessage.fromMessage(SessionMessage message) {
    final rawText = message.text.trim();
    final textTruncated = rawText.length > maxStoredTextLength;
    return PinnedSessionMessage(
      messageId: message.id,
      role: message.role,
      text: textTruncated ? rawText.substring(0, maxStoredTextLength) : rawText,
      textTruncated: textTruncated,
      attachmentCount: message.attachments.length,
      createdAt: message.createdAt,
      pinnedAt: DateTime.now(),
      seq: message.seq,
      phase: message.phase,
    );
  }

  factory PinnedSessionMessage.fromJson(Map<String, dynamic> json) =>
      PinnedSessionMessage(
        messageId: _stringValue(json['messageId']),
        role: _stringValue(json['role']),
        text: _stringValue(json['text']),
        textTruncated: _boolValue(json['textTruncated']),
        attachmentCount: _intValue(json['attachmentCount']),
        createdAt: _dateValue(json['createdAt']),
        pinnedAt: _dateValue(json['pinnedAt']),
        seq: _intValue(json['seq']),
        phase: _stringOrNull(json['phase']),
      );
}

class SessionPinsStore extends ChangeNotifier {
  SessionPinsStore._();

  static final SessionPinsStore instance = SessionPinsStore._();
  static const _prefsKey = 'sidemesh_session_message_pins_v1';
  static const _maxPinsPerSession = 30;

  final Map<String, List<PinnedSessionMessage>> _pinsBySession =
      <String, List<PinnedSessionMessage>>{};
  bool _loaded = false;
  Future<void>? _loadFuture;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  List<PinnedSessionMessage> pinsFor(HostProfile host, String sessionId) {
    final pins = _pinsBySession[_keyFor(host.id, sessionId)];
    if (pins == null || pins.isEmpty) {
      return const <PinnedSessionMessage>[];
    }
    return List<PinnedSessionMessage>.unmodifiable(pins);
  }

  bool isPinned(HostProfile host, String sessionId, String messageId) {
    return _pinsBySession[_keyFor(host.id, sessionId)]?.any(
          (pin) => pin.messageId == messageId,
        ) ??
        false;
  }

  Future<bool> togglePin(
    HostProfile host,
    String sessionId,
    SessionMessage message,
  ) async {
    await ensureLoaded();
    if (isPinned(host, sessionId, message.id)) {
      await unpin(host, sessionId, message.id);
      return false;
    }
    await pin(host, sessionId, message);
    return true;
  }

  Future<void> pin(
    HostProfile host,
    String sessionId,
    SessionMessage message,
  ) async {
    await ensureLoaded();
    final key = _keyFor(host.id, sessionId);
    final next = [
      PinnedSessionMessage.fromMessage(message),
      ...?_pinsBySession[key]?.where((pin) => pin.messageId != message.id),
    ].take(_maxPinsPerSession).toList(growable: false);
    _pinsBySession[key] = next;
    await _persist();
    notifyListeners();
  }

  Future<void> unpin(
    HostProfile host,
    String sessionId,
    String messageId,
  ) async {
    await ensureLoaded();
    final key = _keyFor(host.id, sessionId);
    final current = _pinsBySession[key];
    if (current == null) return;
    final next = current
        .where((pin) => pin.messageId != messageId)
        .toList(growable: false);
    if (next.isEmpty) {
      _pinsBySession.remove(key);
    } else {
      _pinsBySession[key] = next;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((key, value) {
            if (value is! List<dynamic>) return;
            final pins = value
                .whereType<Map<String, dynamic>>()
                .map(PinnedSessionMessage.fromJson)
                .toList(growable: false);
            if (pins.isNotEmpty) {
              _pinsBySession[key] = _sortedPins(pins);
            }
          });
        }
      } catch (_) {
        // Corrupt local pin state should not block opening sessions.
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_pinsBySession.isEmpty) {
      await prefs.remove(_prefsKey);
      return;
    }
    final serialised = _pinsBySession.map(
      (key, value) => MapEntry(
        key,
        _sortedPins(value).map((pin) => pin.toJson()).toList(growable: false),
      ),
    );
    await prefs.setString(_prefsKey, jsonEncode(serialised));
  }

  List<PinnedSessionMessage> _sortedPins(List<PinnedSessionMessage> pins) {
    final sorted = [...pins];
    sorted.sort((left, right) => right.pinnedAt.compareTo(left.pinnedAt));
    return sorted.take(_maxPinsPerSession).toList(growable: false);
  }

  String _keyFor(String hostId, String sessionId) => '$hostId:$sessionId';
}

String _stringValue(Object? value) => value == null ? '' : value.toString();

String? _stringOrNull(Object? value) {
  final string = value?.toString().trim();
  return string == null || string.isEmpty ? null : string;
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _boolValue(Object? value) => value == true || value == 'true';

DateTime _dateValue(Object? value) {
  final ms = _intValue(value);
  if (ms <= 0) return DateTime.fromMillisecondsSinceEpoch(0);
  return DateTime.fromMillisecondsSinceEpoch(ms);
}
