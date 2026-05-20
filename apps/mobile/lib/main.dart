import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'src/onboarding_store.dart';
import 'src/screens/browser_preview_window_screen.dart';
import 'src/screens/desktop_shell.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/screens/session_window_screen.dart';
import 'src/background_sync_service.dart';
import 'src/create_session_defaults_store.dart';
import 'src/local_notification_service.dart';
import 'src/screen_awake_settings_store.dart';
import 'src/session_send_outbox_worker.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_controller.dart';
import 'src/windowing.dart';

bool get _isMacOSDesktop =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.macOS &&
    Platform.isMacOS;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureDesktopRuntimeBackends();
  final launchState = await resolveCurrentWindowLaunchState();
  if (_isMacOSDesktop) {
    // Our macOS build runs unsandboxed by design so keychain access works
    // without extra signing setup. file_picker 11+ assumes a sandboxed app
    // and performs an entitlement check unless we opt out explicitly.
    await FilePicker.skipEntitlementsChecks();
    if (launchState.arguments.kind == SidemeshWindowKind.main) {
      await WindowManipulator.initialize();
      // Extend content behind the titlebar so the traffic lights float over
      // our UI. We draw our own header spacing inside the shell.
      await WindowManipulator.makeTitlebarTransparent();
      await WindowManipulator.enableFullSizeContentView();
      await WindowManipulator.hideTitle();
    }
  }
  await CreateSessionDefaultsStore.instance.ensureLoaded();
  await ScreenAwakeSettingsStore.instance.ensureLoaded();
  final themeController = await ThemeController.load();
  final onboardingCompleted = await OnboardingStore.instance.isCompleted;
  runApp(
    SidemeshApp(
      themeController: themeController,
      launchState: launchState,
      onboardingCompleted: onboardingCompleted,
    ),
  );
  unawaited(_startPostLaunchServices(launchState));
}

void _configureDesktopRuntimeBackends() {
  if (kIsWeb) {
    return;
  }
  if (Platform.isLinux || Platform.isWindows) {
    // Desktop builds need the sqflite FFI backend instead of the mobile
    // method-channel implementation.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  if (Platform.isLinux) {
    // package:video_player does not ship a native Linux playback backend,
    // so route it through media_kit there.
    VideoPlayerMediaKit.ensureInitialized(linux: true);
  }
}

Future<void> _startPostLaunchServices(
  SidemeshWindowLaunchState launchState,
) async {
  try {
    await WindowScreenAwakeCoordinator.instance.start();
  } catch (_) {
    // Keep-screen-awake is best-effort. It must never block app launch or
    // secondary window startup.
  }
  if (!launchState.shouldStartGlobalServices) {
    return;
  }
  try {
    await LocalNotificationService.instance.initialize();
  } catch (_) {
    // Notifications are optional; the app must still be usable without them.
  }
  try {
    await BackgroundSyncService.instance.initialize();
  } catch (_) {
    // Foreground usage and websocket updates still work if background sync
    // cannot initialize on this platform/build.
  }
  SessionSendOutboxWorker.instance.start();
}

class SidemeshApp extends StatelessWidget {
  const SidemeshApp({
    super.key,
    required this.themeController,
    required this.launchState,
    required this.onboardingCompleted,
  });

  final ThemeController themeController;
  final SidemeshWindowLaunchState launchState;
  final bool onboardingCompleted;

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      notifier: themeController,
      child: AnimatedBuilder(
        animation: themeController,
        builder: (context, _) {
          final mode = themeController.mode;
          final variant = themeController.variant;
          final typography = themeController.typography;
          final darkPalette = variant.dark;
          final lightPalette = variant.light;
          final isDark =
              mode == ThemeMode.dark ||
              (mode == ThemeMode.system &&
                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
          final activePalette = isDark ? darkPalette : lightPalette;
          final home = switch (launchState.arguments.kind) {
            SidemeshWindowKind.main => _isMacOSDesktop
                ? const DesktopShell()
                : onboardingCompleted
                    ? const SidemeshHomeScreen()
                    : const OnboardingScreen(),
            SidemeshWindowKind.session => SessionWindowScreen(
              arguments: launchState.arguments,
              windowId: launchState.windowId,
            ),
            SidemeshWindowKind.browserPreview => BrowserPreviewWindowScreen(
              arguments: launchState.arguments,
            ),
          };
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: isDark
                ? SystemUiOverlayStyle.light.copyWith(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: activePalette.canvas,
                    systemNavigationBarIconBrightness: Brightness.light,
                  )
                : SystemUiOverlayStyle.dark.copyWith(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: activePalette.canvas,
                    systemNavigationBarIconBrightness: Brightness.dark,
                  ),
            child: MaterialApp(
              title: 'Sidemesh',
              debugShowCheckedModeBanner: false,
              theme: buildLightTheme(lightPalette, typography: typography),
              darkTheme: buildDarkTheme(darkPalette, typography: typography),
              themeMode: mode,
              builder: (context, child) {
                final media = MediaQuery.maybeOf(context);
                final content = child ?? const SizedBox.shrink();
                if (media == null || typography.isStandardScale) {
                  return content;
                }
                return MediaQuery(
                  data: media.copyWith(
                    textScaler: typography.buildTextScaler(media.textScaler),
                  ),
                  child: content,
                );
              },
              home: home,
            ),
          );
        },
      ),
    );
  }
}
