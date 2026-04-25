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
    : _secure =
          secure ??
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
  static const _tokensBundleKey = 'sidemesh_host_tokens_v1';
  static const _migrationDoneKey = 'sidemesh_hosts_v2_migrated';
  static const _tokenConsolidationDoneKey = 'sidemesh_tokens_consolidated_v1';

  final FlutterSecureStorage _secure;

  // In-memory cache of the single keychain bundle. Populated on first read;
  // kept in sync with saveHosts(). Lets us avoid re-prompting mid-session if
  // the keychain ACL ever rejects "Always Allow" (e.g. after a code-sign
  // change).
  Map<String, String>? _tokenCache;

  Future<Map<String, String>> _readTokenBundle() async {
    final cached = _tokenCache;
    if (cached != null) return cached;
    final raw = await _secure.read(key: _tokensBundleKey);
    if (raw == null || raw.isEmpty) {
      _tokenCache = <String, String>{};
      return _tokenCache!;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _tokenCache = {
          for (final entry in decoded.entries)
            if (entry.value is String) entry.key: entry.value as String,
        };
        return _tokenCache!;
      }
    } catch (_) {
      // Malformed bundle — reset to empty, caller will rewrite on save.
    }
    _tokenCache = <String, String>{};
    return _tokenCache!;
  }

  Future<void> _writeTokenBundle(Map<String, String> tokens) async {
    _tokenCache = Map<String, String>.from(tokens);
    if (tokens.isEmpty) {
      await _secure.delete(key: _tokensBundleKey);
    } else {
      await _secure.write(key: _tokensBundleKey, value: jsonEncode(tokens));
    }
  }

  Future<List<HostProfile>> loadHosts() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyIfNeeded(prefs);
    await _consolidateTokensIfNeeded(prefs);

    final raw = prefs.getString(_hostsMetaKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) {
      return const [];
    }

    final tokens = await _readTokenBundle();
    final hosts = <HostProfile>[];
    for (final entry in decoded.whereType<Map<String, dynamic>>()) {
      final id = entry['id'] as String?;
      final label = entry['label'] as String?;
      final baseUrl = entry['baseUrl'] as String?;
      final enabled = entry['enabled'] != false;
      if (id == null || label == null || baseUrl == null) {
        continue;
      }
      hosts.add(
        HostProfile(
          id: id,
          label: label,
          baseUrl: baseUrl,
          token: tokens[id] ?? '',
          enabled: enabled,
        ),
      );
    }
    hosts.sort(
      (left, right) =>
          left.label.toLowerCase().compareTo(right.label.toLowerCase()),
    );
    return hosts;
  }

  Future<void> saveHosts(List<HostProfile> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    final metadata = hosts
        .map(
          (host) => {
            'id': host.id,
            'label': host.label,
            'baseUrl': host.baseUrl,
            'enabled': host.enabled,
          },
        )
        .toList();
    await prefs.setString(_hostsMetaKey, jsonEncode(metadata));

    final keepIds = hosts.map((host) => host.id).toSet();
    final tokens = <String, String>{
      for (final host in hosts)
        if (host.token.isNotEmpty) host.id: host.token,
    };
    await _writeTokenBundle(tokens);

    // Best-effort cleanup of any stale per-id items left over from the old
    // scheme. Ignore failures — the consolidation flag ensures we won't try
    // again on next launch.
    for (final id in keepIds) {
      try {
        await _secure.delete(key: '$_tokenKeyPrefix$id');
      } catch (_) {}
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
        final tokens = await _readTokenBundle();
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
            tokens[id] = token;
          }
        }
        await _writeTokenBundle(tokens);
        await prefs.setString(_hostsMetaKey, jsonEncode(metadata));
      }
    } catch (_) {
      // Ignore malformed legacy payloads; migration flag will still flip so
      // we never retry.
    }

    await prefs.remove(_legacyHostsKey);
    await prefs.setBool(_migrationDoneKey, true);
  }

  /// One-shot migration from the old per-host keychain entries
  /// (`sidemesh_host_token_<id>`) to the consolidated bundle. Each legacy
  /// item read here triggers its own keychain prompt exactly once; after the
  /// flag flips we never touch those keys again.
  Future<void> _consolidateTokensIfNeeded(SharedPreferences prefs) async {
    if (prefs.getBool(_tokenConsolidationDoneKey) == true) {
      return;
    }

    final metaRaw = prefs.getString(_hostsMetaKey);
    final ids = <String>[];
    if (metaRaw != null && metaRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(metaRaw);
        if (decoded is List<dynamic>) {
          for (final entry in decoded.whereType<Map<String, dynamic>>()) {
            final id = entry['id'];
            if (id is String) ids.add(id);
          }
        }
      } catch (_) {}
    }

    if (ids.isEmpty) {
      await prefs.setBool(_tokenConsolidationDoneKey, true);
      return;
    }

    try {
      final tokens = await _readTokenBundle();
      var changed = false;
      for (final id in ids) {
        if (tokens.containsKey(id)) continue;
        final legacy = await _secure.read(key: '$_tokenKeyPrefix$id');
        if (legacy != null && legacy.isNotEmpty) {
          tokens[id] = legacy;
          changed = true;
        }
      }
      if (changed) {
        await _writeTokenBundle(tokens);
      }
      for (final id in ids) {
        try {
          await _secure.delete(key: '$_tokenKeyPrefix$id');
        } catch (_) {}
      }
      await prefs.setBool(_tokenConsolidationDoneKey, true);
    } catch (_) {
      // Leave the flag unset so we retry on next launch; but don't crash
      // the app if the keychain is temporarily unavailable.
    }
  }
}
