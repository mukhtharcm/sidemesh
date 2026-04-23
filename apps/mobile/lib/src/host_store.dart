import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persists the list of known Sidemesh hosts.
///
/// Non-sensitive metadata (id / label / baseUrl) is stored in
/// [SharedPreferences]. Bearer tokens live in
/// [flutter_secure_storage.FlutterSecureStorage] so they are encrypted by the
/// platform keystore / keychain. On first run we transparently migrate any
/// existing v1 blob.
class HostStore {
  HostStore({FlutterSecureStorage? secure})
      : _secure = secure ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              // The macOS Data Protection Keychain needs a team-signed
              // `com.apple.application-identifier` entitlement, which ad-hoc
              // signed dev builds don't carry; using the legacy file-based
              // keychain works without any signing setup.
              mOptions: MacOsOptions(useDataProtectionKeyChain: false),
            );

  static const _legacyHostsKey = 'sidemesh_hosts_v1';
  static const _hostsMetaKey = 'sidemesh_hosts_v2';
  static const _tokenKeyPrefix = 'sidemesh_host_token_';
  static const _migrationDoneKey = 'sidemesh_hosts_v2_migrated';

  final FlutterSecureStorage _secure;

  Future<List<HostProfile>> loadHosts() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyIfNeeded(prefs);

    final raw = prefs.getString(_hostsMetaKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) {
      return const [];
    }

    final hosts = <HostProfile>[];
    for (final entry in decoded.whereType<Map<String, dynamic>>()) {
      final id = entry['id'] as String?;
      final label = entry['label'] as String?;
      final baseUrl = entry['baseUrl'] as String?;
      if (id == null || label == null || baseUrl == null) {
        continue;
      }
      final token = await _secure.read(key: '$_tokenKeyPrefix$id') ?? '';
      hosts.add(HostProfile(
        id: id,
        label: label,
        baseUrl: baseUrl,
        token: token,
      ));
    }
    hosts.sort((left, right) =>
        left.label.toLowerCase().compareTo(right.label.toLowerCase()));
    return hosts;
  }

  Future<void> saveHosts(List<HostProfile> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    final metadata = hosts
        .map((host) => {
              'id': host.id,
              'label': host.label,
              'baseUrl': host.baseUrl,
            })
        .toList();
    await prefs.setString(_hostsMetaKey, jsonEncode(metadata));

    final previousRaw = prefs.getString(_hostsMetaKey);
    final previousIds = <String>{};
    if (previousRaw != null && previousRaw.isNotEmpty) {
      final decoded = jsonDecode(previousRaw);
      if (decoded is List<dynamic>) {
        for (final entry in decoded.whereType<Map<String, dynamic>>()) {
          final id = entry['id'];
          if (id is String) {
            previousIds.add(id);
          }
        }
      }
    }

    final keepIds = hosts.map((host) => host.id).toSet();
    for (final host in hosts) {
      await _secure.write(
        key: '$_tokenKeyPrefix${host.id}',
        value: host.token,
      );
    }
    for (final id in previousIds.difference(keepIds)) {
      await _secure.delete(key: '$_tokenKeyPrefix$id');
    }
  }

  Future<void> _migrateLegacyIfNeeded(SharedPreferences prefs) async {
    if (prefs.getBool(_migrationDoneKey) == true) {
      return;
    }
    final legacyRaw = prefs.getString(_legacyHostsKey);
    if (legacyRaw == null || legacyRaw.isEmpty) {
      await prefs.setBool(_migrationDoneKey, true);
      return;
    }

    try {
      final decoded = jsonDecode(legacyRaw);
      if (decoded is List<dynamic>) {
        final metadata = <Map<String, dynamic>>[];
        for (final entry in decoded.whereType<Map<String, dynamic>>()) {
          final id = entry['id'] as String?;
          final label = entry['label'] as String?;
          final baseUrl = entry['baseUrl'] as String?;
          final token = entry['token'] as String?;
          if (id == null || label == null || baseUrl == null) {
            continue;
          }
          metadata.add({'id': id, 'label': label, 'baseUrl': baseUrl});
          if (token != null && token.isNotEmpty) {
            await _secure.write(
              key: '$_tokenKeyPrefix$id',
              value: token,
            );
          }
        }
        await prefs.setString(_hostsMetaKey, jsonEncode(metadata));
      }
    } catch (_) {
      // Ignore malformed legacy payloads; migration flag will still flip so
      // we never retry.
    }

    await prefs.remove(_legacyHostsKey);
    await prefs.setBool(_migrationDoneKey, true);
  }
}
