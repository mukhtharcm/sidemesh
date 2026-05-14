import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/port_forward_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  testWidgets(
    'preview-only screen focuses browser previews without tunnel copy',
    (tester) async {
      final api = _ConnectionsFakeApi();

      await _pumpApp(
        tester,
        PortForwardScreen(
          host: _host('preview-only'),
          api: api,
          cwd: '/repo',
          sessionId: 'session-preview-only',
          sessionTitle: 'Preview session',
          supportsBrowserPreview: true,
          supportsPortForwarding: false,
        ),
        size: const Size(390, 844),
      );
      await _pumpFrames(tester);

      expect(find.text('Preview apps'), findsOneWidget);
      expect(find.text('Start a preview'), findsOneWidget);
      expect(
        find.textContaining('Open a local app running on'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Start preview'),
        findsOneWidget,
      );
      expect(find.text('Get local URL'), findsNothing);
      expect(find.text('No previews yet'), findsOneWidget);
    },
  );

  testWidgets('tunnel-only screen avoids browser-preview language', (
    tester,
  ) async {
    final api = _ConnectionsFakeApi();

    await _pumpApp(
      tester,
      PortForwardScreen(
        host: _host('tunnel-only'),
        api: api,
        cwd: '/repo',
        sessionId: 'session-tunnel-only',
        sessionTitle: 'Tunnel session',
        supportsBrowserPreview: false,
        supportsPortForwarding: true,
      ),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    expect(find.text('Preview apps'), findsOneWidget);
    expect(find.text('Previews unavailable'), findsOneWidget);
    expect(
      find.textContaining('does not support previews yet'),
      findsOneWidget,
    );
    expect(find.text('Open'), findsNothing);
    expect(find.text('Get local URL'), findsNothing);
    expect(find.text('No active connections'), findsNothing);
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpApp(
  WidgetTester tester,
  Widget child, {
  required Size size,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      home: child,
    ),
  );
}

HostProfile _host(String id) => HostProfile(
  id: 'port-forward-ui-$id',
  label: 'Fake Host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

class _ConnectionsFakeApi extends ApiClient {
  @override
  Future<List<HostPortForwardInfo>> fetchPortForwards(HostProfile host) async =>
      const [];

  @override
  Future<List<HostBrowserPreviewInfo>> fetchBrowserPreviews(
    HostProfile host,
  ) async => const [];
}
