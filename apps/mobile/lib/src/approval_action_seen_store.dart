import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ApprovalActionSeenSnapshot {
  const ApprovalActionSeenSnapshot({
    required this.keys,
    required this.initialized,
  });

  final Set<String> keys;
  final bool initialized;
}

class ApprovalActionSeenStore {
  ApprovalActionSeenStore._();

  static final ApprovalActionSeenStore instance = ApprovalActionSeenStore._();

  static const _keysKey = 'sidemesh_seen_approval_keys_v1';
  static const _initializedKey = 'sidemesh_seen_approval_keys_initialized_v1';

  Future<ApprovalActionSeenSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ApprovalActionSeenSnapshot(
      keys: (prefs.getStringList(_keysKey) ?? const <String>[]).toSet(),
      initialized: prefs.getBool(_initializedKey) ?? false,
    );
  }

  Future<void> replace(Set<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = keys.toList()..sort();
    await prefs.setStringList(_keysKey, sorted);
    await prefs.setBool(_initializedKey, true);
  }

  String keyFor(HostProfile host, PendingAction action) {
    return '${host.id}:${action.id}';
  }
}
