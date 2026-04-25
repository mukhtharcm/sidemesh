import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

import 'src/screens/desktop_shell.dart';
import 'src/screens/home_screen.dart';
import 'src/background_sync_service.dart';
import 'src/local_notification_service.dart';
import 'src/session_send_outbox_worker.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_controller.dart';

bool get _isMacOSDesktop =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.macOS &&
    Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isMacOSDesktop) {
    // Our macOS build runs unsandboxed by design so keychain access works
    // without extra signing setup. file_picker 11+ assumes a sandboxed app
    // and performs an entitlement check unless we opt out explicitly.
    await FilePicker.skipEntitlementsChecks();
    await WindowManipulator.initialize();
    // Extend content behind the titlebar so the traffic lights float over
    // our UI. We draw our own header spacing inside the shell.
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.hideTitle();
  }
  await LocalNotificationService.instance.initialize();
  await BackgroundSyncService.instance.initialize();
  SessionSendOutboxWorker.instance.start();
  final themeController = await ThemeController.load();
  runApp(SidemeshApp(themeController: themeController));
}

class SidemeshApp extends StatelessWidget {
  const SidemeshApp({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      notifier: themeController,
      child: AnimatedBuilder(
        animation: themeController,
        builder: (context, _) {
          final mode = themeController.mode;
          final variant = themeController.variant;
          final darkPalette = variant.dark;
          final lightPalette = variant.light;
          final isDark =
              mode == ThemeMode.dark ||
              (mode == ThemeMode.system &&
                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
          final activePalette = isDark ? darkPalette : lightPalette;
          final home = _isMacOSDesktop
              ? const DesktopShell()
              : const SidemeshHomeScreen();
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
              theme: buildLightTheme(lightPalette),
              darkTheme: buildDarkTheme(darkPalette),
              themeMode: mode,
              home: home,
            ),
          );
        },
      ),
    );
  }
}
