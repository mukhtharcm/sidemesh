import 'dart:async';
import 'package:flutter/material.dart' hide Icons;
import '../widgets/phosphor_icons.dart';

import '../onboarding_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/mesh_widgets.dart';

enum _OnboardingTab { overview, setup, shortcuts }

/// A desktop welcome center with tabbed sections.
///
/// Covers the window with a wide setup card.
/// Users can explore Overview, Connect, and Shortcuts tabs.
/// Non-blocking — dismiss via the close button or clicking outside.
class DesktopWelcomeOverlay extends StatefulWidget {
  const DesktopWelcomeOverlay({
    super.key,
    required this.themeController,
    required this.onDismissed,
    this.onAddHost,
  });

  final ThemeController themeController;
  final VoidCallback onDismissed;
  final VoidCallback? onAddHost;

  @override
  State<DesktopWelcomeOverlay> createState() => _DesktopWelcomeOverlayState();
}

class _DesktopWelcomeOverlayState extends State<DesktopWelcomeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  _OnboardingTab _tab = _OnboardingTab.overview;

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

  void _markCompleteAndDismiss() async {
    await OnboardingStore.instance.markCompleted();
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_anim.value);
        final lift = 18 * (1 - t);
        return GestureDetector(
          onTap: _dismiss,
          child: Container(
            constraints: const BoxConstraints.expand(),
            color: colors.canvas.withValues(alpha: 0.55 * t),
            child: Center(
              child: GestureDetector(
                onTap: () {},
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, lift),
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 880,
                          minWidth: 560,
                          maxHeight: 680,
                        ),
                        child: MeshCard(
                          tone: MeshCardTone.elevated,
                          padding: const EdgeInsets.all(28),
                          child: _Content(
                            colors: colors,
                            onDismiss: _dismiss,
                            onMarkCompleteAndDismiss: _markCompleteAndDismiss,
                            onAddHost: widget.onAddHost,
                            activeTab: _tab,
                            onTabChanged: (tab) => setState(() => _tab = tab),
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
    required this.onDismiss,
    required this.onMarkCompleteAndDismiss,
    required this.activeTab,
    required this.onTabChanged,
    this.onAddHost,
  });

  final AppColors colors;
  final VoidCallback onDismiss;
  final VoidCallback onMarkCompleteAndDismiss;
  final _OnboardingTab activeTab;
  final ValueChanged<_OnboardingTab> onTabChanged;
  final VoidCallback? onAddHost;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top bar
        Row(
          children: [
            // Brand
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: colors.accentMuted,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: colors.accent.withValues(alpha: 0.35),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.hub_rounded,
                    size: 16,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 10),
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
            const Spacer(),
            _SubtleButton(
              onTap: onMarkCompleteAndDismiss,
              label: 'Close',
              colors: colors,
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Tabs
        _TabBar(
          active: activeTab,
          onTap: onTabChanged,
          colors: colors,
        ),
        Divider(height: 24, color: colors.border),
        // Body
        Expanded(
          child: SingleChildScrollView(
            child: switch (activeTab) {
              _OnboardingTab.overview => _WelcomeTab(
                colors: colors,
                onOpenSetup: () => onTabChanged(_OnboardingTab.setup),
                onMarkCompleteAndDismiss: onMarkCompleteAndDismiss,
              ),
              _OnboardingTab.setup => _SetupTab(
                colors: colors,
                onAddHost: onAddHost,
                onDismiss: onDismiss,
              ),
              _OnboardingTab.shortcuts => const _ShortcutsTab(),
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab bar
// ---------------------------------------------------------------------------

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.active,
    required this.onTap,
    required this.colors,
  });

  final _OnboardingTab active;
  final ValueChanged<_OnboardingTab> onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final tabs = <(_OnboardingTab, String, IconData)>[
      (_OnboardingTab.overview, 'Overview', Icons.grid_view_rounded),
      (_OnboardingTab.setup, 'Connect', Icons.link_rounded),
      (_OnboardingTab.shortcuts, 'Shortcuts', Icons.keyboard_rounded),
    ];
    return Row(
      children: tabs.map((entry) {
        final isActive = active == entry.$1;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onTap(entry.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isActive ? colors.accentMuted : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: isActive
                      ? Border.all(
                          color: colors.accent.withValues(alpha: 0.4),
                        )
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      entry.$3,
                      size: 16,
                      color: isActive ? colors.accent : colors.textTertiary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      entry.$2,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight:
                            isActive ? FontWeight.w700 : FontWeight.w500,
                        color:
                            isActive ? colors.accent : colors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Welcome tab
// ---------------------------------------------------------------------------

class _WelcomeTab extends StatelessWidget {
  const _WelcomeTab({
    required this.colors,
    required this.onOpenSetup,
    required this.onMarkCompleteAndDismiss,
  });

  final AppColors colors;
  final VoidCallback onOpenSetup;
  final VoidCallback onMarkCompleteAndDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect one machine, then keep working from here.',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: colors.textPrimary,
            height: 1.15,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'Sidemesh is easiest to learn once one machine is paired. After that, you can watch sessions, approvals, files, and terminals without leaving this app.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 32),
        // Quick feature chips
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _FeatureChip(
              icon: Icons.chat_bubble_outline_rounded,
              label: 'Sessions',
              colors: colors,
            ),
            _FeatureChip(
              icon: Icons.rule_folder_rounded,
              label: 'Approvals',
              colors: colors,
            ),
            _FeatureChip(
              icon: Icons.folder_open_rounded,
              label: 'Files',
              colors: colors,
            ),
            _FeatureChip(
              icon: Icons.terminal_rounded,
              label: 'Terminal',
              colors: colors,
            ),
          ],
        ),
        const SizedBox(height: 32),
        // Shortcut pills
        _ShortcutHint(colors: colors),
        const SizedBox(height: 32),
        // CTA
        Row(
          children: [
            FilledButton.icon(
              onPressed: onOpenSetup,
              icon: const Icon(Icons.link_rounded, size: 18),
              label: const Text('Connect a machine'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: onMarkCompleteAndDismiss,
              child: const Text('Close'),
            ),
          ],
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
// Setup tab
// ---------------------------------------------------------------------------

class _SetupTab extends StatelessWidget {
  const _SetupTab({
    required this.colors,
    this.onAddHost,
    required this.onDismiss,
  });

  final AppColors colors;
  final VoidCallback? onAddHost;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect a machine',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'Run these commands on the machine you want to manage, then use the add-machine flow in this app.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 24),
        _CommandBlock(
          text: 'npm install -g sidemesh',
          colors: colors,
        ),
        const SizedBox(height: 6),
        _CommandBlock(
          text: 'sidemesh setup',
          colors: colors,
        ),
        const SizedBox(height: 6),
        _CommandBlock(
          text: 'sidemesh pair',
          colors: colors,
        ),
        const SizedBox(height: 24),
        Text(
          'If Sidemesh is already running there, you can skip straight to adding the machine here.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.textTertiary,
          ),
        ),
        const SizedBox(height: 20),
        if (onAddHost != null)
          Row(
            children: [
              FilledButton.icon(
                onPressed: () {
                  onAddHost!();
                  onDismiss();
                },
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add a machine'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: onDismiss,
                child: const Text('Close'),
              ),
            ],
          ),
      ],
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({
    required this.text,
    required this.colors,
  });

  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.codeBorder),
      ),
      child: Row(
        children: [
          Text(
            r'$',
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
// Shortcuts tab
// ---------------------------------------------------------------------------

class _ShortcutsTab extends StatelessWidget {
  const _ShortcutsTab();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shortcuts = <({String keys, String label})>[
      (keys: '⌘F', label: 'Focus search'),
      (keys: '⌘J', label: 'Focus composer'),
      (keys: '⌘R', label: 'Refresh'),
      (keys: '⌘W', label: 'Close active session'),
      (keys: '⌘1', label: 'Recent pane'),
      (keys: '⌘2', label: 'Inbox pane'),
      (keys: '⌘3', label: 'Hosts pane'),
      (keys: '⌘/', label: 'Show keyboard shortcuts'),
      (keys: 'Enter', label: 'Send message'),
      (keys: 'Shift + Enter', label: 'Newline in composer'),
      (keys: 'Long-press message', label: 'Copy to clipboard'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Keyboard shortcuts',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'A few shortcuts are enough to move around quickly. You can learn the rest as you go.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: shortcuts.map((s) {
            return SizedBox(
              width: 280,
              child: Row(
                children: [
                  _Kbd(text: s.keys, colors: colors),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.label,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: colors.textSecondary),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

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
