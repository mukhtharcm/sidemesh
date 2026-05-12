import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../host_store.dart';
import '../models.dart';
import '../onboarding_store.dart';
import '../pairing.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../theme/theme_controller.dart';
import '../widgets/mesh_widgets.dart';
import 'home_screen.dart';
import 'pair_scanner_sheet.dart';

Future<void> showOnboardingScreen(
  BuildContext context, {
  required ThemeController themeController,
}) {
  return Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(
      builder: (_) => OnboardingScreen(themeController: themeController),
    ),
  );
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _pageIndex = 0;
  static const int _pageCount = 3;
  PairingPayload? _pairingSuccess;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_pageIndex < _pageCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic,
      );
      HapticFeedback.lightImpact();
    }
  }

  void _skipIntro() {
    // Jump to the Connect page rather than exiting — new users still need
    // to add a host before the app is useful.
    _pageController.animateToPage(
      _pageCount - 1,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
    );
    HapticFeedback.lightImpact();
  }

  void _skip() {
    _complete();
  }

  Future<void> _complete() async {
    await OnboardingStore.instance.markCompleted();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SidemeshHomeScreen(),
      ),
    );
  }

  Future<void> _onPairingResult(PairingPayload payload) async {
    final store = HostStore();
    final hosts = await store.loadHosts();
    final host = HostProfile(
      id: _randomId(),
      label: payload.label,
      baseUrl: payload.baseUrl,
      token: payload.token,
      enabled: true,
    );
    await store.saveHosts([...hosts, host]);
    HapticFeedback.heavyImpact();
    if (mounted) setState(() => _pairingSuccess = payload);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    await _complete();
  }

  Future<void> _onManualHost(HostProfile host) async {
    final store = HostStore();
    final hosts = await store.loadHosts();
    await store.saveHosts([...hosts, host]);
    HapticFeedback.mediumImpact();
    await _complete();
  }

  void _onPageChanged(int index) {
    setState(() => _pageIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_pageIndex < _pageCount - 1)
                TextButton(
                    onPressed: _skipIntro,
                    child: Text(
                      'Skip intro',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Page view
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                physics: const ClampingScrollPhysics(),
                children: [
                  _WelcomePage(colors: colors),
                  _BriefConnectIntroPage(colors: colors),
                  _pairingSuccess != null
                      ? _PairingSuccessPage(
                          colors: colors,
                          payload: _pairingSuccess!,
                        )
                      : _ConnectPage(
                    colors: colors,
                    onScanQr: () async {
                      final payload = await showPairScannerSheet(context);
                      if (payload != null) {
                        await _onPairingResult(payload);
                      }
                    },
                    onManualEntry: () async {
                      final host = await showModalBottomSheet<HostProfile>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => const _ManualHostSheet(),
                      );
                      if (host != null) {
                        await _onManualHost(host);
                      }
                    },
                    onSkip: _skip,
                  ),
                ],
              ),
            ),
            // Bottom controls
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 12,
                children: [
                  // Dots
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_pageCount, (i) {
                      final active = i == _pageIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: active ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active
                              ? colors.accent
                              : colors.borderStrong,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  // Next / Done button
                  if (_pageIndex < _pageCount - 1)
                    FilledButton(
                      onPressed: _nextPage,
                      child: const Text('Next'),
                    )
                  else
                    FilledButton(
                      onPressed: _skip,
                      child: const Text('Get started'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPageShell extends StatelessWidget {
  const _OnboardingPageShell({
    required this.child,
    required this.horizontalPadding,
  });

  final Widget child;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Page 1: Welcome
// ---------------------------------------------------------------------------

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPageShell(
      horizontalPadding: 32,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Logo container with glow
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.4),
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.15),
                  blurRadius: 40,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Icon(
              Icons.hub_rounded,
              size: 56,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: 40),
          Text(
            'Your coding agents,\nin your pocket.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              height: 1.2,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Control your fleet from anywhere.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2: Connect a host (brief intro)
// ---------------------------------------------------------------------------

class _BriefConnectIntroPage extends StatelessWidget {
  const _BriefConnectIntroPage({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPageShell(
      horizontalPadding: 32,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(
              Icons.cable_rounded,
              size: 46,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: 36),
          Text(
            'Connect a host',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Run the Sidemesh daemon on your Mac or server, then scan the QR code to pair.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 3: Set up & connect
// ---------------------------------------------------------------------------

class _ConnectPage extends StatelessWidget {
  const _ConnectPage({
    required this.colors,
    required this.onScanQr,
    required this.onManualEntry,
    required this.onSkip,
  });

  final AppColors colors;
  final VoidCallback onScanQr;
  final VoidCallback onManualEntry;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPageShell(
      horizontalPadding: 24,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(
              Icons.qr_code_scanner_rounded,
              size: 36,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Set up your daemon',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Install the Sidemesh daemon on the machine you want to control. Then connect this app.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          // Command card
          MeshCard(
            tone: MeshCardTone.muted,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Quick start',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                _CommandLine(
                  text: 'npm install -g github:mukhtharcm/sidemesh',
                  colors: colors,
                ),
                const SizedBox(height: 6),
                _CommandLine(
                  text: 'sidemesh setup',
                  colors: colors,
                ),
                const SizedBox(height: 6),
                _CommandLine(
                  text: 'sidemesh start',
                  colors: colors,
                ),
                const SizedBox(height: 6),
                _CommandLine(
                  text: 'sidemesh pair',
                  colors: colors,
                ),
                const SizedBox(height: 12),
                Text(
                  'On macOS or Linux, install the background service if you want the app\'s Restart and Update buttons to bring the host back on their own.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onScanQr,
              child: const Text('Scan QR code'),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: onManualEntry,
                child: const Text('Enter manually'),
              ),
              Text(
                ' · ',
                style: TextStyle(color: colors.textTertiary),
              ),
              TextButton(
                onPressed: onSkip,
                child: const Text('I\'ll do this later'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommandLine extends StatelessWidget {
  const _CommandLine({required this.text, required this.colors});

  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.codeBorder),
      ),
      child: Row(
        children: [
          Text(
            '\$',
            style: monoStyle(
              color: colors.accent,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: monoStyle(
                color: colors.codeForeground,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Manual host entry sheet
// ---------------------------------------------------------------------------

class _ManualHostSheet extends StatefulWidget {
  const _ManualHostSheet();

  @override
  State<_ManualHostSheet> createState() => _ManualHostSheetState();
}

class _ManualHostSheetState extends State<_ManualHostSheet> {
  final _labelController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _labelController.dispose();
    _baseUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _labelController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    final token = _tokenController.text.trim();

    if (label.isEmpty || baseUrl.isEmpty || token.isEmpty) {
      setState(() => _error = 'All fields are required.');
      return;
    }

    // Simple URL validation
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() => _error = 'Enter a valid http:// or https:// URL.');
      return;
    }

    Navigator.of(context).pop(
      HostProfile(
        id: _randomId(),
        label: label,
        baseUrl: baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        token: token,
        enabled: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottom + 16),
        child: MeshCard(
          tone: MeshCardTone.elevated,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'Add host manually',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      MeshIconButton(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _labelController,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'My MacBook',
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://myhost.tailnet:3000',
                    ),
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _tokenController,
                    decoration: const InputDecoration(
                      labelText: 'Shared token',
                      hintText: 'Paste from sidemesh setup',
                    ),
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: colors.danger,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _submit,
                    child: const Text('Save host'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _randomId() {
  final random = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(
    12,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

// ---------------------------------------------------------------------------
// Pairing success overlay (shown for ~1.6 s before advancing)
// ---------------------------------------------------------------------------

class _PairingSuccessPage extends StatelessWidget {
  const _PairingSuccessPage({required this.colors, required this.payload});

  final AppColors colors;
  final PairingPayload payload;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPageShell(
      horizontalPadding: 32,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colors.successMuted,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_rounded,
              size: 40,
              color: colors.success,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Connected!',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            payload.label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: AppWeights.title,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            payload.baseUrl,
            textAlign: TextAlign.center,
            style: monoStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
