import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  test(
    'shell environment preserves platform values and fills XDG defaults',
    () {
      final environment = ghosttyTerminalShellEnvironment(
        platformEnvironment: const <String, String>{
          'HOME': '/tmp/demo-home',
          'PATH': '/usr/bin',
        },
        overrides: const <String, String>{'TERM': 'xterm-256color'},
      );

      expect(environment['HOME'], '/tmp/demo-home');
      expect(environment['PATH'], '/usr/bin');
      expect(environment['TERM'], 'xterm-256color');
      expect(environment['XDG_CONFIG_HOME'], '/tmp/demo-home/.config');
      expect(environment['XDG_CACHE_HOME'], '/tmp/demo-home/.cache');
      expect(environment['XDG_DATA_HOME'], '/tmp/demo-home/.local/share');
      expect(environment['XDG_STATE_HOME'], '/tmp/demo-home/.local/state');
    },
  );

  test('shell environment injects a UTF-8 locale when missing', () {
    final environment = ghosttyTerminalShellEnvironment(
      platformEnvironment: const <String, String>{'HOME': '/tmp/demo-home'},
    );

    expect(environment['LANG'], contains('UTF-8'));
    expect(environment['LC_CTYPE'], contains('UTF-8'));
  });

  test('shell environment preserves an existing UTF-8 locale', () {
    final environment = ghosttyTerminalShellEnvironment(
      platformEnvironment: const <String, String>{
        'HOME': '/tmp/demo-home',
        'LANG': 'en_US.UTF-8',
      },
    );

    expect(environment['LANG'], 'en_US.UTF-8');
    expect(environment['LC_CTYPE'], 'en_US.UTF-8');
  });

  test('shell environment respects explicit overrides', () {
    final environment = ghosttyTerminalShellEnvironment(
      platformEnvironment: const <String, String>{
        'HOME': '/tmp/demo-home',
        'TERM': 'screen',
      },
      overrides: const <String, String>{
        'TERM': 'xterm-256color',
        'XDG_CONFIG_HOME': '/tmp/custom-config',
      },
    );

    expect(environment['TERM'], 'xterm-256color');
    expect(environment['XDG_CONFIG_HOME'], '/tmp/custom-config');
  });
}
