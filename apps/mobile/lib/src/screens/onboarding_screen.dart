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
import '../theme/theme_controller.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/theme_picker.dart';
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
  static const int _pageCount = 5;

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
    HapticFeedback.mediumImpact();
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
                  TextButton(
                    onPressed: _skip,
                    child: Text(
                      'Skip',
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
                  _ThemePage(
                    colors: colors,
                    themeController: widget.themeController,
                  ),
                  _ConnectPage(
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
                      child: const Text('Start'),
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
          _TypewriterText(
            text: 'Control your fleet from anywhere.',
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
// Page 2: How it works
// ---------------------------------------------------------------------------

class _HowItWorksPage extends StatefulWidget {
  const _HowItWorksPage({required this.colors});

  final AppColors colors;

  @override
  State<_HowItWorksPage> createState() => _HowItWorksPageState();
}

class _HowItWorksPageState extends State<_HowItWorksPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return _OnboardingPageShell(
      horizontalPadding: 32,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 220,
            height: 160,
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, child) {
                return CustomPaint(
                  painter: _MeshDiagramPainter(
                    colors: colors,
                    progress: _anim.value,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 40),
          Text(
            'How it works',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 20),
          _StepItem(
            number: '1',
            title: 'Run the daemon',
            body: 'Install a small agent on your MacBook or server.',
            colors: colors,
          ),
          const SizedBox(height: 16),
          _StepItem(
            number: '2',
            title: 'Connect this app',
            body: 'Scan the QR code or enter your host details.',
            colors: colors,
          ),
          const SizedBox(height: 16),
          _StepItem(
            number: '3',
            title: 'Chat and control',
            body: 'Start sessions, review changes, and approve actions.',
            colors: colors,
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
            border: Border.all(
              color: colors.accent.withValues(alpha: 0.4),
            ),
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

class _MeshDiagramPainter extends CustomPainter {
  _MeshDiagramPainter({required this.colors, required this.progress});

  final AppColors colors;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final nodePaint = Paint()
      ..style = PaintingStyle.fill;

    final nodes = [
      Offset(size.width * 0.2, size.height * 0.35),
      Offset(size.width * 0.8, size.height * 0.35),
      Offset(size.width * 0.5, size.height * 0.75),
    ];

    // Draw edges with pulsing opacity
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final t = (progress + i * 0.33) % 1.0;
        final opacity = 0.15 + 0.25 * (t < 0.5 ? t * 2 : (1 - t) * 2);
        paint.color = colors.accent.withValues(alpha: opacity);
        canvas.drawLine(nodes[i], nodes[j], paint);
      }
    }

    // Draw nodes
    for (var i = 0; i < nodes.length; i++) {
      final t = (progress + i * 0.33) % 1.0;
      final radius = 8 + 3 * (t < 0.5 ? t * 2 : (1 - t) * 2);
      nodePaint.color = colors.accent.withValues(alpha: 0.15);
      canvas.drawCircle(nodes[i], radius + 6, nodePaint);
      nodePaint.color = colors.accent;
      canvas.drawCircle(nodes[i], radius, nodePaint);
    }

    // Labels
    final labelStyle = TextStyle(
      color: colors.textTertiary,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      fontFamily: 'SpaceGrotesk',
    );
    final labels = ['Your machine', 'Daemon', 'Phone'];
    for (var i = 0; i < nodes.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );
      tp.layout();
      tp.paint(
        canvas,
        Offset(
          nodes[i].dx - tp.width / 2,
          nodes[i].dy + 20,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MeshDiagramPainter old) {
    return old.progress != progress || old.colors != colors;
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
            'Chat, approve, inspect.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Everything you need to steer your agents remotely.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 32),
          // Fake session card
          MeshCard(
            tone: MeshCardTone.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    MeshPill(
                      label: 'codex',
                      tone: MeshPillTone.accent,
                      icon: Icons.memory_rounded,
                    ),
                    MeshPill(
                      label: 'approval',
                      tone: MeshPillTone.warning,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.codeBackground,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.codeBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FakeDiffLine(
                        prefix: '+',
                        text: '  const greeting = "Hello, fleet";',
                        prefixColor: colors.diffAddGlyph,
                        lineColor: colors.diffAddLine,
                      ),
                      _FakeDiffLine(
                        prefix: '+',
                        text: '  console.log(greeting);',
                        prefixColor: colors.diffAddGlyph,
                        lineColor: colors.diffAddLine,
                      ),
                      _FakeDiffLine(
                        prefix: '-',
                        text: '  // old code removed',
                        prefixColor: colors.diffDelGlyph,
                        lineColor: colors.diffDelLine,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton(
                      onPressed: null,
                      child: const Text('Reject'),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: null,
                      child: const Text('Approve'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _FeatureChip(
                icon: Icons.chat_bubble_outline_rounded,
                label: 'Chat',
                colors: colors,
              ),
              _FeatureChip(
                icon: Icons.code_rounded,
                label: 'Diffs',
                colors: colors,
              ),
              _FeatureChip(
                icon: Icons.folder_open_outlined,
                label: 'Files',
                colors: colors,
              ),
              _FeatureChip(
                icon: Icons.terminal_outlined,
                label: 'Terminal',
                colors: colors,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FakeDiffLine extends StatelessWidget {
  const _FakeDiffLine({
    required this.prefix,
    required this.text,
    required this.prefixColor,
    required this.lineColor,
  });

  final String prefix;
  final String text;
  final Color prefixColor;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
      decoration: BoxDecoration(
        color: lineColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Text(
            prefix,
            style: monoStyle(color: prefixColor, fontSize: 11),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: monoStyle(
                color: context.colors.codeForeground,
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
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
// Page 4: Pick your vibe
// ---------------------------------------------------------------------------

class _ThemePage extends StatelessWidget {
  const _ThemePage({
    required this.colors,
    required this.themeController,
  });

  final AppColors colors;
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPageShell(
      horizontalPadding: 24,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Pick your vibe',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Choose a palette. You can always change it later.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 32),
          ThemePicker(controller: themeController),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 5: Set up & connect
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
                  text: 'npm install -g sidemesh',
                  colors: colors,
                ),
                const SizedBox(height: 6),
                _CommandLine(
                  text: 'sidemesh setup',
                  colors: colors,
                ),
                const SizedBox(height: 6),
                _CommandLine(
                  text: 'sidemesh pair',
                  colors: colors,
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
// Typewriter text widget
// ---------------------------------------------------------------------------

class _TypewriterText extends StatefulWidget {
  const _TypewriterText({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<_TypewriterText> {
  late String _visible;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _visible = '';
    _startTyping();
  }

  void _startTyping() {
    var index = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (index >= widget.text.length) {
        timer.cancel();
        return;
      }
      setState(() {
        _visible = widget.text.substring(0, index + 1);
      });
      index++;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _visible,
      textAlign: TextAlign.center,
      style: widget.style,
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
