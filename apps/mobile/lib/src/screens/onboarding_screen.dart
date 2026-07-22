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
import '../widgets/mesh_widgets.dart';
import 'home_screen.dart';
import 'pair_scanner_sheet.dart';

Future<void> showOnboardingScreen(BuildContext context) {
  return Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(builder: (_) => const OnboardingScreen()),
  );
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _pageIndex = 0;
  static const int _pageCount = 4;
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
      MaterialPageRoute<void>(builder: (_) => SidemeshHomeScreen()),
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
                        'Go to setup',
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
                  _HowItWorksPage(colors: colors),
                  _ActionsPage(colors: colors),
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
                            final host = await Navigator.of(context)
                                .push<HostProfile>(
                                  MaterialPageRoute<HostProfile>(
                                    builder: (_) =>
                                        const HostEditorSheet(fullPage: true),
                                  ),
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
                          color: active ? colors.accent : colors.borderStrong,
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
                      child: const Text('Finish later'),
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
          // Logo container
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: colors.accent.withValues(alpha: 0.4)),
            ),
            child: Icon(Icons.hub_rounded, size: 56, color: colors.accent),
          ),
          const SizedBox(height: 40),
          Text(
            'Stay in control\naway from your desk.',
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
            'Connect one machine, then check sessions, approvals, files, and terminals from your phone or desktop.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _FeatureChip(
                icon: Icons.link_rounded,
                label: 'Connect once',
                colors: colors,
              ),
              _FeatureChip(
                icon: Icons.rule_folder_rounded,
                label: 'Review approvals',
                colors: colors,
              ),
              _FeatureChip(
                icon: Icons.playlist_play_rounded,
                label: 'Pick up later',
                colors: colors,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2: How it works
// ---------------------------------------------------------------------------

class _HowItWorksPage extends StatelessWidget {
  const _HowItWorksPage({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final colors = this.colors;
    return _OnboardingPageShell(
      horizontalPadding: 32,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Connect your first machine.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Most people start with one machine. You can add more after the first pairing works.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          _StepItem(
            number: '1',
            title: 'Install Sidemesh',
            body: 'Run the setup commands on the machine you want to manage.',
            colors: colors,
          ),
          const SizedBox(height: 16),
          _StepItem(
            number: '2',
            title: 'Pair this app',
            body:
                'Open the pairing code on that machine, then scan it here or add the machine manually.',
            colors: colors,
          ),
          const SizedBox(height: 16),
          _StepItem(
            number: '3',
            title: 'Jump back in',
            body:
                'Open a session, check approvals, or use the terminal when the agent needs you.',
            colors: colors,
          ),
          const SizedBox(height: 20),
          Text(
            'About a minute if you already have terminal access.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _StepItem extends StatelessWidget {
  const _StepItem({
    required this.number,
    required this.title,
    required this.body,
    required this.colors,
  });

  final String number;
  final String title;
  final String body;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.accent.withValues(alpha: 0.4)),
          ),
          alignment: Alignment.center,
          child: Text(
            number,
            style: monoStyle(
              color: colors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Page 3: What you can do
// ---------------------------------------------------------------------------

class _ActionsPage extends StatelessWidget {
  const _ActionsPage({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPageShell(
      horizontalPadding: 24,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Know what needs you.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The goal is simple: see the next action quickly, then jump back into the right machine.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 32),
          MeshCard(
            tone: MeshCardTone.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ActionLine(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'Sessions',
                  body: 'See what each agent is doing and jump back in.',
                  colors: colors,
                ),
                const SizedBox(height: 14),
                _ActionLine(
                  icon: Icons.rule_folder_rounded,
                  title: 'Approvals',
                  body:
                      'Approve or reject risky actions without reopening your laptop.',
                  colors: colors,
                ),
                const SizedBox(height: 14),
                _ActionLine(
                  icon: Icons.folder_open_rounded,
                  title: 'Files',
                  body: 'Check changed files, logs, and saved outputs.',
                  colors: colors,
                ),
                const SizedBox(height: 14),
                _ActionLine(
                  icon: Icons.terminal_rounded,
                  title: 'Terminal',
                  body: 'Open a terminal when the agent needs a hand.',
                  colors: colors,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Best first step: connect a machine and open one test session.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _ActionLine extends StatelessWidget {
  const _ActionLine({
    required this.icon,
    required this.title,
    required this.body,
    required this.colors,
  });

  final IconData icon;
  final String title;
  final String body;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: colors.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeatureChip extends StatelessWidget {
  const _FeatureChip({
    required this.icon,
    required this.label,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colors.textSecondary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 4: Set up & connect
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
              border: Border.all(color: colors.accent.withValues(alpha: 0.4)),
            ),
            child: Icon(
              Icons.qr_code_scanner_rounded,
              size: 36,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Add your first machine',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Run these commands on the machine you want to manage. Then scan the pairing code here.',
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
                _CommandLine(text: 'npm install -g sidemesh', colors: colors),
                const SizedBox(height: 6),
                _CommandLine(text: 'sidemesh setup', colors: colors),
                const SizedBox(height: 6),
                _CommandLine(text: 'sidemesh pair', colors: colors),
                const SizedBox(height: 12),
                Text(
                  'If the machine is already set up, you can scan the pairing code right away or add it manually.',
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
                child: const Text('Add manually'),
              ),
              Text(' · ', style: TextStyle(color: colors.textTertiary)),
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
          Text('\$', style: monoStyle(color: colors.accent, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: monoStyle(color: colors.codeForeground, fontSize: 12),
            ),
          ),
        ],
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
            child: Icon(Icons.check_rounded, size: 40, color: colors.success),
          ),
          const SizedBox(height: 28),
          Text(
            'Machine added',
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
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: AppWeights.title),
          ),
          const SizedBox(height: 4),
          Text(
            payload.baseUrl,
            textAlign: TextAlign.center,
            style: monoStyle(color: colors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Text(
            'Ready to open sessions on this machine.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
