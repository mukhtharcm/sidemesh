import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../terminal_key_models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

void showTerminalKeyBarSheet({
  required BuildContext context,
  required void Function(TerminalKeyAction action) onAction,
  bool compact = false,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _KeyBarSheet(onAction: onAction),
  );
}

class _KeyBarSheet extends StatefulWidget {
  const _KeyBarSheet({required this.onAction});
  final void Function(TerminalKeyAction action) onAction;

  @override
  State<_KeyBarSheet> createState() => _KeyBarSheetState();
}

class _KeyBarSheetState extends State<_KeyBarSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  static const _allKeys = <TerminalKeyAction>[
    TerminalKeyAction(label: 'Esc', key: xterm.TerminalKey.escape),
    TerminalKeyAction(label: 'Tab', key: xterm.TerminalKey.tab),
    TerminalKeyAction(label: 'Enter', key: xterm.TerminalKey.enter),
    TerminalKeyAction(label: 'Space', key: xterm.TerminalKey.space),
    TerminalKeyAction(label: '←', key: xterm.TerminalKey.arrowLeft),
    TerminalKeyAction(label: '↑', key: xterm.TerminalKey.arrowUp),
    TerminalKeyAction(label: '↓', key: xterm.TerminalKey.arrowDown),
    TerminalKeyAction(label: '→', key: xterm.TerminalKey.arrowRight),
    TerminalKeyAction(label: 'Home', key: xterm.TerminalKey.home),
    TerminalKeyAction(label: 'End', key: xterm.TerminalKey.end),
    TerminalKeyAction(label: 'PgUp', key: xterm.TerminalKey.pageUp),
    TerminalKeyAction(label: 'PgDn', key: xterm.TerminalKey.pageDown),
    TerminalKeyAction(label: 'BS', key: xterm.TerminalKey.backspace),
    TerminalKeyAction(label: 'Del', key: xterm.TerminalKey.delete),
    TerminalKeyAction(label: 'Ins', key: xterm.TerminalKey.insert),
    TerminalKeyAction(label: 'F1', key: xterm.TerminalKey.f1),
    TerminalKeyAction(label: 'F2', key: xterm.TerminalKey.f2),
    TerminalKeyAction(label: 'F3', key: xterm.TerminalKey.f3),
    TerminalKeyAction(label: 'F4', key: xterm.TerminalKey.f4),
    TerminalKeyAction(label: 'F5', key: xterm.TerminalKey.f5),
    TerminalKeyAction(label: 'F6', key: xterm.TerminalKey.f6),
    TerminalKeyAction(label: 'F7', key: xterm.TerminalKey.f7),
    TerminalKeyAction(label: 'F8', key: xterm.TerminalKey.f8),
    TerminalKeyAction(label: 'F9', key: xterm.TerminalKey.f9),
    TerminalKeyAction(label: 'F10', key: xterm.TerminalKey.f10),
    TerminalKeyAction(label: 'F11', key: xterm.TerminalKey.f11),
    TerminalKeyAction(label: 'F12', key: xterm.TerminalKey.f12),
    TerminalKeyAction(label: 'Ctrl+A', key: xterm.TerminalKey.keyA, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+C', key: xterm.TerminalKey.keyC, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+D', key: xterm.TerminalKey.keyD, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+E', key: xterm.TerminalKey.keyE, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+K', key: xterm.TerminalKey.keyK, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+L', key: xterm.TerminalKey.keyL, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+R', key: xterm.TerminalKey.keyR, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+U', key: xterm.TerminalKey.keyU, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+W', key: xterm.TerminalKey.keyW, ctrl: true),
    TerminalKeyAction(label: 'Ctrl+Z', key: xterm.TerminalKey.keyZ, ctrl: true),
    TerminalKeyAction(label: '|', rawText: '|'),
    TerminalKeyAction(label: '~', rawText: '~'),
    TerminalKeyAction(label: r'$', rawText: r'$'),
    TerminalKeyAction(label: '`', rawText: '`'),
    TerminalKeyAction(label: r'\', rawText: r'\'),
    TerminalKeyAction(label: '&', rawText: '&'),
    TerminalKeyAction(label: '!', rawText: '!'),
    TerminalKeyAction(label: '#', rawText: '#'),
    TerminalKeyAction(label: '(', rawText: '('),
    TerminalKeyAction(label: ')', rawText: ')'),
    TerminalKeyAction(label: '{', rawText: '{'),
    TerminalKeyAction(label: '}', rawText: '}'),
    TerminalKeyAction(label: '[', rawText: '['),
    TerminalKeyAction(label: ']', rawText: ']'),
    TerminalKeyAction(label: '/', rawText: '/'),
    TerminalKeyAction(label: '-', rawText: '-'),
    TerminalKeyAction(label: '_', rawText: '_'),
    TerminalKeyAction(label: '=', rawText: '='),
    TerminalKeyAction(label: '@', rawText: '@'),
  ];

  List<TerminalKeyAction> get _filtered {
    if (_query.isEmpty) return _allKeys;
    final q = _query.toLowerCase();
    return _allKeys.where((k) => k.label.toLowerCase().contains(q)).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.25,
      maxChildSize: 0.85,
      expand: false,
      builder: (ctx, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: Column(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 8),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Search keys',
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Divider(height: 1, color: colors.border),
              Expanded(
                child: GridView.extent(
                  controller: scrollController,
                  maxCrossAxisExtent: 72,
                  padding: const EdgeInsets.all(12),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1,
                  children: _filtered.map((action) {
                    return _SheetKeyTile(
                      action: action,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(context).pop();
                        widget.onAction(action);
                      },
                      colors: colors,
                    );
                  }).toList(),
                ),
              ),
              SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
            ],
          ),
        );
      },
    );
  }
}

class _SheetKeyTile extends StatelessWidget {
  const _SheetKeyTile({
    required this.action,
    required this.onTap,
    required this.colors,
  });

  final TerminalKeyAction action;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppShapes.input,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppShapes.input,
          border: Border.all(color: colors.border),
        ),
        alignment: Alignment.center,
        child: Text(
          action.label,
          textAlign: TextAlign.center,
          style: monoStyle(
            color: colors.textPrimary,
            fontSize: 12,
            fontWeight: AppWeights.emphasis,
          ),
        ),
      ),
    );
  }
}
