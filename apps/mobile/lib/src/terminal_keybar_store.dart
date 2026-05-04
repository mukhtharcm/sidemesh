import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_key_models.dart';

class TerminalKeyBarStore extends ChangeNotifier {
  TerminalKeyBarStore._();

  static final TerminalKeyBarStore instance = TerminalKeyBarStore._();
  static const _prefsKey = 'sidemesh_terminal_keybar_v1';

  int _selectedCategoryIndex = 0;
  List<TerminalKeyCategory>? _customCategories;
  bool _loaded = false;
  Future<void>? _loadFuture;

  int get selectedCategoryIndex => _selectedCategoryIndex;

  List<TerminalKeyCategory> get categories =>
      _customCategories ?? defaultTerminalKeyCategories();

  bool get hasCustomCategories => _customCategories != null;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  Future<void> setSelectedCategoryIndex(int index) async {
    await ensureLoaded();
    if (_selectedCategoryIndex == index) return;
    _selectedCategoryIndex = index;
    await _persist();
    notifyListeners();
  }

  Future<void> setCustomCategories(List<TerminalKeyCategory>? categories) async {
    await ensureLoaded();
    _customCategories = categories;
    await _persist();
    notifyListeners();
  }

  Future<void> resetToDefaults() async {
    await setCustomCategories(null);
    await setSelectedCategoryIndex(0);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _selectedCategoryIndex = (decoded['selectedCategoryIndex'] as int?) ?? 0;
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
      'selectedCategoryIndex': _selectedCategoryIndex,
      if (_customCategories != null)
        'categories': _customCategories!.map((c) => c.toJson()).toList(),
    };
    await prefs.setString(_prefsKey, jsonEncode(payload));
  }

  @visibleForTesting
  void resetForTest() {
    _selectedCategoryIndex = 0;
    _customCategories = null;
    _loaded = false;
    _loadFuture = null;
  }
}
