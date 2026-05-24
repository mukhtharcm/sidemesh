import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  test('user shell launch uses the provided shell environment', () {
    final launches = ghosttyTerminalShellLaunches(
      profile: GhosttyTerminalShellProfile.userShell,
      platformEnvironment: const <String, String>{
        'HOME': '/tmp/demo-home',
        'SHELL': '/bin/zsh',
      },
    );

    expect(launches, hasLength(1));
    expect(launches.single.label, 'user shell');
    expect(launches.single.shell, '/bin/zsh');
    expect(launches.single.arguments, const <String>['-i']);
    expect(launches.single.environment?['TERM'], 'xterm-256color');
    expect(
      launches.single.environment?['XDG_CONFIG_HOME'],
      '/tmp/demo-home/.config',
    );
  });

  test('clean bash launch includes the shared normalized environment', () {
    final launches = ghosttyTerminalShellLaunches(
      profile: GhosttyTerminalShellProfile.cleanBash,
      platformEnvironment: const <String, String>{'HOME': '/tmp/demo-home'},
    );

    if (launches.isEmpty) {
      return;
    }

    final launch = launches.single;
    expect(launch.label, 'clean bash shell');
    expect(launch.commandLine, contains('--noprofile --norc -i'));
    expect(launch.environment?['TERM'], 'xterm-256color');
    expect(launch.environment?['LANG'], contains('UTF-8'));
    expect(launch.setupCommand, "export PS1='> '\n");
  });

  test('clean zsh launch includes terminal-focused backspace bindings', () {
    final launches = ghosttyTerminalShellLaunches(
      profile: GhosttyTerminalShellProfile.cleanZsh,
      platformEnvironment: const <String, String>{'HOME': '/tmp/demo-home'},
    );

    if (launches.isEmpty) {
      return;
    }

    final launch = launches.single;
    expect(launch.label, 'clean zsh shell');
    expect(launch.setupCommand, contains("PROMPT='%# '\n"));
    expect(launch.setupCommand, contains('RPROMPT=\n'));
    expect(launch.setupCommand, contains('stty erase'));
    expect(launch.setupCommand, contains("bindkey '^?' backward-delete-char"));
    expect(launch.setupCommand, contains("bindkey '^H' backward-delete-char"));
    expect(launch.environment?['TERM'], 'xterm-256color');
  });
}
