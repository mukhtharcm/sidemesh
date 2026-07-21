import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screen_awake_controller.dart';
import 'package:sidemesh_mobile/src/screen_awake_settings_store.dart';
import 'package:sidemesh_mobile/src/windowing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    provider: null,
    status: 'active',
    runtime: null,
    gitInfo: null,
  );
  const preview = HostBrowserPreviewInfo(
    id: 'preview-1',
    label: 'Browser localhost:3000',
    url: 'http://127.0.0.1:3000/',
    targetHost: '127.0.0.1',
    targetPort: 3000,
    scheme: 'http',
    cwd: '/tmp/project',
    sessionId: 'session-1',
    profileMode: 'sidemesh',
    status: 'running',
    width: 1280,
    height: 900,
    clients: 1,
    createdAt: 1700000000000,
    updatedAt: 1700000300000,
    lastClientAt: 1700000300000,
    lastFrameAt: 1700000300000,
    lastError: null,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

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

  test('browser preview window arguments round-trip through json', () {
    final arguments = SidemeshWindowArguments.browserPreviewWindow(
      hostId: host.id,
      preview: preview,
    );

    final decoded = SidemeshWindowArguments.fromJsonString(
      arguments.toJsonString(),
    );

    expect(decoded.kind, SidemeshWindowKind.browserPreview);
    expect(decoded.hostId, host.id);
    expect(decoded.previewId, preview.id);
    expect(decoded.preview?.url, preview.url);
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

  test('pop-out windows are supported on desktop platforms', () {
    expect(
      supportsSessionPopoutWindowsForPlatform(
        targetPlatform: TargetPlatform.macOS,
        isMacOS: true,
        isLinux: false,
        isWindows: false,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      supportsSessionPopoutWindowsForPlatform(
        targetPlatform: TargetPlatform.linux,
        isMacOS: false,
        isLinux: true,
        isWindows: false,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      supportsSessionPopoutWindowsForPlatform(
        targetPlatform: TargetPlatform.windows,
        isMacOS: false,
        isLinux: false,
        isWindows: true,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      supportsSessionPopoutWindowsForPlatform(
        targetPlatform: TargetPlatform.android,
        isMacOS: false,
        isLinux: false,
        isWindows: false,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      supportsSessionPopoutWindowsForPlatform(
        targetPlatform: TargetPlatform.linux,
        isMacOS: false,
        isLinux: true,
        isWindows: false,
        isWeb: true,
      ),
      isFalse,
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

  test(
    'browser preview window manager focuses an existing matching window',
    () async {
      final existing = _FakeWindowHandle(
        SidemeshWindowArguments.browserPreviewWindow(
          hostId: host.id,
          preview: preview,
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
      final manager = SidemeshBrowserPreviewWindowManager(
        platform: platform,
        isSupportedOverride: true,
      );

      final result = await manager.openOrFocusBrowserPreviewWindow(
        host: host,
        preview: preview,
      );

      expect(result, isTrue);
      expect(existing.showCalls, 1);
      expect(platform.createdArguments, isEmpty);
    },
  );

  test(
    'browser preview window manager reports whether a matching window is already open',
    () async {
      final existing = _FakeWindowHandle(
        SidemeshWindowArguments.browserPreviewWindow(
          hostId: host.id,
          preview: preview,
        ).toJsonString(),
      );
      final platform = _FakeWindowPlatform(
        windows: <_FakeWindowHandle>[
          existing,
        ],
      );
      final manager = SidemeshBrowserPreviewWindowManager(
        platform: platform,
        isSupportedOverride: true,
      );

      final focused = await manager.focusBrowserPreviewWindowIfOpen(
        host: host,
        preview: preview,
      );

      expect(focused, isTrue);
      expect(existing.showCalls, 1);
      expect(platform.createdArguments, isEmpty);
    },
  );

  test('browser preview window manager creates a new window when missing', () async {
    final platform = _FakeWindowPlatform(
      windows: <_FakeWindowHandle>[
        _FakeWindowHandle(
          const SidemeshWindowArguments.mainWindow().toJsonString(),
        ),
      ],
    );
    final manager = SidemeshBrowserPreviewWindowManager(
      platform: platform,
      isSupportedOverride: true,
    );

    final result = await manager.openOrFocusBrowserPreviewWindow(
      host: host,
      preview: preview,
    );

    expect(result, isTrue);
    expect(platform.createdArguments, hasLength(1));
    expect(
      SidemeshWindowArguments.fromJsonString(
        platform.createdArguments.single,
      ).matchesBrowserPreview(host, preview),
      isTrue,
    );
    expect(platform.createdWindows.single.showCalls, 1);
  });

  test(
    'screen awake coordinator claims relay channel and applies locally',
    () async {
      final store = ScreenAwakeSettingsStore.forTesting();
      final binding = _FakeScreenAwakeBinding();
      final controller = ScreenAwakeController(
        settingsStore: store,
        binding: binding,
      );
      final relayChannel = _FakeRelayChannel();
      final coordinator = WindowScreenAwakeCoordinator(
        controller: controller,
        relayChannel: relayChannel,
        supportsRelayOverride: true,
      );
      addTearDown(controller.stop);

      await store.setKeepScreenAwakeWhileAgentRuns(true);
      await coordinator.start();
      coordinator.setSourceActive('window:a', true);
      await controller.waitForIdle();

      expect(coordinator.isCoordinator, isTrue);
      expect(relayChannel.registerCalls, 1);
      expect(binding.calls, <bool>[true]);
    },
  );

  test('screen awake coordinator relays to an existing coordinator', () async {
    final store = ScreenAwakeSettingsStore.forTesting();
    final binding = _FakeScreenAwakeBinding();
    final controller = ScreenAwakeController(
      settingsStore: store,
      binding: binding,
    );
    final relayChannel = _FakeRelayChannel(
      registerError: WindowChannelException(
        'CHANNEL_LIMIT_REACHED',
        'already registered',
      ),
      registerErrorCount: 1,
    );
    final coordinator = WindowScreenAwakeCoordinator(
      controller: controller,
      relayChannel: relayChannel,
      supportsRelayOverride: true,
    );
    addTearDown(controller.stop);

    await coordinator.start();
    coordinator.setSourceActive('window:b', true);
    await Future<void>.delayed(Duration.zero);

    expect(coordinator.isCoordinator, isFalse);
    expect(relayChannel.invocations, hasLength(1));
    expect(relayChannel.invocations.single.method, 'setSourceActive');
    expect(binding.calls, isEmpty);
  });

  test(
    'screen awake coordinator falls back to local coordination when relay disappears',
    () async {
      final store = ScreenAwakeSettingsStore.forTesting();
      final binding = _FakeScreenAwakeBinding();
      final controller = ScreenAwakeController(
        settingsStore: store,
        binding: binding,
      );
      final relayChannel = _FakeRelayChannel(
        registerError: WindowChannelException(
          'CHANNEL_LIMIT_REACHED',
          'already registered',
        ),
        registerErrorCount: 1,
        invokeError: WindowChannelException('CHANNEL_UNREGISTERED', 'missing'),
      );
      final coordinator = WindowScreenAwakeCoordinator(
        controller: controller,
        relayChannel: relayChannel,
        supportsRelayOverride: true,
      );
      addTearDown(controller.stop);

      await store.setKeepScreenAwakeWhileAgentRuns(true);
      await coordinator.start();
      coordinator.setSourceActive('window:c', true);
      await Future<void>.delayed(Duration.zero);
      await controller.waitForIdle();

      expect(coordinator.isCoordinator, isTrue);
      expect(relayChannel.registerCalls, 2);
      expect(binding.calls, <bool>[true]);
    },
  );
}

class _FakeWindowPlatform implements SidemeshWindowPlatform {
  _FakeWindowPlatform({required List<_FakeWindowHandle> windows})
    : this._(windows);

  _FakeWindowPlatform._(this._windows);

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

class _FakeRelayChannel implements SidemeshWindowRelayChannel {
  _FakeRelayChannel({
    this.registerError,
    this.registerErrorCount = 0,
    this.invokeError,
  });

  final WindowChannelException? registerError;
  int registerErrorCount;
  final WindowChannelException? invokeError;

  int registerCalls = 0;
  MethodCallHandler? handler;
  final List<_RelayInvocation> invocations = <_RelayInvocation>[];

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    invocations.add(_RelayInvocation(method, arguments));
    if (invokeError != null) {
      throw invokeError!;
    }
    return null;
  }

  @override
  Future<void> setMethodCallHandler(MethodCallHandler? nextHandler) async {
    registerCalls += 1;
    if (registerError != null && registerErrorCount > 0) {
      registerErrorCount -= 1;
      throw registerError!;
    }
    handler = nextHandler;
  }
}

class _RelayInvocation {
  const _RelayInvocation(this.method, this.arguments);

  final String method;
  final dynamic arguments;
}

class _FakeScreenAwakeBinding implements ScreenAwakeBinding {
  final List<bool> calls = <bool>[];

  @override
  Future<void> setEnabled(bool enabled) async {
    calls.add(enabled);
  }
}
