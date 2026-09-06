import 'package:flutter/material.dart';

import '../theme/app_control_styles.dart';

class DesktopSidebarSearchField extends StatelessWidget {
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => TextField(
      controller: controller,
      focusNode: focusNode,
      style: AppControlStyles.searchText(context),
      decoration: AppControlStyles.search(context).copyWith(
        hintText: 'Search (⌘F)',
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    ),
  );
}
