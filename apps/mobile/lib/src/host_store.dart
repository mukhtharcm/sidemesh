import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class HostStore {
  static const _hostsKey = 'sidemesh_hosts_v1';

  Future<List<HostProfile>> loadHosts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_hostsKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) {
      return [];
    }

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(HostProfile.fromJson)
        .toList()
      ..sort((left, right) => left.label.toLowerCase().compareTo(right.label.toLowerCase()));
  }

  Future<void> saveHosts(List<HostProfile> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = hosts.map((host) => host.toJson()).toList();
    await prefs.setString(_hostsKey, jsonEncode(payload));
  }
}
