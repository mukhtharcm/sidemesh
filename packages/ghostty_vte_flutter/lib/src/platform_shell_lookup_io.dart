import 'dart:io';

bool ghosttyTerminalPlatformIsWindows() {
  return Platform.isWindows;
}

String? ghosttyTerminalResolveFirstExistingShell(List<String> candidates) {
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}
