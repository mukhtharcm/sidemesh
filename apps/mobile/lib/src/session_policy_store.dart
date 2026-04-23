import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Approval policies supported by Codex's ACP. Mirrors the values accepted
/// by the sidemesh server in `parseApprovalPolicy`.
enum ApprovalPolicy {
  /// Prompt for any untrusted command (Codex default).
  untrusted('untrusted', 'Ask when untrusted', 'Codex prompts before risky actions (default).'),
  onFailure('on-failure', 'Ask only on failure', 'Let Codex retry; only ask when the sandbox blocks.'),
  onRequest('on-request', 'Ask when requested', 'Codex runs freely; only pauses when it explicitly asks for approval.'),
  never('never', 'Never ask', 'Autopilot. Codex never prompts; requires a permissive sandbox.');

  const ApprovalPolicy(this.wire, this.label, this.description);

  final String wire;
  final String label;
  final String description;

  static ApprovalPolicy? fromWire(String? value) {
    if (value == null) return null;
    for (final p in ApprovalPolicy.values) {
      if (p.wire == value) return p;
    }
    return null;
  }
}

/// Sandbox modes supported by Codex. Mirrors `parseSandboxMode` on the server.
enum SandboxMode {
  readOnly('read-only', 'Read-only', 'Codex can read but not modify files or run commands.'),
  workspaceWrite(
    'workspace-write',
    'Workspace write',
    'Codex can edit files inside the session workspace and run tooling there.',
  ),
  dangerFullAccess(
    'danger-full-access',
    'Full access (danger)',
    'No sandbox. Codex can run anything on this machine — use with care.',
  );

  const SandboxMode(this.wire, this.label, this.description);

  final String wire;
  final String label;
  final String description;

  static SandboxMode? fromWire(String? value) {
    if (value == null) return null;
    for (final s in SandboxMode.values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// Local per-session overrides the user has pinned for approval/sandbox.
/// These are cached per `${hostId}:${sessionId}` and attached to every
/// outgoing `/input` message; Codex persists them on the thread via
/// `Op::OverrideTurnContext` the first time they arrive with a turn.
@immutable
class SessionPolicy {
  const SessionPolicy({this.approval, this.sandbox, this.networkAccess});

  final ApprovalPolicy? approval;
  final SandboxMode? sandbox;

  /// Optional outbound network toggle. Meaningful for `read-only` and
  /// `workspace-write`; `danger-full-access` always allows network regardless.
  final bool? networkAccess;

  bool get isEmpty =>
      approval == null && sandbox == null && networkAccess == null;

  SessionPolicy copyWith({
    Object? approval = _sentinel,
    Object? sandbox = _sentinel,
    Object? networkAccess = _sentinel,
  }) {
    return SessionPolicy(
      approval: identical(approval, _sentinel)
          ? this.approval
          : approval as ApprovalPolicy?,
      sandbox: identical(sandbox, _sentinel)
          ? this.sandbox
          : sandbox as SandboxMode?,
      networkAccess: identical(networkAccess, _sentinel)
          ? this.networkAccess
          : networkAccess as bool?,
    );
  }

  Map<String, Object> toJson() => {
    if (approval != null) 'approval': approval!.wire,
    if (sandbox != null) 'sandbox': sandbox!.wire,
    if (networkAccess != null) 'networkAccess': networkAccess!,
  };

  factory SessionPolicy.fromJson(Map<String, dynamic> json) => SessionPolicy(
    approval: ApprovalPolicy.fromWire(json['approval'] as String?),
    sandbox: SandboxMode.fromWire(json['sandbox'] as String?),
    networkAccess: json['networkAccess'] as bool?,
  );

  static const _sentinel = Object();
}

/// Persists per-session approval / sandbox overrides chosen by the user.
class SessionPolicyStore extends ChangeNotifier {
  SessionPolicyStore._();

  static final SessionPolicyStore instance = SessionPolicyStore._();
  static const _prefsKey = 'sidemesh_session_policies_v1';

  final Map<String, SessionPolicy> _policies = <String, SessionPolicy>{};
  bool _loaded = false;
  Future<void>? _loadFuture;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  SessionPolicy policyFor(HostProfile host, String sessionId) {
    return _policies[_keyFor(host.id, sessionId)] ?? const SessionPolicy();
  }

  Future<void> setPolicy(
    HostProfile host,
    String sessionId,
    SessionPolicy policy,
  ) async {
    await ensureLoaded();
    final key = _keyFor(host.id, sessionId);
    if (policy.isEmpty) {
      _policies.remove(key);
    } else {
      _policies[key] = policy;
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
            if (value is Map<String, dynamic>) {
              _policies[key] = SessionPolicy.fromJson(value);
            }
          });
        }
      } catch (_) {
        // Corrupt payload — ignore and start fresh.
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_policies.isEmpty) {
      await prefs.remove(_prefsKey);
      return;
    }
    final serialised = _policies.map((key, value) => MapEntry(key, value.toJson()));
    await prefs.setString(_prefsKey, jsonEncode(serialised));
  }

  String _keyFor(String hostId, String sessionId) => '$hostId:$sessionId';
}
