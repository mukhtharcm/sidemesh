enum SessionResourceReferenceKind {
  localFile,
  hostUrl,
  publicUrl,
  inlineImage,
  anchor,
  unsupported,
}

class SessionResourceReference {
  const SessionResourceReference({
    required this.kind,
    required this.value,
    required this.original,
  });

  final SessionResourceReferenceKind kind;
  final String value;
  final String original;

  bool get isLocalFile => kind == SessionResourceReferenceKind.localFile;
  bool get isHostUrl => kind == SessionResourceReferenceKind.hostUrl;
}

SessionResourceReference parseSessionResourceReference(String raw) {
  final original = raw;
  var value = raw.trim();
  if (value.startsWith('<') && value.endsWith('>') && value.length > 2) {
    value = value.substring(1, value.length - 1).trim();
  }
  if (value.isEmpty) {
    return SessionResourceReference(
      kind: SessionResourceReferenceKind.unsupported,
      value: value,
      original: original,
    );
  }
  if (value.startsWith('#')) {
    return SessionResourceReference(
      kind: SessionResourceReferenceKind.anchor,
      value: value,
      original: original,
    );
  }
  if (value.startsWith('data:image/')) {
    return SessionResourceReference(
      kind: SessionResourceReferenceKind.inlineImage,
      value: value,
      original: original,
    );
  }
  if (value.startsWith('//')) {
    return SessionResourceReference(
      kind: SessionResourceReferenceKind.publicUrl,
      value: 'https:$value',
      original: original,
    );
  }

  final uri = Uri.tryParse(value);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (scheme == 'http' || scheme == 'https') {
    return SessionResourceReference(
      kind: isHostLoopbackUri(uri!)
          ? SessionResourceReferenceKind.hostUrl
          : SessionResourceReferenceKind.publicUrl,
      value: value,
      original: original,
    );
  }
  if (scheme == 'file') {
    // Preserve the URI. The connected host, not the phone, owns the platform
    // semantics required to convert it into a filesystem path.
    return SessionResourceReference(
      kind: SessionResourceReferenceKind.localFile,
      value: value,
      original: original,
    );
  }
  if (scheme.isNotEmpty && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    return SessionResourceReference(
      kind: SessionResourceReferenceKind.unsupported,
      value: value,
      original: original,
    );
  }

  final path = _stripMarkdownSuffix(value);
  return SessionResourceReference(
    kind: path.isEmpty
        ? SessionResourceReferenceKind.unsupported
        : SessionResourceReferenceKind.localFile,
    value: _decodePath(path),
    original: original,
  );
}

bool isHostLoopbackUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      isHostLoopbackUri(uri);
}

bool isHostLoopbackUri(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host == '0.0.0.0' ||
      host == '::1' ||
      host.endsWith('.localhost')) {
    return true;
  }
  final octets = host.split('.');
  return octets.length == 4 &&
      int.tryParse(octets.first) == 127 &&
      octets.every((part) {
        final value = int.tryParse(part);
        return value != null && value >= 0 && value <= 255;
      });
}

String? hostPathDirectory(String raw) {
  final reference = parseSessionResourceReference(raw);
  if (!reference.isLocalFile || reference.value.startsWith('file:')) {
    return null;
  }
  final value = reference.value;
  final slash = value.lastIndexOf('/');
  final backslash = value.lastIndexOf('\\');
  final separator = slash > backslash ? slash : backslash;
  if (separator < 0) return null;
  if (separator == 0) return value.substring(0, 1);
  return value.substring(0, separator);
}

String resolveHostPathLexically(String raw, {String? basePath}) {
  final reference = parseSessionResourceReference(raw);
  if (!reference.isLocalFile) return raw;
  final value = reference.value;
  if (value.startsWith('file:') ||
      value.startsWith('/') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
      (basePath ?? '').isEmpty) {
    return value;
  }
  final base = basePath!;
  final windows = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(base) ||
      (base.contains('\\') && !base.contains('/'));
  final separator = windows ? '\\' : '/';
  final normalizedBase = base.replaceAll(windows ? '/' : '\\', separator);
  final normalizedValue = value.replaceAll(windows ? '/' : '\\', separator);
  return '$normalizedBase$separator$normalizedValue';
}

String _stripMarkdownSuffix(String value) {
  final query = value.indexOf('?');
  final fragment = value.indexOf('#');
  final indexes = [query, fragment].where((index) => index >= 0).toList()
    ..sort();
  return indexes.isEmpty ? value : value.substring(0, indexes.first);
}

String _decodePath(String value) {
  try {
    return Uri.decodeFull(value);
  } catch (_) {
    return value;
  }
}
