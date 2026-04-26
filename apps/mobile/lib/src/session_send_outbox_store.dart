import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class PendingSessionSend {
  const PendingSessionSend({
    required this.hostId,
    required this.hostFingerprint,
    required this.sessionId,
    required this.clientMessageId,
    required this.text,
    required this.inputItems,
    required this.message,
    required this.createdAt,
    required this.updatedAt,
    required this.nextAttemptAt,
    required this.retryCount,
    this.model,
    this.reasoningEffort,
    this.fastMode,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.lastError,
    this.blocked = false,
  });

  final String hostId;
  final String hostFingerprint;
  final String sessionId;
  final String clientMessageId;
  final String text;
  final List<SessionInputItem> inputItems;
  final SessionMessage message;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime nextAttemptAt;
  final int retryCount;
  final String? model;
  final String? reasoningEffort;
  final bool? fastMode;
  final String? approvalPolicy;
  final String? sandboxMode;
  final bool? networkAccess;
  final String? lastError;
  final bool blocked;

  String get key => '$hostId:$hostFingerprint:$sessionId:$clientMessageId';

  PendingSessionSend copyWith({
    String? hostFingerprint,
    DateTime? updatedAt,
    DateTime? nextAttemptAt,
    int? retryCount,
    String? lastError,
    bool clearLastError = false,
    bool? blocked,
  }) {
    return PendingSessionSend(
      hostId: hostId,
      hostFingerprint: hostFingerprint ?? this.hostFingerprint,
      sessionId: sessionId,
      clientMessageId: clientMessageId,
      text: text,
      inputItems: inputItems,
      message: message,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      retryCount: retryCount ?? this.retryCount,
      model: model,
      reasoningEffort: reasoningEffort,
      fastMode: fastMode,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      networkAccess: networkAccess,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      blocked: blocked ?? this.blocked,
    );
  }

  factory PendingSessionSend.fromJson(Map<String, dynamic> json) {
    return PendingSessionSend(
      hostId: _stringValue(json['hostId']),
      hostFingerprint: _stringValue(json['hostFingerprint']),
      sessionId: _stringValue(json['sessionId']),
      clientMessageId: _stringValue(json['clientMessageId']),
      text: _stringValue(json['text']),
      inputItems: (json['inputItems'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(SessionInputItem.fromJson)
          .toList(growable: false),
      message: SessionMessage.fromJson(
        json['message'] as Map<String, dynamic>? ?? const <String, dynamic>{},
      ),
      createdAt: _dateValue(json['createdAt']),
      updatedAt: _dateValue(json['updatedAt']),
      nextAttemptAt: _dateValue(json['nextAttemptAt']),
      retryCount: _intValue(json['retryCount']),
      model: _stringOrNull(json['model']),
      reasoningEffort: _stringOrNull(json['reasoningEffort']),
      fastMode: json['fastMode'] is bool ? json['fastMode'] as bool : null,
      approvalPolicy: _stringOrNull(json['approvalPolicy']),
      sandboxMode: _stringOrNull(json['sandboxMode']),
      networkAccess: json['networkAccess'] is bool
          ? json['networkAccess'] as bool
          : null,
      lastError: _stringOrNull(json['lastError']),
      blocked: json['blocked'] is bool ? json['blocked'] as bool : false,
    );
  }

  Map<String, dynamic> toJson() => {
    'hostId': hostId,
    'hostFingerprint': hostFingerprint,
    'sessionId': sessionId,
    'clientMessageId': clientMessageId,
    'text': text,
    'inputItems': inputItems.map((item) => item.toJson()).toList(),
    'message': message.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'nextAttemptAt': nextAttemptAt.millisecondsSinceEpoch,
    'retryCount': retryCount,
    'model': model,
    'reasoningEffort': reasoningEffort,
    'fastMode': fastMode,
    'approvalPolicy': approvalPolicy,
    'sandboxMode': sandboxMode,
    'networkAccess': networkAccess,
    'lastError': lastError,
    'blocked': blocked,
  };
}

class SessionSendOutboxStore extends ChangeNotifier {
  SessionSendOutboxStore._();

  static final SessionSendOutboxStore instance = SessionSendOutboxStore._();

  static const _key = 'sidemesh_pending_session_sends_v1';
  static const _maxEntries = 20;
  static const _maxEntryChars = 192 * 1024;
  static const _maxTotalChars = 512 * 1024;
  static const _ttl = Duration(days: 7);

  Future<void> _writeQueue = Future<void>.value();

  Future<List<PendingSessionSend>> loadForSession(
    HostProfile host,
    String sessionId,
  ) {
    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = await _loadAll(prefs);
      final fingerprint = hostFingerprint(host);
      final now = DateTime.now();
      final pruned = _prune(entries, now);
      if (pruned.length != entries.length) {
        await _saveAll(prefs, pruned);
      }
      return pruned
          .where(
            (entry) =>
                entry.hostId == host.id &&
                entry.hostFingerprint == fingerprint &&
                entry.sessionId == sessionId,
          )
          .toList(growable: false);
    });
  }

  Future<List<PendingSessionSend>> loadAll() {
    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = await _loadAll(prefs);
      final pruned = _prune(entries, DateTime.now());
      if (pruned.length != entries.length) {
        await _saveAll(prefs, pruned);
        notifyListeners();
      }
      return pruned;
    });
  }

  Future<bool> upsert(PendingSessionSend entry) async {
    final encodedEntry = jsonEncode(entry.toJson());
    if (utf8.encode(encodedEntry).length > _maxEntryChars) {
      return false;
    }

    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final entries = _prune(
        await _loadAll(prefs),
        now,
      ).where((item) => item.key != entry.key).toList(growable: true);
      entries.add(entry);
      entries.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
      while (entries.length > _maxEntries) {
        entries.removeLast();
      }
      final saved = await _saveAllWithinBudget(prefs, entries, entry.key);
      notifyListeners();
      return saved;
    });
  }

  Future<void> remove(PendingSessionSend entry) async {
    await removeFor(
      hostId: entry.hostId,
      hostFingerprint: entry.hostFingerprint,
      sessionId: entry.sessionId,
      clientMessageId: entry.clientMessageId,
    );
  }

  Future<void> removeFor({
    required String hostId,
    required String hostFingerprint,
    required String sessionId,
    required String clientMessageId,
  }) {
    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      final key = '$hostId:$hostFingerprint:$sessionId:$clientMessageId';
      final entries = (await _loadAll(
        prefs,
      )).where((item) => item.key != key).toList(growable: false);
      await _saveAll(prefs, entries);
      notifyListeners();
    });
  }

  Future<bool> contains(PendingSessionSend entry) {
    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = await _loadAll(prefs);
      return entries.any((item) => item.key == entry.key);
    });
  }

  Future<bool> replaceIfPresent(
    PendingSessionSend current,
    PendingSessionSend replacement,
  ) {
    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = await _loadAll(prefs);
      final index = entries.indexWhere((item) => item.key == current.key);
      if (index == -1) return false;
      final next = entries.toList(growable: true);
      next[index] = replacement;
      await _saveAllWithinBudget(prefs, next, replacement.key);
      notifyListeners();
      return true;
    });
  }

  Future<bool> attemptIfPresent({
    required PendingSessionSend entry,
    required Future<void> Function() attempt,
    required PendingSessionSend Function(Object error) recover,
  }) {
    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = await _loadAll(prefs);
      final index = entries.indexWhere((item) => item.key == entry.key);
      if (index == -1) return false;
      try {
        await attempt();
        final next = entries
            .where((item) => item.key != entry.key)
            .toList(growable: false);
        await _saveAll(prefs, next);
      } catch (error) {
        final replacement = recover(error);
        final next = entries.toList(growable: true);
        next[index] = replacement;
        await _saveAllWithinBudget(prefs, next, replacement.key);
      }
      notifyListeners();
      return true;
    });
  }

  Future<void> clearAll() {
    return _runExclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      notifyListeners();
    });
  }

  Future<T> _runExclusive<T>(Future<T> Function() action) async {
    final previous = _writeQueue;
    final completer = Completer<void>();
    _writeQueue = completer.future;
    await previous.catchError((_) {});
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  Future<List<PendingSessionSend>> _loadAll(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      return const <PendingSessionSend>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return const <PendingSessionSend>[];
      }
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PendingSessionSend.fromJson)
          .where(
            (entry) =>
                entry.hostId.isNotEmpty &&
                entry.hostFingerprint.isNotEmpty &&
                entry.sessionId.isNotEmpty &&
                entry.clientMessageId.isNotEmpty &&
                entry.message.id.isNotEmpty &&
                entry.inputItems.isNotEmpty,
          )
          .toList(growable: false);
    } catch (_) {
      await prefs.remove(_key);
      return const <PendingSessionSend>[];
    }
  }

  Future<bool> _saveAllWithinBudget(
    SharedPreferences prefs,
    List<PendingSessionSend> entries,
    String requiredKey,
  ) async {
    var next = entries;
    while (next.isNotEmpty) {
      final encoded = _encode(next);
      if (utf8.encode(encoded).length <= _maxTotalChars) {
        await prefs.setString(_key, encoded);
        return next.any((entry) => entry.key == requiredKey);
      }
      next = next.take(next.length - 1).toList(growable: false);
    }
    await prefs.remove(_key);
    return false;
  }

  Future<void> _saveAll(
    SharedPreferences prefs,
    List<PendingSessionSend> entries,
  ) async {
    if (entries.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, _encode(entries));
  }

  List<PendingSessionSend> _prune(
    List<PendingSessionSend> entries,
    DateTime now,
  ) {
    return entries
        .where((entry) => now.difference(entry.createdAt) <= _ttl)
        .toList(growable: false);
  }

  String _encode(List<PendingSessionSend> entries) {
    return jsonEncode(entries.map((entry) => entry.toJson()).toList());
  }

  static String hostFingerprint(HostProfile host) {
    final endpoint = _normalizedBaseUrl(host.baseUrl);
    return _stableHash('$endpoint\n${host.token}');
  }

  static String _normalizedBaseUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      return trimmed;
    }
    final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path == '/'
        ? ''
        : uri.path.replaceFirst(RegExp(r'/$'), '');
    return '$scheme://$host$port$path';
  }

  static String _stableHash(String input) {
    var fnv = 0x811c9dc5;
    var djb = 5381;
    for (final codeUnit in input.codeUnits) {
      fnv ^= codeUnit;
      fnv = (fnv * 0x01000193) & 0xffffffff;
      djb = (((djb << 5) + djb) ^ codeUnit) & 0xffffffff;
    }
    return '${fnv.toRadixString(16).padLeft(8, '0')}${djb.toRadixString(16).padLeft(8, '0')}';
  }
}

String _stringValue(Object? value) => value is String ? value : '';

String? _stringOrNull(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int _intValue(Object? value) => value is int ? value : 0;

DateTime _dateValue(Object? value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  return DateTime.now();
}
