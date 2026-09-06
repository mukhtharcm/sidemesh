import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/host_detail_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

const _host = HostProfile(
  id: 'machine-details-test',
  label: 'Test machine',
  baseUrl: 'http://localhost:8899',
  token: 'test',
);

final _node = NodeInfo.fromJson({
  'label': 'Test machine',
  'hostname': 'localhost',
  'platform': 'linux',
  'provider': 'fake',
  'providerName': 'Test agent',
  'providerVersion': '1.0',
  'providerConfig': {'kind': 'fake'},
  'defaultProviderCapabilities': <String, Object?>{},
  'hostCapabilities': {
    'workspace': {'terminal': true},
  },
  'supportedProviders': <Object>[],
  'packageVersion': '1.0.0',
  'latestVersion': '1.1.0',
  'updateSupported': true,
  'updateAvailable': true,
  'installType': 'npm',
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final desktop in [true, false]) {
      testWidgets(
        'machine controls load without session history: $mode, $desktop',
        (tester) async {
          final api = _MachineApi();
          await _pumpMachine(tester, api, mode: mode, desktop: desktop);

          expect(find.text('Recent sessions'), findsNothing);
          expect(find.text('Start from folder'), findsNothing);
          expect(find.text('Machine tools'), findsNothing);
          expect(find.text('New session'), findsOneWidget);
          expect(find.text('Connection'), findsNothing);
          if (desktop) {
            expect(
              tester.getCenter(find.text('New session')).dy,
              closeTo(tester.getCenter(find.text('Open terminal')).dy, 1),
            );
          }
          expect(find.textContaining('Agents:'), findsOneWidget);
          expect(find.text('Open terminal'), findsOneWidget);
          expect(find.text('Update Sidemesh'), findsOneWidget);
          expect(api.sessionReads, 0);
          expect(find.text('Restart Sidemesh'), findsNothing);
          await tester.tap(find.byTooltip('More machine actions'));
          await tester.pumpAndSettle();
          expect(find.text('Restart Sidemesh'), findsOneWidget);
          await tester.tap(find.byTooltip('More machine actions'));
          await tester.pumpAndSettle();

          await tester.tap(find.byTooltip('Refresh'));
          await tester.pumpAndSettle();
          expect(api.nodeReads, 2);
          expect(api.sessionReads, 0);
          expect(tester.takeException(), isNull);

          await tester.tap(find.text('Update Sidemesh'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(
            find.text(
              'Open terminals and browser tabs disconnect while the update starts.',
            ),
            findsOneWidget,
          );
          expect(find.text('Update now').hitTestable(), findsOneWidget);
          expect(
            tester.getCenter(find.text('Cancel')).dy,
            tester.getCenter(find.text('Update now')).dy,
          );
          await tester.tap(find.byType(Checkbox));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getBool('sidemesh_update_skip_confirm'), isNull);
          expect(api.updates, 0);

          await tester.tap(find.text('Update Sidemesh'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Checkbox));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Update now'));
          await tester.pump();
          expect(api.updates, 1);
          expect(prefs.getBool('sidemesh_update_skip_confirm'), isTrue);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

Future<void> _pumpMachine(
  WidgetTester tester,
  _MachineApi api, {
  required ThemeMode mode,
  required bool desktop,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = desktop ? const Size(1100, 900) : const Size(390, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final palette = ThemeVariant.codexAmber;
  final platform = desktop ? TargetPlatform.macOS : TargetPlatform.iOS;
  await tester.pumpWidget(
    MaterialApp(
      themeMode: mode,
      theme: buildLightTheme(palette.light, platform: platform),
      darkTheme: buildDarkTheme(palette.dark, platform: platform),
      home: HostDetailScreen(
        host: _host,
        api: api,
        embedded: desktop,
        showMobileClientCompatibility: false,
        onOpenSession: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _MachineApi extends ApiClient {
  int nodeReads = 0;
  int sessionReads = 0;
  int updates = 0;

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async {
    nodeReads++;
    return _node;
  }

  @override
  Future<List<SessionSummary>> fetchSessions(
    HostProfile host, {
    int? limit,
  }) async {
    sessionReads++;
    throw StateError('Session history is unavailable');
  }

  @override
  Future<UpdateInfo> refreshUpdateInfo(HostProfile host) async =>
      _node.updateInfo;

  @override
  Future<UpdateOperation?> updateDaemon(
    HostProfile host, {
    String? updateChannel,
  }) async {
    updates++;
    return null;
  }

  @override
  Future<UpdateOperation?> fetchUpdateStatus(HostProfile host) async => null;
}
