import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'screen_awake_controller.dart';

bool get supportsSessionPopoutWindows =>
    supportsSessionPopoutWindowsForPlatform(
      targetPlatform: defaultTargetPlatform,
      isMacOS: !kIsWeb && Platform.isMacOS,
      isLinux: !kIsWeb && Platform.isLinux,
      isWindows: !kIsWeb && Platform.isWindows,
      isWeb: kIsWeb,
    );

@visibleForTesting
bool supportsSessionPopoutWindowsForPlatform({
  required TargetPlatform targetPlatform,
  required bool isMacOS,
  required bool isLinux,
  required bool isWindows,
  required bool isWeb,
}) {
  if (isWeb) {
    return false;
  }
  return switch (targetPlatform) {
    TargetPlatform.macOS => isMacOS,
    TargetPlatform.linux => isLinux,
    TargetPlatform.windows => isWindows,
    TargetPlatform.android ||
    TargetPlatform.fuchsia ||
    TargetPlatform.iOS => false,
  };
}

enum SidemeshWindowKind { main, session, browserPreview }

@immutable
class SidemeshWindowArguments {
  const SidemeshWindowArguments._({
    required this.kind,
    this.hostId,
    this.session,
    this.preview,
  });

  const SidemeshWindowArguments.mainWindow()
    : this._(kind: SidemeshWindowKind.main);

  const SidemeshWindowArguments.sessionWindow({
    required String hostId,
    required SessionSummary session,
  }) : this._(
         kind: SidemeshWindowKind.session,
         hostId: hostId,
         session: session,
       );

  const SidemeshWindowArguments.browserPreviewWindow({
    required String hostId,
    required HostBrowserPreviewInfo preview,
  }) : this._(
         kind: SidemeshWindowKind.browserPreview,
         hostId: hostId,
         preview: preview,
       );

  final SidemeshWindowKind kind;
  final String? hostId;
  final SessionSummary? session;
  final HostBrowserPreviewInfo? preview;

  String get sessionId => session?.id ?? '';
  String get previewId => preview?.id ?? '';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': switch (kind) {
      SidemeshWindowKind.main => 'main',
      SidemeshWindowKind.session => 'session',
      SidemeshWindowKind.browserPreview => 'browserPreview',
    },
    if ((hostId ?? '').isNotEmpty) 'hostId': hostId,
    if (session != null) 'session': session!.toJson(),
    if (preview != null) 'preview': preview!.toJson(),
  };

  String toJsonString() => jsonEncode(toJson());

  bool matchesSession(HostProfile host, SessionSummary nextSession) {
    return kind == SidemeshWindowKind.session &&
        hostId == host.id &&
        sessionId == nextSession.id;
  }

  bool matchesBrowserPreview(
    HostProfile host,
    HostBrowserPreviewInfo nextPreview,
  ) {
    return kind == SidemeshWindowKind.browserPreview &&
        hostId == host.id &&
        previewId == nextPreview.id;
  }

  static SidemeshWindowArguments fromJsonString(String? raw) {
    if ((raw ?? '').trim().isEmpty) {
      return const SidemeshWindowArguments.mainWindow();
    }
    try {
      final decoded = jsonDecode(raw!);
      if (decoded is! Map<String, dynamic>) {
        return const SidemeshWindowArguments.mainWindow();
      }
      final kind = switch (decoded['kind']) {
        'session' => SidemeshWindowKind.session,
        'browserPreview' => SidemeshWindowKind.browserPreview,
        _ => SidemeshWindowKind.main,
      };
      if (kind == SidemeshWindowKind.main) {
        return const SidemeshWindowArguments.mainWindow();
      }
      final hostId = decoded['hostId'] as String?;
      if ((hostId ?? '').trim().isEmpty) {
        return const SidemeshWindowArguments.mainWindow();
      }
      if (kind == SidemeshWindowKind.session) {
        final sessionJson = decoded['session'];
        if (sessionJson is! Map<String, dynamic>) {
          return const SidemeshWindowArguments.mainWindow();
        }
        return SidemeshWindowArguments.sessionWindow(
          hostId: hostId!.trim(),
          session: SessionSummary.fromJson(sessionJson),
        );
      }
      final previewJson = decoded['preview'];
      if (previewJson is! Map<String, dynamic>) {
        return const SidemeshWindowArguments.mainWindow();
      }
      return SidemeshWindowArguments.browserPreviewWindow(
        hostId: hostId!.trim(),
        preview: HostBrowserPreviewInfo.fromJson(previewJson),
      );
    } catch (_) {
      return const SidemeshWindowArguments.mainWindow();
    }
  }
}

@immutable
class SidemeshWindowLaunchState {
  const SidemeshWindowLaunchState({required this.arguments, this.windowId});

  final SidemeshWindowArguments arguments;
  final String? windowId;

  bool get shouldStartGlobalServices =>
      arguments.kind == SidemeshWindowKind.main;
}

Future<SidemeshWindowLaunchState> resolveCurrentWindowLaunchState() async {
  if (!supportsSessionPopoutWindows) {
    return const SidemeshWindowLaunchState(
      arguments: SidemeshWindowArguments.mainWindow(),
    );
  }
  try {
    final controller = await WindowController.fromCurrentEngine();
    return SidemeshWindowLaunchState(
      arguments: SidemeshWindowArguments.fromJsonString(controller.arguments),
      windowId: controller.windowId,
    );
  } catch (_) {
    return const SidemeshWindowLaunchState(
      arguments: SidemeshWindowArguments.mainWindow(),
    );
  }
}

abstract class SidemeshWindowHandle {
  String get arguments;
  Future<void> show();
}

abstract class SidemeshWindowPlatform {
  Future<List<SidemeshWindowHandle>> getAll();
  Future<SidemeshWindowHandle> create(String arguments);
}

class DesktopMultiWindowHandle implements SidemeshWindowHandle {
  DesktopMultiWindowHandle(this._controller);

  final WindowController _controller;

  @override
  String get arguments => _controller.arguments;

  @override
  Future<void> show() => _controller.show();
}

class DesktopMultiWindowPlatform implements SidemeshWindowPlatform {
  const DesktopMultiWindowPlatform();

  @override
  Future<SidemeshWindowHandle> create(String arguments) async {
    final controller = await WindowController.create(
      WindowConfiguration(hiddenAtLaunch: true, arguments: arguments),
    );
    return DesktopMultiWindowHandle(controller);
  }

  @override
  Future<List<SidemeshWindowHandle>> getAll() async {
    final controllers = await WindowController.getAll();
    return controllers
        .map(DesktopMultiWindowHandle.new)
        .toList(growable: false);
  }
}

abstract class SidemeshWindowRelayChannel {
  Future<void> setMethodCallHandler(MethodCallHandler? handler);
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]);
}

class DesktopMultiWindowRelayChannel implements SidemeshWindowRelayChannel {
  DesktopMultiWindowRelayChannel(String name)
    : _channel = WindowMethodChannel(name, mode: ChannelMode.unidirectional);

  final WindowMethodChannel _channel;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    return _channel.invokeMethod<T>(method, arguments);
  }

  @override
  Future<void> setMethodCallHandler(MethodCallHandler? handler) {
    return _channel.setMethodCallHandler(handler);
  }
}

class WindowScreenAwakeCoordinator {
  WindowScreenAwakeCoordinator({
    ScreenAwakeController? controller,
    SidemeshWindowRelayChannel? relayChannel,
    bool? supportsRelayOverride,
  }) : _controller = controller ?? ScreenAwakeController.instance,
       _relayChannel =
           relayChannel ??
           DesktopMultiWindowRelayChannel(_screenAwakeRelayChannelName),
       _supportsRelayOverride = supportsRelayOverride;

  static const String _screenAwakeRelayChannelName =
      'sidemesh/window_screen_awake';

  static final WindowScreenAwakeCoordinator instance =
      WindowScreenAwakeCoordinator();

  final ScreenAwakeController _controller;
  final SidemeshWindowRelayChannel _relayChannel;
  final bool? _supportsRelayOverride;

  bool _isCoordinator = false;
  bool _localControllerStarted = false;
  Future<void>? _claimFuture;

  bool get _supportsRelay =>
      _supportsRelayOverride ?? supportsSessionPopoutWindows;

  Future<void> start() async {
    if (!_supportsRelay) {
      await _startLocalController();
      _isCoordinator = true;
      return;
    }
    await _tryClaimCoordinator();
  }

  void setSourceActive(String key, bool active) {
    unawaited(_setSourceActive(key, active));
  }

  void clearSource(String key) {
    unawaited(_clearSource(key));
  }

  Future<void> _setSourceActive(String key, bool active) async {
    if (_isCoordinator || !_supportsRelay) {
      _controller.setSourceActive(key, active);
      return;
    }
    try {
      await _relayChannel.invokeMethod<void>(
        'setSourceActive',
        <String, Object>{'key': key, 'active': active},
      );
    } on WindowChannelException {
      await _tryClaimCoordinator();
      if (_isCoordinator) {
        _controller.setSourceActive(key, active);
      }
    }
  }

  Future<void> _clearSource(String key) async {
    if (_isCoordinator || !_supportsRelay) {
      _controller.clearSource(key);
      return;
    }
    try {
      await _relayChannel.invokeMethod<void>('clearSource', <String, Object>{
        'key': key,
      });
    } on WindowChannelException {
      await _tryClaimCoordinator();
      if (_isCoordinator) {
        _controller.clearSource(key);
      }
    }
  }

  Future<void> _tryClaimCoordinator() {
    return _claimFuture ??= _claimCoordinator().whenComplete(() {
      _claimFuture = null;
    });
  }

  Future<void> _claimCoordinator() async {
    if (_isCoordinator) {
      return;
    }
    try {
      await _relayChannel.setMethodCallHandler(_handleRelayCall);
      _isCoordinator = true;
      await _startLocalController();
    } on WindowChannelException {
      _isCoordinator = false;
    }
  }

  Future<dynamic> _handleRelayCall(MethodCall call) async {
    final arguments = call.arguments;
    final payload = arguments is Map
        ? Map<String, dynamic>.from(arguments)
        : const <String, dynamic>{};
    final key = payload['key'] as String?;
    if ((key ?? '').isEmpty) {
      return null;
    }
    switch (call.method) {
      case 'setSourceActive':
        _controller.setSourceActive(key!, payload['active'] == true);
        return null;
      case 'clearSource':
        _controller.clearSource(key!);
        return null;
      default:
        throw MissingPluginException('Unknown relay method ${call.method}');
    }
  }

  Future<void> _startLocalController() async {
    if (_localControllerStarted) {
      return;
    }
    _localControllerStarted = true;
    await _controller.start();
  }

  @visibleForTesting
  bool get isCoordinator => _isCoordinator;
}

class SidemeshSessionWindowManager {
  SidemeshSessionWindowManager({
    SidemeshWindowPlatform? platform,
    bool? isSupportedOverride,
  }) : _platform = platform ?? const DesktopMultiWindowPlatform(),
       _isSupportedOverride = isSupportedOverride;

  static final SidemeshSessionWindowManager instance =
      SidemeshSessionWindowManager();

  final SidemeshWindowPlatform _platform;
  final bool? _isSupportedOverride;

  bool get isSupported => _isSupportedOverride ?? supportsSessionPopoutWindows;

  Future<bool> openOrFocusSessionWindow({
    required HostProfile host,
    required SessionSummary session,
  }) async {
    if (!isSupported) {
      return false;
    }
    final requested = SidemeshWindowArguments.sessionWindow(
      hostId: host.id,
      session: session,
    );
    final windows = await _platform.getAll();
    for (final window in windows) {
      final parsed = SidemeshWindowArguments.fromJsonString(window.arguments);
      if (!parsed.matchesSession(host, session)) {
        continue;
      }
      await window.show();
      return true;
    }
    final created = await _platform.create(requested.toJsonString());
    await created.show();
    return true;
  }
}

class SidemeshBrowserPreviewWindowManager {
  SidemeshBrowserPreviewWindowManager({
    SidemeshWindowPlatform? platform,
    bool? isSupportedOverride,
  }) : _platform = platform ?? const DesktopMultiWindowPlatform(),
       _isSupportedOverride = isSupportedOverride;

  static final SidemeshBrowserPreviewWindowManager instance =
      SidemeshBrowserPreviewWindowManager();

  final SidemeshWindowPlatform _platform;
  final bool? _isSupportedOverride;

  bool get isSupported => _isSupportedOverride ?? supportsSessionPopoutWindows;

  Future<bool> focusBrowserPreviewWindowIfOpen({
    required HostProfile host,
    required HostBrowserPreviewInfo preview,
  }) async {
    if (!isSupported) {
      return false;
    }
    final windows = await _platform.getAll();
    for (final window in windows) {
      final parsed = SidemeshWindowArguments.fromJsonString(window.arguments);
      if (!parsed.matchesBrowserPreview(host, preview)) {
        continue;
      }
      await window.show();
      return true;
    }
    return false;
  }

  Future<bool> openOrFocusBrowserPreviewWindow({
    required HostProfile host,
    required HostBrowserPreviewInfo preview,
  }) async {
    if (!isSupported) {
      return false;
    }
    final focused = await focusBrowserPreviewWindowIfOpen(
      host: host,
      preview: preview,
    );
    if (focused) {
      return true;
    }
    final requested = SidemeshWindowArguments.browserPreviewWindow(
      hostId: host.id,
      preview: preview,
    );
    final created = await _platform.create(requested.toJsonString());
    await created.show();
    return true;
  }
}
