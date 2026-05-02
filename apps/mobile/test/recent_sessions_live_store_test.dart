import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/recent_sessions_live_store.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => '/tmp/sidemesh_test';
  @override
  Future<String?> getTemporaryPath() async => '/tmp/sidemesh_test';
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProvider();
  });

  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  setUp(() async {
    SessionLocalStore.instance.resetMigrationState();
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('falls back to HTTP sessions when live socket is unavailable', () async {
    final api = _FakeApiClient()
      ..throwOnOpenSessionsLive = true
      ..sessionsByHostId[host.id] = [_session('session-1', title: 'HTTP only')];
    final store = RecentSessionsStore(
      pollInterval: const Duration(hours: 1),
      initialHttpFallbackDelay: const Duration(milliseconds: 1),
    );
    addTearDown(store.dispose);

    store.configure(hosts: const [host], api: api);
    await _settle();

    expect(store.entries, hasLength(1));
    expect(store.entries.single.session.title, 'HTTP only');
    expect(store.confirmedHostIds, contains(host.id));
  });

  test(
    'hydrates cached sessions before a slower network refresh completes',
    () async {
      final cached = _session('session-1', title: 'Cached first');
      await SessionLocalStore.instance.upsertSessions(host, [cached]);
      final api = _FakeApiClient()
        ..throwOnOpenSessionsLive = true
        ..fetchDelay = const Duration(milliseconds: 50)
        ..sessionsByHostId[host.id] = [
          _session('session-2', title: 'Fresh later'),
        ];
      final store = RecentSessionsStore(
        pollInterval: const Duration(hours: 1),
        initialHttpFallbackDelay: const Duration(milliseconds: 1),
      );
      addTearDown(store.dispose);

      store.configure(hosts: const [host], api: api);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(store.entries.map((entry) => entry.session.title), [
        'Cached first',
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(store.entries.map((entry) => entry.session.title), [
        'Fresh later',
      ]);
      expect(store.confirmedHostIds, contains(host.id));
    },
  );

  test('live snapshot and remove keep recent sessions current', () async {
    final api = _FakeApiClient()
      ..sessionsByHostId[host.id] = const <SessionSummary>[];
    final store = RecentSessionsStore(
      pollInterval: const Duration(hours: 1),
      initialHttpFallbackDelay: const Duration(milliseconds: 100),
    );
    addTearDown(store.dispose);

    store.configure(hosts: const [host], api: api);
    await _settle();

    final channel = api.liveChannelFor(host);
    channel.addIncoming(
      jsonEncode({
        'type': 'snapshot',
        'sessions': [_session('session-1', title: 'First').toJson()],
      }),
    );
    await _settle();

    expect(store.entries, hasLength(1));
    expect(store.entries.single.session.title, 'First');
    expect(store.confirmedHostIds, contains(host.id));

    channel.addIncoming(
      jsonEncode({
        'type': 'upsert',
        'session': _session('session-2', title: 'Second').toJson(),
      }),
    );
    await _settle();

    expect(store.entries.map((entry) => entry.session.id), {
      'session-1',
      'session-2',
    });

    channel.addIncoming(
      jsonEncode({'type': 'remove', 'sessionId': 'session-1'}),
    );
    await _settle();

    expect(store.entries.map((entry) => entry.session.id), {'session-2'});
  });

  test(
    'swallows websocket handshake failures and keeps HTTP fallback alive',
    () async {
      final uncaught = <Object>[];

      await runZonedGuarded(
        () async {
          final api = _FakeApiClient()
            ..liveReady = Future<void>.error(StateError('handshake failed'))
            ..sessionsByHostId[host.id] = [
              _session('session-1', title: 'HTTP survives'),
            ];
          final store = RecentSessionsStore(
            pollInterval: const Duration(hours: 1),
            initialHttpFallbackDelay: const Duration(milliseconds: 1),
          );
          addTearDown(store.dispose);

          store.configure(hosts: const [host], api: api);
          await _settle();
          await _settle();

          expect(store.entries, hasLength(1));
          expect(store.entries.single.session.title, 'HTTP survives');

          store.dispose();
          await _settle();
        },
        (error, stackTrace) {
          uncaught.add(error);
        },
      );

      expect(uncaught, isEmpty);
    },
  );

  test(
    'live disconnect clears confirmation without dropping visible entries',
    () async {
      final api = _FakeApiClient()
        ..sessionsByHostId[host.id] = const <SessionSummary>[];
      final store = RecentSessionsStore(
        pollInterval: const Duration(hours: 1),
        initialHttpFallbackDelay: const Duration(milliseconds: 100),
      );
      addTearDown(store.dispose);

      store.configure(hosts: const [host], api: api);
      await _settle();

      final channel = api.liveChannelFor(host);
      channel.addIncoming(
        jsonEncode({
          'type': 'snapshot',
          'sessions': [_session('session-1', title: 'Still visible').toJson()],
        }),
      );
      await _settle();
      expect(store.confirmedHostIds, contains(host.id));

      await channel.closeFromServer();
      await _settle();

      expect(store.entries, hasLength(1));
      expect(store.confirmedHostIds, isNot(contains(host.id)));
    },
  );

  test('live snapshot cancels the initial HTTP fallback', () async {
    final api = _FakeApiClient()
      ..sessionsByHostId[host.id] = [_session('session-http', title: 'HTTP')];
    final store = RecentSessionsStore(
      pollInterval: const Duration(hours: 1),
      initialHttpFallbackDelay: const Duration(milliseconds: 30),
    );
    addTearDown(store.dispose);

    store.configure(hosts: const [host], api: api);
    api
        .liveChannelFor(host)
        .addIncoming(
          jsonEncode({
            'type': 'snapshot',
            'sessions': [_session('session-live', title: 'Live').toJson()],
          }),
        );
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(api.fetchSessionsCalls, 0);
    expect(store.entries.map((entry) => entry.session.title), ['Live']);
  });
}

class _FakeApiClient extends ApiClient {
  final Map<String, List<SessionSummary>> sessionsByHostId = {};
  final Map<String, _FakeWebSocketChannel> _liveChannels = {};
  bool throwOnOpenSessionsLive = false;
  Duration fetchDelay = Duration.zero;
  Future<void> liveReady = Future<void>.value();
  int fetchSessionsCalls = 0;

  @override
  Future<List<SessionSummary>> fetchSessions(
    HostProfile host, {
    int? limit,
  }) async {
    fetchSessionsCalls++;
    if (fetchDelay > Duration.zero) {
      await Future<void>.delayed(fetchDelay);
    }
    return sessionsByHostId[host.id] ?? const <SessionSummary>[];
  }

  @override
  WebSocketChannel openSessionsLive(HostProfile host) {
    if (throwOnOpenSessionsLive) {
      throw StateError('live sessions unavailable');
    }
    return _liveChannels.putIfAbsent(
      host.id,
      () => _FakeWebSocketChannel(ready: liveReady),
    );
  }

  _FakeWebSocketChannel liveChannelFor(HostProfile host) => _liveChannels
      .putIfAbsent(host.id, () => _FakeWebSocketChannel(ready: liveReady));
}

class _FakeWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeWebSocketChannel({Future<void>? ready})
    : _ready = ready ?? Future<void>.value();

  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();
  final Future<void> _ready;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeWebSocketSink(_outgoing.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => _ready;

  void addIncoming(String value) {
    _incoming.add(value);
  }

  Future<void> closeFromServer() => _incoming.close();
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._delegate);

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

SessionSummary _session(String id, {required String title}) {
  final now = DateTime.now();
  return SessionSummary(
    id: id,
    title: title,
    preview: 'preview',
    cwd: '/repo',
    createdAt: now.subtract(const Duration(minutes: 5)),
    updatedAt: now,
    source: 'codex',
    provider: null,
    status: 'active',
    runtime: null,
    gitInfo: null,
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 10));
}
