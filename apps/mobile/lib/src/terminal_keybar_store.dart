import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_key_models.dart';

class TerminalKeyBarStore extends ChangeNotifier {
  TerminalKeyBarStore._();

  static final TerminalKeyBarStore instance = TerminalKeyBarStore._();
  static const _prefsKey = 'sidemesh_terminal_keybar_v1';

  List<TerminalKeyCategory>? _customCategories;
  bool _loaded = false;
  Future<void>? _loadFuture;

  List<TerminalKeyCategory> get categories =>
      _customCategories ?? defaultTerminalKeyCategories();

  bool get hasCustomCategories => _customCategories != null;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  Future<void> setCustomCategories(List<TerminalKeyCategory>? categories) async {
    await ensureLoaded();
    _customCategories = categories;
    await _persist();
    notifyListeners();
  }

  Future<void> resetToDefaults() async {
    await setCustomCategories(null);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final categoriesJson = decoded['categories'];
        if (categoriesJson is List<dynamic>) {
          _customCategories = categoriesJson
              .cast<Map<String, dynamic>>()
              .map(TerminalKeyCategory.fromJson)
              .toList();
        }
      } catch (_) {
        // Corrupt payload — ignore and start fresh.
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, Object>{
      if (_customCategories != null)
        'categories': _customCategories!.map((c) => c.toJson()).toList(),
    };
    await prefs.setString(_prefsKey, jsonEncode(payload));
  }

  @visibleForTesting
  void resetForTest() {
    _customCategories = null;
    _loaded = false;
    _loadFuture = null;
  }
}
