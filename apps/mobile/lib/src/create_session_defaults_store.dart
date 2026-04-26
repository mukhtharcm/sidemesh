import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_policy_store.dart';

@immutable
class CreateSessionDefaults {
  const CreateSessionDefaults({
    this.approval = ApprovalPolicy.onRequest,
    this.sandbox = SandboxMode.workspaceWrite,
    this.fastMode = false,
    this.webSearch = false,
  });

  final ApprovalPolicy approval;
  final SandboxMode sandbox;
  final bool fastMode;
  final bool webSearch;

  static const CreateSessionDefaults factoryDefaults = CreateSessionDefaults();

  CreateSessionDefaults copyWith({
    ApprovalPolicy? approval,
    SandboxMode? sandbox,
    bool? fastMode,
    bool? webSearch,
  }) {
    return CreateSessionDefaults(
      approval: approval ?? this.approval,
      sandbox: sandbox ?? this.sandbox,
      fastMode: fastMode ?? this.fastMode,
      webSearch: webSearch ?? this.webSearch,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'approval': approval.wire,
    'sandbox': sandbox.wire,
    'fastMode': fastMode,
    'webSearch': webSearch,
  };

  factory CreateSessionDefaults.fromJson(Map<String, dynamic> json) {
    return CreateSessionDefaults(
      approval:
          ApprovalPolicy.fromWire(json['approval'] as String?) ??
          ApprovalPolicy.onRequest,
      sandbox:
          SandboxMode.fromWire(json['sandbox'] as String?) ??
          SandboxMode.workspaceWrite,
      fastMode: json['fastMode'] == true,
      webSearch: json['webSearch'] == true,
    );
  }
}

class CreateSessionDefaultsStore extends ChangeNotifier {
  CreateSessionDefaultsStore._();

  static final CreateSessionDefaultsStore instance =
      CreateSessionDefaultsStore._();

  static const _prefsKey = 'sidemesh_create_session_defaults_v1';

  CreateSessionDefaults _defaults = CreateSessionDefaults.factoryDefaults;
  bool _loaded = false;
  Future<void>? _loadFuture;

  CreateSessionDefaults get defaults => _defaults;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  Future<void> setDefaults(CreateSessionDefaults defaults) async {
    await ensureLoaded();
    _defaults = defaults;
    await _persist();
    notifyListeners();
  }

  Future<void> reset() async {
    await setDefaults(CreateSessionDefaults.factoryDefaults);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _defaults = CreateSessionDefaults.fromJson(decoded);
        }
      } catch (_) {
        _defaults = CreateSessionDefaults.factoryDefaults;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_defaults.toJson()));
  }

  @visibleForTesting
  void resetForTest() {
    _defaults = CreateSessionDefaults.factoryDefaults;
    _loaded = false;
    _loadFuture = null;
  }
}
