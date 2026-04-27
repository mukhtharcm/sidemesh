import 'dart:convert';
import 'dart:io' show Platform;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

bool get supportsSessionPopoutWindows =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.macOS &&
    Platform.isMacOS;

enum SidemeshWindowKind { main, session }

@immutable
class SidemeshWindowArguments {
  const SidemeshWindowArguments._({
    required this.kind,
    this.hostId,
    this.session,
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

  final SidemeshWindowKind kind;
  final String? hostId;
  final SessionSummary? session;

  String get sessionId => session?.id ?? '';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': switch (kind) {
      SidemeshWindowKind.main => 'main',
      SidemeshWindowKind.session => 'session',
    },
    if ((hostId ?? '').isNotEmpty) 'hostId': hostId,
    if (session != null) 'session': session!.toJson(),
  };

  String toJsonString() => jsonEncode(toJson());

  bool matchesSession(HostProfile host, SessionSummary nextSession) {
    return kind == SidemeshWindowKind.session &&
        hostId == host.id &&
        sessionId == nextSession.id;
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
        _ => SidemeshWindowKind.main,
      };
      if (kind == SidemeshWindowKind.main) {
        return const SidemeshWindowArguments.mainWindow();
      }
      final hostId = decoded['hostId'] as String?;
      final sessionJson = decoded['session'];
      if ((hostId ?? '').trim().isEmpty ||
          sessionJson is! Map<String, dynamic>) {
        return const SidemeshWindowArguments.mainWindow();
      }
      return SidemeshWindowArguments.sessionWindow(
        hostId: hostId!.trim(),
        session: SessionSummary.fromJson(sessionJson),
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
