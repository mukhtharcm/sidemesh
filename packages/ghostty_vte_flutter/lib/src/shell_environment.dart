library;

import 'platform_environment_stub.dart'
    if (dart.library.io) 'platform_environment_io.dart'
    as platform_env;

/// Options for constructing a usable shell environment for terminal demos.
final class GhosttyTerminalShellEnvironmentOptions {
  const GhosttyTerminalShellEnvironmentOptions({
    this.term = 'xterm-256color',
    this.colorTerm = 'truecolor',
    this.fallbackUtf8Locale = 'C.UTF-8',
    this.ensureXdgPaths = true,
    this.ensureUtf8Locale = true,
  });

  final String term;
  final String? colorTerm;
  final String fallbackUtf8Locale;
  final bool ensureXdgPaths;
  final bool ensureUtf8Locale;
}

/// Returns the current process environment on native platforms and an empty map
/// on web.
Map<String, String> ghosttyTerminalPlatformEnvironment() {
  return platform_env.ghosttyTerminalPlatformEnvironment();
}

/// Builds a shell-friendly environment from a platform environment map.
///
/// This keeps the caller's existing environment intact, then applies terminal
/// defaults such as `TERM`, `COLORTERM`, `HOME`-derived XDG paths, and a UTF-8
/// locale when the input environment did not already provide one.
Map<String, String> ghosttyTerminalShellEnvironment({
  required Map<String, String> platformEnvironment,
  Map<String, String> overrides = const <String, String>{},
  GhosttyTerminalShellEnvironmentOptions options =
      const GhosttyTerminalShellEnvironmentOptions(),
}) {
  final environment = <String, String>{...platformEnvironment, ...overrides};

  environment['TERM'] = environment['TERM']?.isNotEmpty == true
      ? environment['TERM']!
      : options.term;
  final colorTerm = options.colorTerm;
  if (colorTerm != null &&
      (environment['COLORTERM'] == null || environment['COLORTERM']!.isEmpty)) {
    environment['COLORTERM'] = colorTerm;
  }

  final home = _resolvedHome(environment);
  if (home != null) {
    environment['HOME'] ??= home;
    if (options.ensureXdgPaths) {
      environment['XDG_CONFIG_HOME'] ??= '$home/.config';
      environment['XDG_CACHE_HOME'] ??= '$home/.cache';
      environment['XDG_DATA_HOME'] ??= '$home/.local/share';
      environment['XDG_STATE_HOME'] ??= '$home/.local/state';
    }
  }

  if (options.ensureUtf8Locale) {
    final utf8Locale = _resolvedUtf8Locale(
      environment,
      fallback: options.fallbackUtf8Locale,
    );
    if ((environment['LC_ALL'] == null || environment['LC_ALL']!.isEmpty) &&
        utf8Locale != null) {
      final lang = environment['LANG'];
      if (lang == null || !_containsUtf8Locale(lang)) {
        environment['LANG'] = utf8Locale;
      }
      final lcCtype = environment['LC_CTYPE'];
      if (lcCtype == null || !_containsUtf8Locale(lcCtype)) {
        environment['LC_CTYPE'] = utf8Locale;
      }
    }
  }

  return environment;
}

String? _resolvedHome(Map<String, String> environment) {
  final home = environment['HOME'];
  if (home != null && home.isNotEmpty) {
    return home;
  }
  final userProfile = environment['USERPROFILE'];
  if (userProfile != null && userProfile.isNotEmpty) {
    return userProfile;
  }
  return null;
}

String? _resolvedUtf8Locale(
  Map<String, String> environment, {
  required String fallback,
}) {
  for (final key in const <String>['LC_ALL', 'LC_CTYPE', 'LANG']) {
    final value = environment[key];
    if (value != null && _containsUtf8Locale(value)) {
      return value;
    }
  }
  return fallback.isEmpty ? null : fallback;
}

bool _containsUtf8Locale(String locale) {
  final lower = locale.toLowerCase();
  return lower.contains('utf-8') || lower.contains('utf8');
}
