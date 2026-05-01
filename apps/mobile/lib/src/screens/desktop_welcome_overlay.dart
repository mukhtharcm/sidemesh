import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../onboarding_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/theme_picker.dart';

/// A native-feeling desktop welcome overlay.
///
/// Uses a blurred backdrop and a wide, low-profile card that respects
/// the app's terminal-inspired aesthetic. Non-blocking — users can
/// dismiss via the close button, clicking outside, or pressing Escape.
class DesktopWelcomeOverlay extends StatefulWidget {
  const DesktopWelcomeOverlay({
    super.key,
    required this.themeController,
    required this.onDismissed,
  });

  final ThemeController themeController;
  final VoidCallback onDismissed;

  @override
  State<DesktopWelcomeOverlay> createState() => _DesktopWelcomeOverlayState();
}

class _DesktopWelcomeOverlayState extends State<DesktopWelcomeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _anim.reverse();
    if (!mounted) return;
    widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_anim.value);
        return GestureDetector(
          onTap: _dismiss,
          child: Container(
            constraints: const BoxConstraints.expand(),
            color: colors.canvas.withValues(alpha: 0.55 * t),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12 * t, sigmaY: 12 * t),
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // prevent tap-through
                  child: Opacity(
                    opacity: t,
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 960,
                          minWidth: 640,
                        ),
                        child: MeshCard(
                          tone: MeshCardTone.elevated,
                          padding: const EdgeInsets.all(44),
                          child: _Content(
                            colors: colors,
                            themeController: widget.themeController,
                            onDismiss: _dismiss,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.colors,
    required this.themeController,
    required this.onDismiss,
  });

  final AppColors colors;
  final ThemeController themeController;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top bar: close button
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _SubtleButton(
              onTap: () async {
                await OnboardingStore.instance.markCompleted();
                onDismiss();
              },
              label: 'Skip',
              colors: colors,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Two-column body
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left column: branding + headline + description
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Brand mark
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: colors.accentMuted,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.accent.withValues(alpha: 0.35),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.hub_rounded,
                          size: 20,
                          color: colors.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Sidemesh',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.textSecondary,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  // Headline
                  Text(
                    'Your coding agents,\nin your pocket.',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colors.textPrimary,
                      height: 1.15,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Body
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Text(
                      'Run a small daemon on your machine, then control it remotely from this desktop app. Chat, approve changes, inspect files, and monitor sessions — all from one place.',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Shortcuts hint
                  _ShortcutHint(colors: colors),
                  const SizedBox(height: 32),
                  // CTA
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          HapticFeedback.mediumImpact();
                          await OnboardingStore.instance.markCompleted();
                          onDismiss();
                        },
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Get started'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () async {
                          await OnboardingStore.instance.markCompleted();
                          onDismiss();
                        },
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 48),
            // Right column: theme picker
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pick your vibe',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Choose a palette. You can change this anytime in Settings.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ThemePicker(
                    controller: themeController,
                    height: 240,
                    cardWidth: 120,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShortcutHint extends StatelessWidget {
  const _ShortcutHint({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Kbd(text: '⌘F', colors: colors),
        _Kbd(text: '⌘R', colors: colors),
        _Kbd(text: '⌘1/2/3', colors: colors),
        _Kbd(text: '⌘/', colors: colors),
        const SizedBox(width: 4),
        Text(
          'search · refresh · panes · help',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.textTertiary,
          ),
        ),
      ],
    );
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd({required this.text, required this.colors});

  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 0,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        text,
        style: monoStyle(
          color: colors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SubtleButton extends StatelessWidget {
  const _SubtleButton({
    required this.onTap,
    required this.label,
    required this.colors,
  });

  final VoidCallback onTap;
  final String label;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
