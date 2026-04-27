import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/windowing.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  final session = SessionSummary(
    id: 'session-1',
    title: 'Debug session',
    preview: 'preview',
    cwd: '/tmp/project',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000300000),
    source: 'cli',
    status: 'active',
    runtime: null,
    gitInfo: null,
  );

  test('session window arguments round-trip through json', () {
    final arguments = SidemeshWindowArguments.sessionWindow(
      hostId: host.id,
      session: session,
    );

    final decoded = SidemeshWindowArguments.fromJsonString(
      arguments.toJsonString(),
    );

    expect(decoded.kind, SidemeshWindowKind.session);
    expect(decoded.hostId, host.id);
    expect(decoded.sessionId, session.id);
    expect(decoded.session?.title, session.title);
  });

  test('invalid window arguments fall back to main window', () {
    expect(
      SidemeshWindowArguments.fromJsonString('{invalid json').kind,
      SidemeshWindowKind.main,
    );
    expect(
      SidemeshWindowArguments.fromJsonString(
        '{"kind":"session","hostId":"","session":{}}',
      ).kind,
      SidemeshWindowKind.main,
    );
  });

  test('session window manager focuses an existing matching window', () async {
    final existing = _FakeWindowHandle(
      SidemeshWindowArguments.sessionWindow(
        hostId: host.id,
        session: session,
      ).toJsonString(),
    );
    final platform = _FakeWindowPlatform(
      windows: <_FakeWindowHandle>[
        _FakeWindowHandle(
          const SidemeshWindowArguments.mainWindow().toJsonString(),
        ),
        existing,
      ],
    );
    final manager = SidemeshSessionWindowManager(
      platform: platform,
      isSupportedOverride: true,
    );

    final result = await manager.openOrFocusSessionWindow(
      host: host,
      session: session,
    );

    expect(result, isTrue);
    expect(existing.showCalls, 1);
    expect(platform.createdArguments, isEmpty);
  });

  test('session window manager creates a new window when missing', () async {
    final platform = _FakeWindowPlatform(
      windows: <_FakeWindowHandle>[
        _FakeWindowHandle(
          const SidemeshWindowArguments.mainWindow().toJsonString(),
        ),
      ],
    );
    final manager = SidemeshSessionWindowManager(
      platform: platform,
      isSupportedOverride: true,
    );

    final result = await manager.openOrFocusSessionWindow(
      host: host,
      session: session,
    );

    expect(result, isTrue);
    expect(platform.createdArguments, hasLength(1));
    expect(
      SidemeshWindowArguments.fromJsonString(
        platform.createdArguments.single,
      ).matchesSession(host, session),
      isTrue,
    );
    expect(platform.createdWindows.single.showCalls, 1);
  });
}

class _FakeWindowPlatform implements SidemeshWindowPlatform {
  _FakeWindowPlatform({required List<_FakeWindowHandle> windows})
    : _windows = windows;

  final List<_FakeWindowHandle> _windows;
  final List<String> createdArguments = <String>[];
  final List<_FakeWindowHandle> createdWindows = <_FakeWindowHandle>[];

  @override
  Future<SidemeshWindowHandle> create(String arguments) async {
    createdArguments.add(arguments);
    final handle = _FakeWindowHandle(arguments);
    createdWindows.add(handle);
    _windows.add(handle);
    return handle;
  }

  @override
  Future<List<SidemeshWindowHandle>> getAll() async {
    return _windows;
  }
}

class _FakeWindowHandle implements SidemeshWindowHandle {
  _FakeWindowHandle(this.arguments);

  @override
  final String arguments;

  int showCalls = 0;

  @override
  Future<void> show() async {
    showCalls += 1;
  }
}
