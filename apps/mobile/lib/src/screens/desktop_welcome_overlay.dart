import 'dart:async';
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

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
    _anim = AnimationController(vsync: this, duration: AppMotion.page)
      ..forward();
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
            color: colors.canvas.withValues(alpha: AppEmphasis.medium * t),
            child: Center(
              child: GestureDetector(
                onTap: () {},
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, lift),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxl),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 880,
                          minWidth: 560,
                          maxHeight: 680,
                        ),
                        child: MeshCard(
                          tone: MeshCardTone.elevated,
                          padding: const EdgeInsets.all(AppSpacing.xxl),
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
                    borderRadius: AppShapes.input,
                    border: Border.all(
                      color: colors.accent.withValues(alpha: AppEmphasis.muted),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.hub_rounded,
                    size: AppSizes.compactIcon,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
                Text(
                  'Sidemesh',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: AppWeights.strong,
                    color: colors.textSecondary,
                    letterSpacing: AppLetterSpacing.caps,
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
        const SizedBox(height: AppSpacing.xl),
        // Tabs
        _TabBar(active: activeTab, onTap: onTabChanged, colors: colors),
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
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: AppShapes.input,
              onTap: () => onTap(entry.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: isActive ? colors.accentMuted : Colors.transparent,
                  borderRadius: AppShapes.input,
                  border: isActive
                      ? Border.all(
                          color: colors.accent.withValues(
                            alpha: AppEmphasis.muted,
                          ),
                        )
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      entry.$3,
                      size: AppSizes.compactIcon,
                      color: isActive ? colors.accent : colors.textTertiary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      entry.$2,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: isActive
                            ? AppWeights.strong
                            : AppWeights.emphasis,
                        color: isActive ? colors.accent : colors.textTertiary,
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
            fontWeight: AppWeights.strong,
            color: colors.textPrimary,
            height: AppLineHeights.tight,
            letterSpacing: AppLetterSpacing.headline,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'Sidemesh is easiest to learn once one machine is paired. After that, you can watch sessions, approvals, files, and terminals without leaving this app.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colors.textSecondary,
              height: AppLineHeights.code,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
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
        const SizedBox(height: AppSpacing.xxl),
        // Shortcut pills
        _ShortcutHint(colors: colors),
        const SizedBox(height: AppSpacing.xxl),
        // CTA
        Row(
          children: [
            FilledButton.icon(
              onPressed: onOpenSetup,
              icon: const Icon(Icons.link_rounded, size: AppSizes.inlineIcon),
              label: const Text('Connect a machine'),
            ),
            const SizedBox(width: AppSpacing.md),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.panel,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppSizes.compactIcon, color: colors.textSecondary),
          const SizedBox(width: AppSpacing.tight),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.textSecondary,
              fontWeight: AppWeights.title,
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
            fontWeight: AppWeights.strong,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'Run these commands on the machine you want to manage, then use the add-machine flow in this app.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
              height: AppLineHeights.code,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _CommandBlock(text: 'npm install -g sidemesh', colors: colors),
        const SizedBox(height: AppSpacing.tight),
        _CommandBlock(text: 'sidemesh setup', colors: colors),
        const SizedBox(height: AppSpacing.tight),
        _CommandBlock(text: 'sidemesh pair', colors: colors),
        const SizedBox(height: AppSpacing.xl),
        Text(
          'If Sidemesh is already running there, you can skip straight to adding the machine here.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
        ),
        const SizedBox(height: AppSpacing.xl),
        if (onAddHost != null)
          Row(
            children: [
              FilledButton.icon(
                onPressed: () {
                  onAddHost!();
                  onDismiss();
                },
                icon: const Icon(Icons.add_rounded, size: AppSizes.inlineIcon),
                label: const Text('Add a machine'),
              ),
              const SizedBox(width: AppSpacing.md),
              OutlinedButton(onPressed: onDismiss, child: const Text('Close')),
            ],
          ),
      ],
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.text, required this.colors});

  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.compact,
      ),
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: AppShapes.panel,
        border: Border.all(color: colors.codeBorder),
      ),
      child: Row(
        children: [
          Text(
            r'$',
            style: monoStyle(
              color: colors.accent,
              fontSize: AppFontSizes.caption,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: monoStyle(
                color: colors.codeForeground,
                fontSize: AppFontSizes.caption,
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
            fontWeight: AppWeights.strong,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'A few shortcuts are enough to move around quickly. You can learn the rest as you go.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xl),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: shortcuts.map((s) {
            return SizedBox(
              width: 280,
              child: Row(
                children: [
                  _Kbd(text: s.keys, colors: colors),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      s.label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
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
        const SizedBox(width: AppSpacing.xs),
        Text(
          'search · refresh · panes · help',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colors.textTertiary),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.badge,
        border: Border.all(color: colors.border),
        boxShadow: [AppShadows.surface(colors.textPrimary)],
      ),
      child: Text(
        text,
        style: monoStyle(
          color: colors.textSecondary,
          fontSize: AppFontSizes.metadata,
          fontWeight: AppWeights.title,
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
        borderRadius: AppShapes.hover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.compact,
            vertical: AppSpacing.tight,
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textTertiary,
              fontWeight: AppWeights.title,
            ),
          ),
        ),
      ),
    );
  }
}
