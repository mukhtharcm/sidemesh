import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as xterm;

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
  static const _primaryActions = <TerminalKeyAction>[
    TerminalKeyAction(label: 'Ctrl+C', key: xterm.TerminalKey.keyC, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+D', key: xterm.TerminalKey.keyD, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+Z', key: xterm.TerminalKey.keyZ, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+L', key: xterm.TerminalKey.keyL, ctrl: true),
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
          itemCount: _primaryActions.length + 1,
          itemBuilder: (context, index) {
            if (index < _primaryActions.length) {
              return _KeyButton(
                label: _primaryActions[index].label,
                onTap: () => _fireAction(_primaryActions[index]),
                compact: widget.compact,
                highlighted: _primaryActions[index].hasModifiers,
              );
            }

            return _MoreButton(
              compact: widget.compact,
              onTap: () => showTerminalKeyBarSheet(
                context: context,
                onAction: widget.onAction,
                compact: widget.compact,
              ),
            );
          },
          separatorBuilder: (_, _) => SizedBox(width: widget.compact ? 5 : 6),
        ),
      ),
    );
  }

  void _fireAction(TerminalKeyAction action) {
    if (action.key == null &&
        (action.rawText == null || action.rawText!.isEmpty)) {
      return;
    }
    HapticFeedback.selectionClick();
    widget.onAction(action);
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
