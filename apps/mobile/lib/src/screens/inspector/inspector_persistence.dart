import 'package:shared_preferences/shared_preferences.dart';

import 'inspector_controller.dart';

/// Per-session persistence of which inspector surface (if any) was last
/// open for a given session ownerKey. The value stored is the
/// [InspectorSurfaceKind.name]; absence means "closed".
class InspectorPersistence {
  static const String _prefix = 'sidemesh.inspector.surface.';

  static String _key(String ownerKey) => '$_prefix$ownerKey';

  /// Returns the persisted surface kind for [ownerKey], or null when no
  /// state has been saved (or the stored value is no longer recognised).
  static Future<InspectorSurfaceKind?> load(String ownerKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(ownerKey));
      if (raw == null) return null;
      for (final kind in InspectorSurfaceKind.values) {
        if (kind.name == raw) return kind;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Saves [kind] for [ownerKey]; passing null removes the entry.
  static Future<void> save(
    String ownerKey,
    InspectorSurfaceKind? kind,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(ownerKey);
      if (kind == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, kind.name);
      }
    } catch (_) {
      // Best-effort persistence.
    }
  }
}
