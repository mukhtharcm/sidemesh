import 'dart:io';

/// Removes stale build-hook outputs for `ghostty_vte` inside a consuming app.
///
/// This is primarily used by `dart run ghostty_vte:setup`: building that
/// executable can populate `.dart_tool/hooks_runner/shared/ghostty_vte/`
/// before the requested prebuilt library is extracted, so the next app build
/// should start from a clean hook cache.
List<String> clearGhosttyVteHookCache(Directory projectRoot) {
  final hookCache = Directory(
    '${projectRoot.path}/.dart_tool/hooks_runner/shared/ghostty_vte',
  );

  if (!hookCache.existsSync()) {
    return const [];
  }

  hookCache.deleteSync(recursive: true);
  return [hookCache.path];
}
