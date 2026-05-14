import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../terminal_key_models.dart';
import '../terminal_keybar_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

Future<void> showTerminalKeyBarSheet({
  required BuildContext context,
  required void Function(TerminalKeyAction action) onAction,
  required bool compact,
}) async {
  final colors = context.colors;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) =>
        _TerminalKeyBarSheet(onAction: onAction, compact: compact),
  );
}

class _TerminalKeyBarSheet extends StatefulWidget {
  const _TerminalKeyBarSheet({required this.onAction, required this.compact});

  final void Function(TerminalKeyAction action) onAction;
  final bool compact;

  @override
  State<_TerminalKeyBarSheet> createState() => _TerminalKeyBarSheetState();
}

class _TerminalKeyBarSheetState extends State<_TerminalKeyBarSheet> {
  late final TerminalKeyBarStore _store = TerminalKeyBarStore.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_store.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            final categories = _store.categories;
            return CustomScrollView(
              shrinkWrap: true,
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 16),
                        child: Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: colors.border,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Extra keys',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: AppWeights.title),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Useful keys and shortcuts for terminal work.',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: colors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(
                              Icons.close_rounded,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                for (final category in categories) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8, top: 4),
                      child: Text(
                        category.label,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colors.textSecondary,
                          fontWeight: AppWeights.emphasis,
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.only(bottom: 16),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: widget.compact ? 5 : 6,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: widget.compact ? 2.2 : 2.4,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final action = category.actions[index];
                        return _SheetKeyButton(
                          action: action,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            widget.onAction(action);
                            Navigator.of(context).pop();
                          },
                        );
                      }, childCount: category.actions.length),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SheetKeyButton extends StatelessWidget {
  const _SheetKeyButton({required this.action, required this.onTap});

  final TerminalKeyAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.input,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          border: Border.all(color: colors.border),
          borderRadius: AppShapes.input,
        ),
        alignment: Alignment.center,
        child: Text(
          action.label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.textPrimary,
            fontSize: 12,
            fontWeight: AppWeights.emphasis,
          ),
        ),
      ),
    );
  }
}
