// Linux / Windows development harness for visually inspecting the session screen.
//
// Connects to a locally running sidemesh daemon and renders the session screen
// in three layout modes (desktop 1200px, tablet 700px, phone 375px) so you
// can inspect layout, spacing, and behaviour without needing the macOS shell.
//
// Usage:
//   flutter run -t lib/main_linux_dev.dart -d linux
//   flutter run -t lib/main_linux_dev.dart -d windows
//
// Prerequisites:
//   - sidemesh daemon running locally (see README / sidemesh start)
//   - Update _kBaseUrl / _kToken / _kSessionId below to match your local setup

import 'package:flutter/material.dart';
import 'src/api_client.dart';
import 'src/models.dart';
import 'src/screens/session_screen.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_controller.dart';

// ── Configure to match your local daemon ─────────────────────────────────────
const _kBaseUrl = 'http://localhost:8899';
const _kToken = 'test-token';
const _kSessionId = ''; // Leave empty to use the first session from the API,
                        // or paste a session ID from `sidemesh sessions list`.
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeController = await ThemeController.load();
  runApp(_DevHarnessApp(themeController: themeController));
}

final _host = const HostProfile(
  id: 'linux-dev-host',
  label: 'local',
  baseUrl: _kBaseUrl,
  token: _kToken,
  enabled: true,
);

final _placeholderSession = SessionSummary(
  id: _kSessionId.isEmpty ? 'placeholder' : _kSessionId,
  title: 'Session',
  preview: '',
  cwd: '/',
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  source: 'appServer',
  provider: null,
  status: 'idle',
  runtime: null,
  gitInfo: null,
);

class _DevHarnessApp extends StatelessWidget {
  const _DevHarnessApp({required this.themeController});
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
          final typography = themeController.typography;
          return MaterialApp(
            title: 'Sidemesh — Linux dev harness',
            debugShowCheckedModeBanner: false,
            theme: buildLightTheme(variant.light, typography: typography),
            darkTheme: buildDarkTheme(variant.dark, typography: typography),
            themeMode: mode,
            home: const _HarnessFrame(),
          );
        },
      ),
    );
  }
}

class _HarnessFrame extends StatefulWidget {
  const _HarnessFrame();
  @override
  State<_HarnessFrame> createState() => _HarnessFrameState();
}

class _HarnessFrameState extends State<_HarnessFrame> {
  int _view = 0;
  final _api = ApiClient();

  static const _views = [
    (label: 'Desktop (1200px)', width: 1200.0, desktop: true),
    (label: 'Tablet (700px)', width: 700.0, desktop: false),
    (label: 'Phone (375px)', width: 375.0, desktop: false),
  ];

  @override
  Widget build(BuildContext context) {
    final v = _views[_view];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // View switcher
          Container(
            color: Colors.black,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                for (var i = 0; i < _views.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            i == _view ? Colors.blue : Colors.grey[800],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                      onPressed: () => setState(() => _view = i),
                      child: Text(
                        _views[i].label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Session screen
          Expanded(
            child: Center(
              child: SizedBox(
                width: v.width,
                child: ClipRect(
                  child: MediaQuery(
                    data: MediaQueryData(size: Size(v.width, 900)),
                    child: SessionScreen(
                      key: ValueKey('session-$_view'),
                      host: _host,
                      session: _placeholderSession,
                      api: _api,
                      desktopMode: v.desktop,
                      topPadding: v.desktop ? 0 : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
