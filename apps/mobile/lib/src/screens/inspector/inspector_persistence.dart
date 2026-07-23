import 'package:shared_preferences/shared_preferences.dart';

import 'inspector_controller.dart';

/// Per-session persistence of which inspector surface (if any) was last
/// open for a given session ownerKey. The value stored is the
/// [InspectorSurfaceKind.name]; absence means "closed".
class InspectorPersistence {
  // v1 persisted the automatically opened Files pane, so those values cannot
  // distinguish a user choice from the old default. v2 only records surfaces
  // that were deliberately opened.
  static const String _prefix = 'sidemesh.inspector.surface.v2.';
  static const String _legacyPrefix = 'sidemesh.inspector.surface.';

  static String _key(String ownerKey) => '$_prefix$ownerKey';
  static String _legacyKey(String ownerKey) => '$_legacyPrefix$ownerKey';

  /// Returns the persisted surface kind for [ownerKey], or null when no
  /// state has been saved (or the stored value is no longer recognised).
  static Future<InspectorSurfaceKind?> load(String ownerKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(_key(ownerKey));
      if (raw == null) {
        final legacyKey = _legacyKey(ownerKey);
        final legacy = prefs.getString(legacyKey);
        if (legacy != null) {
          await prefs.remove(legacyKey);
          // Files was the old automatic default. Transient and retired
          // surfaces were never valid restoration targets.
          const nonRestorable = {
            'fileBrowser',
            'sessionHub',
            'sessionControls',
            'browserPreview',
            'debug',
            'gitDetails',
            'sessionDetails',
          };
          if (!nonRestorable.contains(legacy)) {
            raw = legacy;
            await prefs.setString(_key(ownerKey), legacy);
          }
        }
      }
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
  static Future<void> save(String ownerKey, InspectorSurfaceKind? kind) async {
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
