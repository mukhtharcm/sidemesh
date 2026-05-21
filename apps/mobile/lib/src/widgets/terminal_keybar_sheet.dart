import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../terminal_key_models.dart';
import '../terminal_keybar_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'app_sheets.dart';
import 'mesh_widgets.dart';
import '../app_icons.dart';

Future<void> showTerminalKeyBarSheet({
  required BuildContext context,
  required void Function(TerminalKeyAction action) onAction,
  required bool compact,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
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
    return MeshBottomSheetScaffold(
      icon: AppIcons.keyboard_command_key_rounded,
      title: 'Extra keys',
      description: 'Useful keys and shortcuts for terminal work.',
      maxWidth: 760,
      maxHeightFactor: 0.86,
      child: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final categories = _store.categories;
          return CustomScrollView(
            shrinkWrap: true,
            slivers: [
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
    return Semantics(
      button: true,
      label: action.label,
      child: MeshSurface(
        onTap: onTap,
        tone: MeshSurfaceTone.muted,
        radius: AppRadii.control,
        padding: EdgeInsets.zero,
        child: Center(
          child: Text(
            action.label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: AppWeights.emphasis,
            ),
          ),
        ),
      ),
    );
  }
}
