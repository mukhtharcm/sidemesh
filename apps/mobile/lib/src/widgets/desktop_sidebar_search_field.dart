import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

class DesktopSidebarSearchField extends StatefulWidget {
  const DesktopSidebarSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;

  @override
  State<DesktopSidebarSearchField> createState() =>
      _DesktopSidebarSearchFieldState();
}

class _DesktopSidebarSearchFieldState extends State<DesktopSidebarSearchField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocus);
    _focused = widget.focusNode.hasFocus;
  }

  @override
  void didUpdateWidget(covariant DesktopSidebarSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode == widget.focusNode) return;
    oldWidget.focusNode.removeListener(_handleFocus);
    widget.focusNode.addListener(_handleFocus);
    _focused = widget.focusNode.hasFocus;
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocus);
    super.dispose();
  }

  void _handleFocus() {
    if (!mounted || widget.focusNode.hasFocus == _focused) return;
    setState(() => _focused = widget.focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: AppSizes.control,
      decoration: BoxDecoration(
        color: colors.composerBackground,
        borderRadius: AppShapes.action,
        border: Border.all(
          color: _focused ? colors.accent : colors.border,
          width: _focused ? 1.5 : 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: AppSizes.compactIcon,
            color: _focused ? colors.accent : colors.textTertiary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Align(
              alignment: Alignment.center,
              child: SizedBox(
                height: 20,
                child: Transform.translate(
                  offset: const Offset(0, 1),
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    textAlignVertical: TextAlignVertical.center,
                    style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
                    cursorColor: colors.accent,
                    cursorHeight: 18,
                    cursorWidth: 1.5,
                    cursorRadius: const Radius.circular(1),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      filled: false,
                      hoverColor: Colors.transparent,
                      focusColor: Colors.transparent,
                      hint: Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Text(
                          'Search (⌘F)',
                          style: TextStyle(
                            color: colors.textTertiary,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              if (widget.controller.text.isEmpty) {
                return const SizedBox.shrink();
              }
              return InkWell(
                borderRadius: AppShapes.action,
                onTap: widget.onClear,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: colors.textTertiary,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
