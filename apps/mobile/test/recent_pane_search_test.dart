import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/session_read_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'test_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await configureTestDatabaseFactory();
  });

  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );
  const brokenHost = HostProfile(
    id: 'host-2',
    label: 'Broken VPS',
    baseUrl: 'http://broken.local:8787',
    token: 'secret',
  );

  setUp(() async {
    SessionLocalStore.instance.resetMigrationState();
    SessionReadStore.instance.resetForTest();
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SessionReadStore.instance.ensureLoaded();
  });

  testWidgets(
    'falls back to local filtering when query shrinks below two characters',
    (tester) async {
      final now = DateTime(2026, 1, 1, 12);
      final api = _FakeSearchApiClient(
        sessions: <SessionSummary>[
          _session(id: 'local-alpha', title: 'Alpha Local', updatedAt: now),
        ],
        searchResults: <String, List<SessionSummary>>{
          'ab': <SessionSummary>[
            _session(
              id: 'remote-beta',
              title: 'Remote Beta',
              updatedAt: now.add(const Duration(minutes: 1)),
              matchRank: 1,
            ),
          ],
        },
      );

      await _pumpRecentPane(
        tester,
        api: api,
        hosts: const <HostProfile>[host],
        query: '',
      );
      await tester.pump();
      await tester.pump();

      await _pumpRecentPane(
        tester,
        api: api,
        hosts: const <HostProfile>[host],
        query: 'ab',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.text('Remote Beta'), findsOneWidget);
      expect(find.text('Alpha Local'), findsNothing);

      await _pumpRecentPane(
        tester,
        api: api,
        hosts: const <HostProfile>[host],
        query: 'a',
      );
      await tester.pump();

      expect(find.text('Alpha Local'), findsOneWidget);
      expect(find.text('Remote Beta'), findsNothing);
    },
  );

  testWidgets(
    'keeps search relevance ahead of recency when rendering remote matches',
    (tester) async {
      final now = DateTime(2026, 1, 1, 12);
      final api = _FakeSearchApiClient(
        sessions: const <SessionSummary>[],
        searchResults: <String, List<SessionSummary>>{
          'ng': <SessionSummary>[
            _session(
              id: 'best',
              title: 'Best Match',
              updatedAt: now,
              matchRank: 1,
            ),
            _session(
              id: 'newer',
              title: 'Newer Match',
              updatedAt: now.add(const Duration(hours: 1)),
              matchRank: 5,
            ),
          ],
        },
      );

      await _pumpRecentPane(
        tester,
        api: api,
        hosts: const <HostProfile>[host],
        query: '',
      );
      await tester.pump();
      await tester.pump();

      await _pumpRecentPane(
        tester,
        api: api,
        hosts: const <HostProfile>[host],
        query: 'ng',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      final best = tester.getTopLeft(find.text('Best Match')).dy;
      final newer = tester.getTopLeft(find.text('Newer Match')).dy;
      expect(best, lessThan(newer));
    },
  );

  testWidgets('shows a banner when one host fails during search', (
    tester,
  ) async {
    final now = DateTime(2026, 1, 1, 12);
    final api = _FakeSearchApiClient(
      sessions: const <SessionSummary>[],
      searchResults: <String, List<SessionSummary>>{
        'host-1::ng': <SessionSummary>[
          _session(
            id: 'best',
            title: 'Best Match',
            updatedAt: now,
            matchRank: 1,
          ),
        ],
      },
      searchFailures: <String, Object>{'host-2::ng': StateError('offline')},
    );

    await _pumpRecentPane(
      tester,
      api: api,
      hosts: const <HostProfile>[host, brokenHost],
      query: '',
    );
    await tester.pump();
    await tester.pump();

    await _pumpRecentPane(
      tester,
      api: api,
      hosts: const <HostProfile>[host, brokenHost],
      query: 'ng',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.textContaining('Broken VPS is unreachable.'), findsOneWidget);
    expect(find.text('Best Match'), findsOneWidget);
  });

  testWidgets(
    'deduplicates mirrored search results returned by multiple hosts',
    (tester) async {
      final now = DateTime(2026, 1, 1, 12);
      final api = _FakeSearchApiClient(
        sessions: const <SessionSummary>[],
        searchResults: <String, List<SessionSummary>>{
          'host-1::ng': <SessionSummary>[
            _session(
              id: 'shared',
              title: 'Shared Match',
              updatedAt: now,
              matchRank: 1,
            ),
          ],
          'host-2::ng': <SessionSummary>[
            _session(
              id: 'shared',
              title: 'Shared Match',
              updatedAt: now.add(const Duration(seconds: 1)),
              matchRank: 2,
            ),
          ],
        },
      );

      await _pumpRecentPane(
        tester,
        api: api,
        hosts: const <HostProfile>[host, brokenHost],
        query: '',
      );
      await tester.pump();
      await tester.pump();

      await _pumpRecentPane(
        tester,
        api: api,
        hosts: const <HostProfile>[host, brokenHost],
        query: 'ng',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.text('Shared Match'), findsOneWidget);
    },
  );

  testWidgets('filters recents down to active sessions only', (tester) async {
    final now = DateTime(2026, 1, 1, 12);
    final api = _FakeSearchApiClient(
      sessions: <SessionSummary>[
        _session(
          id: 'running',
          title: 'Running Agent',
          updatedAt: now,
          status: 'running',
        ),
        _session(
          id: 'idle',
          title: 'Idle Agent',
          updatedAt: now.subtract(const Duration(minutes: 1)),
        ),
      ],
      searchResults: const <String, List<SessionSummary>>{},
    );

    await _pumpRecentPane(
      tester,
      api: api,
      hosts: const <HostProfile>[host],
      query: '',
      filters: const RecentSessionFilters(runningOnly: true),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Running Agent'), findsOneWidget);
    expect(find.text('Idle Agent'), findsNothing);
  });

  testWidgets('filters recents down to unread sessions only', (tester) async {
    final now = DateTime(2026, 1, 1, 12);
    final readSession = _session(
      id: 'read',
      title: 'Read Session',
      updatedAt: now.subtract(const Duration(minutes: 2)),
    );
    final unreadSession = _session(
      id: 'unread',
      title: 'Unread Session',
      updatedAt: now,
    );
    SessionReadStore.instance.markSeen(
      host,
      readSession.id,
      readSession.updatedAt,
    );
    SessionReadStore.instance.markUnread(host, unreadSession.id);
    await SessionReadStore.instance.flush();
    final api = _FakeSearchApiClient(
      sessions: <SessionSummary>[readSession, unreadSession],
      searchResults: const <String, List<SessionSummary>>{},
    );

    await _pumpRecentPane(
      tester,
      api: api,
      hosts: const <HostProfile>[host],
      query: '',
      filters: const RecentSessionFilters(unreadOnly: true),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Unread Session'), findsOneWidget);
    expect(find.text('Read Session'), findsNothing);
  });
}

Future<void> _pumpRecentPane(
  WidgetTester tester, {
  required ApiClient api,
  required List<HostProfile> hosts,
  required String query,
  RecentSessionFilters filters = const RecentSessionFilters(),
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
            query: query,
            filters: filters,
            hasSavedHosts: hosts.isNotEmpty,
            onOpenSession: (_, _) {},
            onActiveCountChanged: (_) {},
          ),
        ),
      ),
    ),
  );
}

SessionSummary _session({
  required String id,
  required String title,
  required DateTime updatedAt,
  String status = 'loaded',
  num? matchRank,
}) {
  return SessionSummary(
    id: id,
    title: title,
    preview: '$title preview',
    cwd: '/repo',
    createdAt: updatedAt,
    updatedAt: updatedAt,
    source: 'codex',
    provider: 'codex',
    status: status,
    runtime: null,
    gitInfo: null,
    matchRank: matchRank,
  );
}

class _FakeSearchApiClient extends ApiClient {
  _FakeSearchApiClient({
    required this.sessions,
    required this.searchResults,
    this.searchFailures = const <String, Object>{},
  });

  final List<SessionSummary> sessions;
  final Map<String, List<SessionSummary>> searchResults;
  final Map<String, Object> searchFailures;

  @override
  Future<List<SessionSummary>> fetchSessions(HostProfile host, {int? limit}) {
    return Future<List<SessionSummary>>.value(sessions);
  }

  @override
  Future<List<SessionSummary>> searchSessions(
    HostProfile host, {
    required String query,
    int? limit,
  }) {
    final scopedKey = '${host.id}::$query';
    final failure = searchFailures[scopedKey] ?? searchFailures[query];
    if (failure != null) {
      return Future<List<SessionSummary>>.error(failure);
    }
    return Future<List<SessionSummary>>.value(
      searchResults[scopedKey] ??
          searchResults[query] ??
          const <SessionSummary>[],
    );
  }

  @override
  WebSocketChannel openSessionsLive(HostProfile host) {
    final channel = _IdleWebSocketChannel();
    scheduleMicrotask(() {
      channel.emit(jsonEncode(<String, Object?>{'type': 'hello'}));
      channel.emit(
        jsonEncode(<String, Object?>{
          'type': 'snapshot',
          'sessions': sessions.map((session) => session.toJson()).toList(),
        }),
      );
    });
    return channel;
  }
}

class _IdleWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  void emit(dynamic value) {
    if (!_incoming.isClosed) {
      _incoming.add(value);
    }
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _IdleWebSocketSink(_outgoing.sink);

  @override
  Future<void> get ready => Future<void>.value();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;
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
