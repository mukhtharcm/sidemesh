import 'dart:io';

import 'package:ghostty_vte/src/hook/build_cache.dart';
import 'package:test/test.dart';

void main() {
  test('clearGhosttyVteHookCache removes only the ghostty_vte hook cache', () {
    final root = Directory.systemTemp.createTempSync('ghostty_vte_build_cache');
    addTearDown(() => root.deleteSync(recursive: true));

    final ghosttyCache = Directory(
      '${root.path}/.dart_tool/hooks_runner/shared/ghostty_vte/build',
    )..createSync(recursive: true);
    final otherCache = Directory(
      '${root.path}/.dart_tool/hooks_runner/shared/portable_pty/build',
    )..createSync(recursive: true);

    File('${ghosttyCache.path}/libghostty-vt.so').writeAsStringSync('stub');
    File('${otherCache.path}/libportable_pty_rs.so').writeAsStringSync('stub');

    final removed = clearGhosttyVteHookCache(root);

    expect(removed, [
      '${root.path}/.dart_tool/hooks_runner/shared/ghostty_vte',
    ]);
    expect(
      Directory(
        '${root.path}/.dart_tool/hooks_runner/shared/ghostty_vte',
      ).existsSync(),
      isFalse,
    );
    expect(otherCache.existsSync(), isTrue);
  });
}
