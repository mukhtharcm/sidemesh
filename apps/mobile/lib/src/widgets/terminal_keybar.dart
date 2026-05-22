import 'package:flutter/material.dart' hide Icon, Icons, IconData;
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as xterm;
import './app_icons.dart';

import '../terminal_key_models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'terminal_keybar_sheet.dart';

class TerminalKeyBar extends StatefulWidget {
  const TerminalKeyBar({
    super.key,
    required this.onAction,
    this.compact = false,
  });

  final void Function(TerminalKeyAction action) onAction;
  final bool compact;

  @override
  State<TerminalKeyBar> createState() => _TerminalKeyBarState();
}

class _TerminalKeyBarState extends State<TerminalKeyBar> {
  bool _ctrl = false;
  bool _alt = false;
  bool _shift = false;

  static const _essentials = <TerminalKeyAction>[
    TerminalKeyAction(label: 'Esc', key: xterm.TerminalKey.escape),
    TerminalKeyAction(label: 'Tab', key: xterm.TerminalKey.tab),
    TerminalKeyAction(label: '←', key: xterm.TerminalKey.arrowLeft),
    TerminalKeyAction(label: '↑', key: xterm.TerminalKey.arrowUp),
    TerminalKeyAction(label: '↓', key: xterm.TerminalKey.arrowDown),
    TerminalKeyAction(label: '→', key: xterm.TerminalKey.arrowRight),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final activeModifier = _ctrl || _alt || _shift;

    return SafeArea(
      top: false,
      child: Container(
        height: widget.compact ? 46 : 52,
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 6 : 8,
          vertical: widget.compact ? 5 : 6,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _essentials.length + 4, // + Ctrl + Alt + Shift + More
          itemBuilder: (context, index) {
            // Essentials first
            if (index < _essentials.length) {
              return _KeyButton(
                label: _essentials[index].label,
                onTap: () => _onAction(_essentials[index]),
                compact: widget.compact,
                highlighted: activeModifier,
              );
            }

            // Then modifiers and More
            final modIndex = index - _essentials.length;
            switch (modIndex) {
              case 0:
                return _ModifierPill(
                  label: 'Ctrl',
                  active: _ctrl,
                  compact: widget.compact,
                  onTap: () => setState(() => _ctrl = !_ctrl),
                );
              case 1:
                return _ModifierPill(
                  label: 'Alt',
                  active: _alt,
                  compact: widget.compact,
                  onTap: () => setState(() => _alt = !_alt),
                );
              case 2:
                return _ModifierPill(
                  label: 'Shift',
                  active: _shift,
                  compact: widget.compact,
                  onTap: () => setState(() => _shift = !_shift),
                );
              case 3:
                return _MoreButton(
                  compact: widget.compact,
                  onTap: () => showTerminalKeyBarSheet(
                    context: context,
                    onAction: widget.onAction,
                    compact: widget.compact,
                  ),
                );
            }
            return const SizedBox.shrink();
          },
          separatorBuilder: (_, _) => SizedBox(width: widget.compact ? 5 : 6),
        ),
      ),
    );
  }

  void _onAction(TerminalKeyAction base) {
    if (!mounted) return;
    final effective = TerminalKeyAction(
      label: base.label,
      key: base.key,
      ctrl: base.ctrl || _ctrl,
      alt: base.alt || _alt,
      shift: base.shift || _shift,
      rawText: base.rawText,
    );
    if (effective.key == null &&
        (effective.rawText == null || effective.rawText!.isEmpty)) {
      return;
    }
    HapticFeedback.selectionClick();
    widget.onAction(effective);

    // One-shot: auto-clear modifiers after a key is sent.
    if (_ctrl || _alt || _shift) {
      setState(() {
        _ctrl = false;
        _alt = false;
        _shift = false;
      });
    }
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.label,
    required this.onTap,
    required this.compact,
    this.highlighted = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool compact;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.input,
      child: Container(
        constraints: const BoxConstraints(minWidth: 40),
        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(
            color: highlighted ? colors.accent : colors.border,
          ),
          borderRadius: AppShapes.input,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.textPrimary,
            fontSize: compact ? 12 : 13,
            fontWeight: AppWeights.emphasis,
          ),
        ),
      ),
    );
  }
}

class _ModifierPill extends StatelessWidget {
  const _ModifierPill({
    required this.label,
    required this.active,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.pill,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 9 : 12,
          vertical: compact ? 5 : 6,
        ),
        decoration: BoxDecoration(
          color: active ? colors.accentMuted : colors.surface,
          border: Border.all(color: active ? colors.accent : colors.border),
          borderRadius: AppShapes.pill,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: active ? colors.accent : colors.textSecondary,
            fontWeight: AppWeights.emphasis,
            fontSize: compact ? 11 : 12,
          ),
        ),
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.compact, required this.onTap});

  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.pill,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 9 : 12,
          vertical: compact ? 5 : 6,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.border),
          borderRadius: AppShapes.pill,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.more_horiz_rounded,
              size: compact ? 16 : 18,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              'More',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.textSecondary,
                fontWeight: AppWeights.emphasis,
                fontSize: compact ? 11 : 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
