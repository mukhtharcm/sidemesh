/// Compact label for a remote workspace; never disclose a home username.
String workspaceLabel(String cwd) {
  final normalized = cwd.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
  if (normalized.isEmpty) return cwd.trim() == '/' ? '/' : 'Workspace';
  if (normalized == '~' || normalized == '/root' ||
      RegExp(r'^/(Users|home)/[^/]+$').hasMatch(normalized) ||
      RegExp(r'^[A-Za-z]:/Users/[^/]+$', caseSensitive: false).hasMatch(normalized)) {
    return '~';
  }
  return normalized.split('/').last;
}
