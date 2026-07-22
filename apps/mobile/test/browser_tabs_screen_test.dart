import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/browser_tabs_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  testWidgets('empty browser asks for a URL and opens a tab', (tester) async {
    final api = _BrowserTabsFakeApi();
    HostBrowserPreviewInfo? opened;

    await _pumpApp(
      tester,
      BrowserTabsScreen(
        host: _host(),
        api: api,
        cwd: '/repo',
        sessionId: 'session-1',
        onBrowserOpened: (tab) => opened = tab,
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('Open browser'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'localhost:3000');
    await tester.tap(
      find.widgetWithIcon(FilledButton, Icons.open_in_browser_rounded),
    );
    await _pumpFrames(tester);

    expect(api.createCalls, hasLength(1));
    expect(api.createCalls.single.targetPort, 3000);
    expect(api.createCalls.single.reuseExisting, isFalse);
    expect(opened?.id, 'created-1');
  });

  testWidgets('existing browser tabs are listed with a new tab action', (
    tester,
  ) async {
    final existing = _tab(
      id: 'tab-existing',
      label: 'Local app',
      url: 'http://127.0.0.1:3000/',
    );
    final api = _BrowserTabsFakeApi(tabs: [existing]);
    HostBrowserPreviewInfo? opened;

    await _pumpApp(
      tester,
      BrowserTabsScreen(
        host: _host(),
        api: api,
        cwd: '/repo',
        sessionId: 'session-1',
        onBrowserOpened: (tab) => opened = tab,
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('Tabs'), findsOneWidget);
    expect(find.text('Local app'), findsOneWidget);
    expect(find.text('New tab'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Local app'));
    await _pumpFrames(tester);
    expect(opened?.id, 'tab-existing');

    await tester.tap(find.text('New tab'));
    await _pumpFrames(tester);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'localhost:4173');
    await tester.tap(find.widgetWithText(FilledButton, 'Open').first);
    await _pumpFrames(tester);

    expect(api.createCalls, hasLength(1));
    expect(api.createCalls.single.targetPort, 4173);
    expect(api.createCalls.single.reuseExisting, isFalse);
    expect(opened?.id, 'created-1');
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpApp(WidgetTester tester, Widget child) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(430, 760);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      home: TooltipVisibility(visible: false, child: child),
    ),
  );
}

HostProfile _host() => HostProfile(
  id: 'browser-tabs-host',
  label: 'Fake Host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

HostBrowserPreviewInfo _tab({
  required String id,
  required String label,
  required String url,
  String sessionId = 'session-1',
}) => HostBrowserPreviewInfo(
  id: id,
  label: label,
  url: url,
  targetHost: '127.0.0.1',
  targetPort: Uri.parse(url).port,
  scheme: Uri.parse(url).scheme,
  cwd: '/repo',
  sessionId: sessionId,
  profileMode: 'temporary',
  status: 'running',
  width: 390,
  height: 844,
  clients: 1,
  createdAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastClientAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastFrameAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastError: null,
);

class _CreateCall {
  const _CreateCall({required this.targetPort, required this.reuseExisting});

  final int? targetPort;
  final bool reuseExisting;
}

class _BrowserTabsFakeApi extends ApiClient {
  _BrowserTabsFakeApi({List<HostBrowserPreviewInfo> tabs = const []})
    : _tabs = List<HostBrowserPreviewInfo>.of(tabs);

  final List<HostBrowserPreviewInfo> _tabs;
  final List<_CreateCall> createCalls = <_CreateCall>[];

  @override
  Future<List<HostBrowserPreviewInfo>> fetchBrowserPreviews(
    HostProfile host,
  ) async => List<HostBrowserPreviewInfo>.of(_tabs);

  @override
  Future<HostBrowserPreviewInfo> createBrowserPreview(
    HostProfile host, {
    int? targetPort,
    String targetHost = '127.0.0.1',
    String? targetUrl,
    String scheme = 'http',
    String? label,
    String? cwd,
    String? sessionId,
    int? width,
    int? height,
    String profileMode = 'temporary',
    bool reuseExisting = true,
  }) async {
    createCalls.add(
      _CreateCall(targetPort: targetPort, reuseExisting: reuseExisting),
    );
    final tab = _tab(
      id: 'created-${createCalls.length}',
      label: label ?? 'Created tab',
      url: targetUrl ?? '$scheme://$targetHost:$targetPort/',
      sessionId: sessionId ?? 'session-1',
    );
    _tabs.insert(0, tab);
    return tab;
  }

  @override
  Future<void> stopBrowserPreview(HostProfile host, String previewId) async {
    final index = _tabs.indexWhere((tab) => tab.id == previewId);
    if (index == -1) {
      throw StateError('missing tab');
    }
    _tabs.removeAt(index);
  }
}
