import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'models.dart';
import 'session_identity_store.dart';

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
    this.mode,
    this.reasoningEffort,
    this.fastMode,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.accessMode,
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
  final String? mode;
  final String? reasoningEffort;
  final bool? fastMode;
  final String? approvalPolicy;
  final String? sandboxMode;
  final bool? networkAccess;
  final String? accessMode;
  final String? lastError;
  final bool blocked;

  String get key => jsonEncode([hostId, hostFingerprint, sessionId, clientMessageId]);

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
      mode: mode,
      reasoningEffort: reasoningEffort,
      fastMode: fastMode,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      networkAccess: networkAccess,
      accessMode: accessMode,
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
      mode: _stringOrNull(json['mode']),
      reasoningEffort: _stringOrNull(json['reasoningEffort']),
      fastMode: json['fastMode'] is bool ? json['fastMode'] as bool : null,
      approvalPolicy: _stringOrNull(json['approvalPolicy']),
      sandboxMode: _stringOrNull(json['sandboxMode']),
      networkAccess: json['networkAccess'] is bool
          ? json['networkAccess'] as bool
          : null,
      accessMode: _stringOrNull(json['accessMode']),
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
    'mode': mode,
    'reasoningEffort': reasoningEffort,
    'fastMode': fastMode,
    'approvalPolicy': approvalPolicy,
    'sandboxMode': sandboxMode,
    'networkAccess': networkAccess,
    'accessMode': accessMode,
    'lastError': lastError,
    'blocked': blocked,
  };
}

class SessionSendOutboxStore extends ChangeNotifier {
  SessionSendOutboxStore._();

  static final SessionSendOutboxStore instance = SessionSendOutboxStore._();

  static const _key = 'sidemesh_pending_session_sends_v1';
  static const _migration = 'session-outbox-prefs-v1';
  static const _maxEntries = 20;
  static const _maxEntryBytes = 192 * 1024;
  static const _maxTotalBytes = 512 * 1024;
  static const _identityWhere =
      'host_id = ? AND host_fingerprint = ? AND session_id = ? AND client_message_id = ?';

  Future<List<PendingSessionSend>> loadForSession(
    HostProfile host,
    String sessionId,
  ) async {
    final db = await _database();
    await SessionIdentityStore.instance.ensureLoaded();
    final ids = SessionIdentityStore.instance.references(host.id, sessionId);
    final rows = await db.query(
      'session_outbox',
      where: 'host_id = ? AND host_fingerprint = ? AND session_id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [host.id, hostFingerprint(host), ...ids],
    );
    return _decodeRows(rows);
  }

  Future<List<PendingSessionSend>> loadAll() async {
    final db = await _database();
    return _decodeRows(await db.query('session_outbox'));
  }

  Future<bool> upsert(PendingSessionSend entry) async {
    final db = await _database();
    final saved = await db.transaction((txn) => _save(txn, entry));
    if (saved) notifyListeners();
    return saved;
  }

  Future<void> remove(PendingSessionSend entry) => removeFor(
    hostId: entry.hostId,
    hostFingerprint: entry.hostFingerprint,
    sessionId: entry.sessionId,
    clientMessageId: entry.clientMessageId,
  );

  Future<void> removeFor({
    required String hostId,
    required String hostFingerprint,
    required String sessionId,
    required String clientMessageId,
  }) async {
    final db = await _database();
    await SessionIdentityStore.instance.ensureLoaded();
    final ids = SessionIdentityStore.instance.references(hostId, sessionId);
    final removed = await db.delete(
      'session_outbox',
      where: 'host_id = ? AND host_fingerprint = ? AND client_message_id = ? AND session_id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [hostId, hostFingerprint, clientMessageId, ...ids],
    );
    if (removed > 0) notifyListeners();
  }

  Future<bool> contains(PendingSessionSend entry) async {
    final db = await _database();
    return _contains(db, entry);
  }

  Future<bool> replaceIfPresent(
    PendingSessionSend current,
    PendingSessionSend replacement,
  ) async {
    final db = await _database();
    final saved = await db.transaction((txn) async {
      if (!await _contains(txn, current)) return false;
      if (current.key != replacement.key && await _contains(txn, replacement)) {
        return false;
      }
      if (!await _save(txn, replacement, replacing: current)) return false;
      if (current.key != replacement.key) {
        await txn.delete('session_outbox',
          where: _identityWhere, whereArgs: _identity(current));
      }
      return true;
    });
    if (saved) notifyListeners();
    return saved;
  }

  Future<void> clearAll() async {
    final db = await SidemeshDb.instance;
    await db.transaction((txn) async {
      await txn.delete('session_outbox');
      // Keep the import marker so an explicit discard cannot restore a backup.
      await txn.insert('client_migrations', {'name': _migration},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    });
    notifyListeners();
  }


  Future<Database> _database() async {
    final db = await SidemeshDb.instance;
    if ((await db.query('client_migrations',
      where: 'name = ?', whereArgs: [_migration])).isNotEmpty) {
      return db;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    await db.transaction((txn) async {
      if ((await txn.query('client_migrations',
        where: 'name = ?', whereArgs: [_migration])).isNotEmpty) {
        return;
      }
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is! List) {
          throw const FormatException('Cannot read saved pending messages.');
        }
        for (final item in decoded) {
          final entry = _decodeEntry(item);
          // Preserve every pending message, including old entries over the limit.
          await txn.insert('session_outbox', _row(entry, jsonEncode(item)));
        }
      }
      await txn.insert('client_migrations', {'name': _migration});
    });
    return db;
  }

  Future<bool> _save(
    DatabaseExecutor db,
    PendingSessionSend entry, {
    PendingSessionSend? replacing,
  }) async {
    final encoded = jsonEncode(entry.toJson());
    _decodeEntry(entry.toJson());
    final size = utf8.encode(encoded).length;
    if (size > _maxEntryBytes) return false;
    final totals = (await db.rawQuery(
      'SELECT COUNT(*) AS count, COALESCE(SUM(length(CAST(payload AS BLOB))), 0) AS bytes '
      'FROM session_outbox WHERE NOT ($_identityWhere)',
      _identity(replacing ?? entry),
    )).single;
    if ((totals['count'] as int) >= _maxEntries ||
        (totals['bytes'] as int) + size > _maxTotalBytes) {
      return false;
    }
    await db.insert('session_outbox', _row(entry, encoded),
      conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  Future<bool> _contains(DatabaseExecutor db, PendingSessionSend entry) async {
    return (await db.query('session_outbox', columns: ['client_message_id'],
      where: _identityWhere, whereArgs: _identity(entry))).isNotEmpty;
  }

  List<String> _identity(PendingSessionSend entry) => [
    entry.hostId, entry.hostFingerprint, entry.sessionId, entry.clientMessageId,
  ];

  Map<String, Object?> _row(PendingSessionSend entry, String payload) => {
    'host_id': entry.hostId,
    'host_fingerprint': entry.hostFingerprint,
    'session_id': entry.sessionId,
    'client_message_id': entry.clientMessageId,
    'payload': payload,
  };

  List<PendingSessionSend> _decodeRows(List<Map<String, Object?>> rows) {
    final entries = rows.map((row) {
      final entry = _decodeEntry(jsonDecode(row['payload'] as String));
      if (row['host_id'] != entry.hostId || row['host_fingerprint'] != entry.hostFingerprint ||
          row['session_id'] != entry.sessionId || row['client_message_id'] != entry.clientMessageId) {
        throw const FormatException('Saved pending message identity does not match its record.');
      }
      return entry;
    }).toList();
    entries.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return entries;
  }

  PendingSessionSend _decodeEntry(Object? json) {
    if (json is! Map<String, dynamic> || json['inputItems'] is! List ||
        (json['inputItems'] as List).any((item) => item is! Map<String, dynamic>)) {
      throw const FormatException('Cannot read saved pending message.');
    }
    final entry = PendingSessionSend.fromJson(json);
    if (entry.hostId.isEmpty || entry.hostFingerprint.isEmpty ||
        entry.sessionId.isEmpty || entry.clientMessageId.isEmpty ||
        entry.message.id.isEmpty || entry.inputItems.isEmpty ||
        entry.inputItems.any((item) => switch (item.type) {
          'text' => item.text == null,
          'image' => item.url == null || item.url!.isEmpty,
          'localImage' || 'file' => item.path == null || item.path!.isEmpty,
          'skill' => item.name == null || item.name!.isEmpty || item.path == null || item.path!.isEmpty,
          _ => true,
        })) {
      throw const FormatException('Saved pending message has no identity or input.');
    }
    return entry;
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
