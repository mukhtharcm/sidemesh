import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screen_awake_controller.dart';
import 'package:sidemesh_mobile/src/screen_awake_settings_store.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/session_cache_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('does not wake from cached active sessions when fetch fails', (
    tester,
  ) async {
    final active = _summary('session-1', status: 'active');
    await SessionCacheStore.instance.saveRecentSessions(host, [active]);
    final store = ScreenAwakeSettingsStore.forTesting();
    await store.setKeepScreenAwakeWhileAgentRuns(true);
    final binding = _FakeScreenAwakeBinding();
    final controller = ScreenAwakeController(
      settingsStore: store,
      binding: binding,
    );
    addTearDown(controller.stop);
    await controller.start();

    await _pumpRecentPane(
      tester,
      api: _FakeApiClient.error(),
      controller: controller,
      hosts: const [host],
    );
    await tester.pump();
    await tester.pump();
    await controller.waitForIdle();

    expect(binding.calls, isEmpty);
  });

  testWidgets('wakes for freshly confirmed active sessions and releases', (
    tester,
  ) async {
    final active = _summary('session-1', status: 'active');
    final store = ScreenAwakeSettingsStore.forTesting();
    await store.setKeepScreenAwakeWhileAgentRuns(true);
    final binding = _FakeScreenAwakeBinding();
    final controller = ScreenAwakeController(
      settingsStore: store,
      binding: binding,
    );
    addTearDown(controller.stop);
    await controller.start();

    await _pumpRecentPane(
      tester,
      api: _FakeApiClient.sessions([active]),
      controller: controller,
      hosts: const [host],
    );
    await tester.pump();
    await tester.pump();
    await controller.waitForIdle();

    expect(binding.calls, <bool>[true]);

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.waitForIdle();
    await controller.stop();

    expect(binding.calls, <bool>[true, false]);
  });
}

Future<void> _pumpRecentPane(
  WidgetTester tester, {
  required ApiClient api,
  required ScreenAwakeController controller,
  required List<HostProfile> hosts,
}) async {
  final themeController = await ThemeController.load();
  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    ThemeScope(
      notifier: themeController,
      child: MaterialApp(
        theme: buildLightTheme(
          palette.light,
          typography: themeController.typography,
        ),
        darkTheme: buildDarkTheme(
          palette.dark,
          typography: themeController.typography,
        ),
        home: Scaffold(
          body: RecentPane(
            hosts: hosts,
            api: api,
            hasSavedHosts: hosts.isNotEmpty,
            screenAwakeSourceKey: 'recent-test',
            screenAwakeController: controller,
            onOpenSession: (_, _) {},
            onActiveCountChanged: (_) {},
          ),
        ),
      ),
    ),
  );
}

SessionSummary _summary(String id, {required String status}) {
  final now = DateTime.now();
  return SessionSummary(
    id: id,
    title: 'Session $id',
    preview: 'hello',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'codex',
    provider: null,
    status: status,
    runtime: null,
    gitInfo: null,
  );
}

class _FakeApiClient extends ApiClient {
  _FakeApiClient._(this._sessions, this._error);

  factory _FakeApiClient.sessions(List<SessionSummary> sessions) {
    return _FakeApiClient._(sessions, null);
  }

  factory _FakeApiClient.error() {
    return _FakeApiClient._(const <SessionSummary>[], StateError('offline'));
  }

  final List<SessionSummary> _sessions;
  final Object? _error;
  final _IdleWebSocketChannel _channel = _IdleWebSocketChannel();

  @override
  Future<List<SessionSummary>> fetchSessions(HostProfile host, {int? limit}) {
    final error = _error;
    if (error != null) {
      return Future<List<SessionSummary>>.error(error);
    }
    return Future<List<SessionSummary>>.value(_sessions);
  }

  @override
  WebSocketChannel openSessionsLive(HostProfile host) => _channel;
}

class _FakeScreenAwakeBinding implements ScreenAwakeBinding {
  final List<bool> calls = <bool>[];

  @override
  Future<void> setEnabled(bool enabled) async {
    calls.add(enabled);
  }
}

class _IdleWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _IdleWebSocketSink(_outgoing.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}
}

class _IdleWebSocketSink implements WebSocketSink {
  _IdleWebSocketSink(this._delegate);

  final StreamSink<dynamic> _delegate;

  @override
  Future<void> addStream(Stream<dynamic> stream) => _delegate.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _delegate.close();

  @override
  Future<void> get done => _delegate.done;

  @override
  void add(dynamic data) => _delegate.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);
}
