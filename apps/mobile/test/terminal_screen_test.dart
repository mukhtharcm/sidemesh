import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/terminal_screen.dart';
import 'package:sidemesh_mobile/src/widgets/terminal_keybar.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

class _UnavailableApi extends ApiClient {
  @override
  Future<List<HostTerminalInfo>> fetchTerminals(HostProfile host) async =>
      throw StateError('Terminal unavailable');
}

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    for (final dark in [false, true]) {
      testWidgets('terminal controls and output: $platform, dark=$dark', (
        tester,
      ) async {
        var closed = false;
        final palette = ThemeVariant.codexAmber;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark
                ? buildDarkTheme(palette.dark, platform: platform)
                : buildLightTheme(palette.light, platform: platform),
            home: TerminalScreen(
              host: const HostProfile(
                id: 'terminal-test',
                label: 'Test',
                baseUrl: 'http://localhost',
                token: 'test',
              ),
              api: _UnavailableApi(),
              cwd: '/',
              onClose: () => closed = true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(TerminalKeyBar),
          platform == TargetPlatform.iOS ? findsOneWidget : findsNothing,
        );
        final terminal = tester
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal;
        expect(terminal.buffer.lines[0].getText().trim(), isEmpty);
        expect(find.byTooltip('Start a new terminal'), findsOneWidget);
        await tester.tap(find.byTooltip('Back to machine'));
        expect(closed, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
