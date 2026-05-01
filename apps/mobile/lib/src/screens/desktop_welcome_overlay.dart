import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../onboarding_store.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/theme_picker.dart';

/// Shows a non-blocking desktop welcome overlay.
///
/// The overlay covers the whole window with a semi-transparent backdrop
/// and a centered card. Users can dismiss it via "Get started" or "Skip".
/// Tapping outside the card also dismisses it.
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
      duration: const Duration(milliseconds: 400),
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
        final opacity = Curves.easeOutCubic.transform(_anim.value);
        return GestureDetector(
          onTap: _dismiss,
          child: Container(
            constraints: const BoxConstraints.expand(),
            color: colors.canvas.withValues(alpha: 0.72 * opacity),
            child: Center(
              child: GestureDetector(
                onTap: () {}, // prevent tap-through
                child: Opacity(
                  opacity: opacity,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 680,
                      maxHeight: 640,
                    ),
                    child: MeshCard(
                      tone: MeshCardTone.elevated,
                      padding: const EdgeInsets.all(32),
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
        // Header
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colors.accentMuted,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colors.accent.withValues(alpha: 0.4),
                ),
              ),
              child: Icon(
                Icons.hub_rounded,
                size: 24,
                color: colors.accent,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome to Sidemesh',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Your coding agents, in your pocket.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            MeshIconButton(
              icon: Icons.close_rounded,
              onTap: onDismiss,
            ),
          ],
        ),
        Divider(height: 32, color: colors.border),
        // Value props
        _PropRow(
          icon: Icons.terminal_rounded,
          title: 'One daemon, full control',
          body:
              'Run a small agent on your machine. This desktop app connects to it over your network.',
          colors: colors,
        ),
        const SizedBox(height: 14),
        _PropRow(
          icon: Icons.chat_bubble_outline_rounded,
          title: 'Chat, approve, inspect',
          body:
              'Start sessions, review code changes, approve actions, and browse files — all remotely.',
          colors: colors,
        ),
        const SizedBox(height: 14),
        _PropRow(
          icon: Icons.keyboard_command_key_rounded,
          title: 'Built for speed',
          body:
              'Keyboard shortcuts for everything: ⌘F search, ⌘R refresh, ⌘1/2/3 switch panes, ⌘/ help.',
          colors: colors,
        ),
        Divider(height: 32, color: colors.border),
        // Theme picker
        Text(
          'Pick your vibe',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        ThemePicker(
          controller: themeController,
          height: 200,
          cardWidth: 140,
        ),
        const SizedBox(height: 24),
        // Actions
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () async {
                await OnboardingStore.instance.markCompleted();
                onDismiss();
              },
              child: const Text('Skip'),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: () async {
                HapticFeedback.mediumImpact();
                await OnboardingStore.instance.markCompleted();
                onDismiss();
              },
              icon: const Icon(Icons.check_rounded),
              label: const Text('Get started'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PropRow extends StatelessWidget {
  const _PropRow({
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
            border: Border.all(
              color: colors.accent.withValues(alpha: 0.35),
            ),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: colors.accent),
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
