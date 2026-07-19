import 'package:flutter/material.dart';

import 'src/create_session_defaults_store.dart';
import 'src/onboarding_store.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/screen_awake_settings_store.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CreateSessionDefaultsStore.instance.ensureLoaded();
  await ScreenAwakeSettingsStore.instance.ensureLoaded();
  final themeController = await ThemeController.load();
  final onboardingCompleted = await OnboardingStore.instance.isCompleted;
  runApp(
    SidemeshWebApp(
      themeController: themeController,
      onboardingCompleted: onboardingCompleted,
    ),
  );
}

class SidemeshWebApp extends StatelessWidget {
  const SidemeshWebApp({
    super.key,
    required this.themeController,
    required this.onboardingCompleted,
  });

  final ThemeController themeController;
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
          return MaterialApp(
            title: 'Sidemesh',
            debugShowCheckedModeBanner: false,
            theme: buildLightTheme(variant.light, typography: typography),
            darkTheme: buildDarkTheme(variant.dark, typography: typography),
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
            home: onboardingCompleted
                ? const SidemeshHomeScreen()
                : const OnboardingScreen(),
          );
        },
      ),
    );
  }
}
