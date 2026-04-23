import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

import 'src/screens/desktop_shell.dart';
import 'src/screens/home_screen.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_controller.dart';

bool get _isMacOSDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS && Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isMacOSDesktop) {
    await WindowManipulator.initialize();
    // Extend content behind the titlebar so the traffic lights float over
    // our UI. We draw our own header spacing inside the shell.
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.hideTitle();
  }
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
          final isDark = mode == ThemeMode.dark ||
              (mode == ThemeMode.system &&
                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
          final home = _isMacOSDesktop
              ? const DesktopShell()
              : const SidemeshHomeScreen();
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: isDark
                ? SystemUiOverlayStyle.light.copyWith(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: const Color(0xFF0B0F14),
                    systemNavigationBarIconBrightness: Brightness.light,
                  )
                : SystemUiOverlayStyle.dark.copyWith(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: const Color(0xFFF6EFE2),
                    systemNavigationBarIconBrightness: Brightness.dark,
                  ),
            child: MaterialApp(
              title: 'Sidemesh',
              debugShowCheckedModeBanner: false,
              theme: buildLightTheme(),
              darkTheme: buildDarkTheme(),
              themeMode: mode,
              home: home,
            ),
          );
        },
      ),
    );
  }
}
