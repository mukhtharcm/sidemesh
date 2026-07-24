import 'dart:convert';

class PairingPayload {
  const PairingPayload({
    required this.label,
    required this.baseUrl,
    required this.token,
    required this.addresses,
  });

  final String label;
  final String baseUrl;
  final String token;
  final List<String> addresses;

  static PairingPayload? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return _parseUri(trimmed) ?? _parseJson(trimmed);
  }

  static PairingPayload? _parseUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'sidemesh' || uri.host != 'pair') {
      return null;
    }
    final label = uri.queryParameters['label']?.trim() ?? '';
    final baseUrl =
        uri.queryParameters['baseUrl']?.trim() ??
        uri.queryParameters['url']?.trim() ??
        '';
    final token = uri.queryParameters['token']?.trim() ?? '';
    return _build(
      label: label,
      baseUrl: baseUrl,
      token: token,
      addresses: uri.queryParametersAll['address'],
    );
  }

  static PairingPayload? _parseJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final label = _string(decoded['label']);
      final token = _string(decoded['token']);
      final baseUrl =
          _string(decoded['baseUrl']) ??
          _string(decoded['url']) ??
          _preferredAddress(decoded['preferredAddress']) ??
          _firstAddress(decoded['addresses']);
      return _build(
        label: label,
        baseUrl: baseUrl,
        token: token,
        addresses: _addresses(decoded['addresses']),
      );
    } catch (_) {
      return null;
    }
  }

  static PairingPayload? _build({
    required String? label,
    required String? baseUrl,
    required String? token,
    Iterable<String>? addresses,
  }) {
    final resolvedLabel = label?.trim() ?? '';
    final resolvedBaseUrl = _normalizeBaseUrl(baseUrl ?? '');
    final resolvedToken = token?.trim() ?? '';
    if (resolvedLabel.isEmpty ||
        resolvedBaseUrl.isEmpty ||
        resolvedToken.isEmpty) {
      return null;
    }
    return PairingPayload(
      label: resolvedLabel,
      baseUrl: resolvedBaseUrl,
      token: resolvedToken,
      addresses: <String>{
        resolvedBaseUrl,
        ...?addresses
            ?.map(_normalizeBaseUrl)
            .where((address) => address.isNotEmpty),
      }.toList(growable: false),
    );
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _preferredAddress(Object? value) {
    if (value is! Map) return null;
    return _string(value['url']);
  }

  static String? _firstAddress(Object? value) {
    if (value is! List) return null;
    for (final item in value) {
      if (item is Map) {
        final url = _string(item['url']);
        if (url != null) return url;
      }
    }
    return null;
  }

  static List<String> _addresses(Object? value) {
    if (value is! List) return const [];
    return value
        .map((item) => item is Map ? _string(item['url']) : _string(item))
        .whereType<String>()
        .toList(growable: false);
  }

  static String _normalizeBaseUrl(String input) {
    var value = input.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return '';
    if (uri.scheme != 'http' && uri.scheme != 'https') return '';
    return value;
  }
}
