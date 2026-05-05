import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../terminal_key_models.dart';
import '../terminal_keybar_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

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
  late final TerminalKeyBarStore _store = TerminalKeyBarStore.instance;
  bool _ctrl = false;
  bool _alt = false;
  bool _shift = false;

  @override
  void initState() {
    super.initState();
    unawaited(_store.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Top row: modifiers (left) + category tabs (right) ──
            SizedBox(
              height: widget.compact ? 34 : 38,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  _ModifierPill(
                    label: 'Ctrl',
                    active: _ctrl,
                    compact: widget.compact,
                    onTap: () => setState(() => _ctrl = !_ctrl),
                  ),
                  const SizedBox(width: 6),
                  _ModifierPill(
                    label: 'Alt',
                    active: _alt,
                    compact: widget.compact,
                    onTap: () => setState(() => _alt = !_alt),
                  ),
                  const SizedBox(width: 6),
                  _ModifierPill(
                    label: 'Shift',
                    active: _shift,
                    compact: widget.compact,
                    onTap: () => setState(() => _shift = !_shift),
                  ),
                  VerticalDivider(
                    width: 1,
                    indent: 8,
                    endIndent: 8,
                    color: colors.border,
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: _store,
                      builder: (context, _) {
                        return ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: _store.categories.length,
                          itemBuilder: (context, index) {
                            final selected =
                                _store.selectedCategoryIndex == index;
                            return _CategoryTab(
                              label: _store.categories[index].label,
                              selected: selected,
                              compact: widget.compact,
                              onTap: () => _store.setSelectedCategoryIndex(index),
                            );
                          },
                          separatorBuilder: (_, _) => const SizedBox(width: 14),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            // ── Bottom row: keys for the selected category ──
            SizedBox(
              height: widget.compact ? 40 : 46,
              child: ListenableBuilder(
                listenable: _store,
                builder: (context, _) {
                  final category =
                      _store.categories[_store.selectedCategoryIndex];
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: category.actions.length,
                    itemBuilder: (context, index) {
                      final action = category.actions[index];
                      return _ActionButton(
                        action: action,
                        compact: widget.compact,
                        activeModifier: _ctrl || _alt || _shift,
                        onTap: () => _onAction(action),
                      );
                    },
                    separatorBuilder: (_, _) =>
                        SizedBox(width: widget.compact ? 5 : 6),
                  );
                },
              ),
            ),
          ],
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

    // One-shot modifiers: after a key is sent we automatically clear them so
    // the user does not accidentally keep Ctrl/Alt/Shift latched.
    if (_ctrl || _alt || _shift) {
      setState(() {
        _ctrl = false;
        _alt = false;
        _shift = false;
      });
    }
  }
}

// ── Category tabs (text-only, underline when selected) ──

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.input,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 10,
          vertical: compact ? 6 : 8,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: selected ? colors.textPrimary : colors.textSecondary,
            fontWeight:
                selected ? AppWeights.emphasis : AppWeights.body,
            fontSize: compact ? 11 : 12,
          ),
        ),
      ),
    );
  }
}

// ── Modifier pills (filled accent when active — impossible to miss) ──

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
          color: active ? colors.accent : null,
          border: Border.all(
            color: active ? colors.accent : colors.border,
          ),
          borderRadius: AppShapes.pill,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: active ? Colors.white : colors.textSecondary,
            fontWeight: active ? AppWeights.emphasis : AppWeights.body,
            fontSize: compact ? 11 : 12,
          ),
        ),
      ),
    );
  }
}

// ── Action buttons ──

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.action,
    required this.compact,
    required this.activeModifier,
    required this.onTap,
  });

  final TerminalKeyAction action;
  final bool compact;
  final bool activeModifier;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.input,
      child: Container(
        constraints: const BoxConstraints(minWidth: 36),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
        ),
        decoration: BoxDecoration(
          border: Border.all(
            color: activeModifier || action.hasModifiers
                ? colors.accent
                : colors.border,
          ),
          borderRadius: AppShapes.input,
        ),
        alignment: Alignment.center,
        child: Text(
          action.label,
          style: monoStyle(
            color: colors.textPrimary,
            fontSize: compact ? 11.5 : 12.5,
            fontWeight: AppWeights.emphasis,
          ),
        ),
      ),
    );
  }
}
