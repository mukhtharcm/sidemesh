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
      height: AppSizes.compactControl,
      decoration: BoxDecoration(
        color: colors.composerBackground,
        borderRadius: AppShapes.input,
        border: Border.all(
          color: _focused
              ? colors.accent.withValues(alpha: 0.72)
              : colors.border.withValues(alpha: 0.8),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
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
                height: 18,
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  textAlignVertical: TextAlignVertical.center,
                  strutStyle: const StrutStyle(
                    fontSize: 13,
                    height: 1.2,
                    forceStrutHeight: true,
                  ),
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 13,
                    height: 1.2,
                  ),
                  cursorColor: colors.accent,
                  cursorHeight: 16,
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
                    hintText: 'Search (⌘F)',
                    hintStyle: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 13,
                      height: 1.2,
                    ),
                    contentPadding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(height: 18),
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
