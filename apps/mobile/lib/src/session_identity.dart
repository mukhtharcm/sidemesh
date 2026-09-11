import 'dart:convert';

class SessionAliases {
  const SessionAliases({
    required this.rawProviderId,
    required this.kinds,
    required this.aliases,
  });

  final String rawProviderId;
  final Map<String, String> kinds;
  final Map<String, String> aliases;

  static SessionAliases? fromJson(Object? value) {
    if (value is! Map || value['rawProviderId'] is! String ||
        value['kinds'] is! Map || value['aliases'] is! Map) {
      return null;
    }
    final kinds = value['kinds'] as Map;
    final aliases = value['aliases'] as Map;
    if (kinds.entries.any((entry) => entry.key is! String || entry.value is! String) ||
        aliases.entries.any((entry) => entry.key is! String || entry.value is! String)) {
      return null;
    }
    return SessionAliases(
      rawProviderId: value['rawProviderId'] as String,
      kinds: Map<String, String>.from(kinds),
      aliases: Map<String, String>.from(aliases),
    );
  }

  ({String sessionId, String providerId})? resolve(String id) {
    if (id.isEmpty) return null;
    final scoped = _unwrap(id);
    final providerId = scoped == null ? rawProviderId : aliases[scoped.providerId];
    if (providerId == null || !kinds.containsKey(providerId)) return null;
    return (sessionId: wrap(providerId, scoped?.rawId ?? id), providerId: providerId);
  }

  List<String> references(String id) {
    final resolved = resolve(id);
    if (resolved == null) return [id];
    final rawId = _unwrap(resolved.sessionId)!.rawId;
    return {
      resolved.sessionId,
      for (final entry in aliases.entries)
        if (entry.value == resolved.providerId) wrap(entry.key, rawId),
      if (resolved.providerId == rawProviderId) rawId,
    }.toList(growable: false);
  }

  static String wrap(String providerId, String rawId) =>
      '$providerId:${base64Url.encode(utf8.encode(rawId)).replaceAll('=', '')}';

  static ({String rawId, String providerId})? _unwrap(String id) {
    final separator = id.indexOf(':');
    if (separator <= 0) return null;
    final encoded = id.substring(separator + 1);
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) return null;
    try {
      final rawId = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      final providerId = id.substring(0, separator);
      if (rawId.isNotEmpty && wrap(providerId, rawId) == id) {
        return (rawId: rawId, providerId: providerId);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'rawProviderId': rawProviderId, 'kinds': kinds, 'aliases': aliases,
  };
}
