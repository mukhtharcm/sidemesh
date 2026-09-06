import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'reasoning_choice_list.dart';
import '../theme/app_control_styles.dart';

class MobileModelPicker extends StatefulWidget {
  const MobileModelPicker({
    super.key,
    required this.models,
    required this.currentModel,
    required this.onModelSelected,
    this.currentReasoning,
    this.onReasoningSelected,
    this.onUseDefault,
    this.usesDefault = false,
  });

  final List<ModelCatalogEntry> models;
  final String? currentModel;
  final String? currentReasoning;
  final ValueChanged<ModelCatalogEntry> onModelSelected;
  final Future<void> Function(String)? onReasoningSelected;
  final VoidCallback? onUseDefault;
  final bool usesDefault;

  @override
  State<MobileModelPicker> createState() => _MobileModelPickerState();
}

class _MobileModelPickerState extends State<MobileModelPicker> {
  final _queryController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;
  bool _showEffort = false;
  String? _reasoning;

  @override
  void dispose() {
    _queryController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final query = _queryController.text.trim().toLowerCase();
    final filtered = widget.models
        .where(
          (model) => '${model.displayName} ${model.model} ${model.description}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    final current = widget.models
        .where((model) => model.model == widget.currentModel)
        .firstOrNull;
    final options =
        current?.supportedReasoningEfforts ??
        const <ModelReasoningEffortOption>[];
    final effort =
        _reasoning ??
        widget.currentReasoning ??
        current?.defaultReasoningEffort ??
        '';
    final canChooseEffort =
        widget.onReasoningSelected != null &&
        current != null &&
        !current.isAutoModel &&
        options.isNotEmpty;
    final availableHeight = math.max(
      0.0,
      media.size.height - media.viewInsets.bottom - media.padding.vertical - 16,
    );
    final itemCount = _showEffort ? options.length : filtered.length;

    return AnimatedPadding(
      duration: AppMotion.quick,
      curve: AppMotion.standard,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        media.viewInsets.bottom + AppSpacing.sm,
      ),
      child: Material(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(AppRadii.floatingSheet),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.min(media.size.height * 0.58, availableHeight),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.borderStrong,
                        borderRadius: AppShapes.pill,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      IconButton.filledTonal(
                        tooltip: _showEffort ? 'Back to models' : 'Close',
                        style: AppControlStyles.sheetIcon(colors),
                        icon: Icon(
                          _showEffort
                              ? Icons.arrow_back_rounded
                              : Icons.close_rounded,
                        ),
                        onPressed: () {
                          if (_showEffort) {
                            setState(() => _showEffort = false);
                          } else {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                      Expanded(
                        child: Text(
                          _showEffort ? 'Effort' : 'Choose a model',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: AppFontSizes.picker,
                          ),
                        ),
                      ),
                      if (!_showEffort && widget.models.length > 6)
                        IconButton(
                          tooltip: _searching
                              ? 'Hide model search'
                              : 'Search models',
                          icon: Icon(
                            _searching
                                ? Icons.search_off_rounded
                                : Icons.search_rounded,
                          ),
                          onPressed: () {
                            setState(() {
                              _searching = !_searching;
                              if (!_searching) _queryController.clear();
                            });
                            if (_searching) {
                              _searchFocus.requestFocus();
                            } else {
                              _searchFocus.unfocus();
                            }
                          },
                        )
                      else
                        const SizedBox(width: 44),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (!_showEffort && _searching) ...[
                    TextField(
                      controller: _queryController,
                      focusNode: _searchFocus,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      style: AppControlStyles.searchText(context),
                      decoration: AppControlStyles.search(
                        context,
                      ).copyWith(hintText: 'Search models'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (!_showEffort && canChooseEffort)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      minTileHeight: AppSizes.control,
                      title: Text(
                        'Effort',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            reasoningEffortLabel(effort),
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: AppSizes.icon,
                            color: colors.textSecondary,
                          ),
                        ],
                      ),
                      onTap: () {
                        _searchFocus.unfocus();
                        setState(() => _showEffort = true);
                      },
                    ),
                  if (!_showEffort && canChooseEffort)
                    const SizedBox(height: AppSpacing.sm),
                  Flexible(
                    child: Material(
                      key: const ValueKey('mobile-model-list'),
                      color: colors.surfaceElevated,
                      borderRadius: BorderRadius.circular(AppRadii.sheet),
                      clipBehavior: Clip.antiAlias,
                      child: itemCount == 0
                          ? const Padding(
                              padding: EdgeInsets.all(AppSpacing.xl),
                              child: Text('No models match that search.'),
                            )
                          : ListView.separated(
                              key: ValueKey(_showEffort),
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: itemCount,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                thickness: AppStrokes.hairline,
                                indent: 16,
                                endIndent: 16,
                                color: colors.border,
                              ),
                              itemBuilder: (context, index) {
                                if (_showEffort) {
                                  final option = options[index];
                                  return _choiceRow(
                                    title: reasoningEffortLabel(
                                      option.reasoningEffort,
                                    ),
                                    subtitle:
                                        option.reasoningEffort ==
                                            current?.defaultReasoningEffort
                                        ? 'Default'
                                        : null,
                                    selected: option.reasoningEffort == effort,
                                    onTap: () async {
                                      await widget.onReasoningSelected!(
                                        option.reasoningEffort,
                                      );
                                      if (!mounted) return;
                                      setState(() {
                                        _reasoning = option.reasoningEffort;
                                        _showEffort = false;
                                      });
                                    },
                                  );
                                }
                                final model = filtered[index];
                                return _choiceRow(
                                  title: model.displayName,
                                  subtitle: model.description.isEmpty
                                      ? null
                                      : model.description,
                                  selected: model.model == widget.currentModel,
                                  onTap: () => widget.onModelSelected(model),
                                );
                              },
                            ),
                    ),
                  ),
                  if (!_showEffort && widget.onUseDefault != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: widget.onUseDefault,
                        style: AppControlStyles.foreground(
                          colors.textSecondary,
                        ),
                        child: Text(
                          widget.usesDefault
                              ? 'Using machine default'
                              : 'Use default model',
                        ),
                      ),
                    ),
                  if (_showEffort) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Higher effort takes more time and uses more of your limits.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choiceRow({
    required String title,
    required bool selected,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      child: ListTile(
        minTileHeight: subtitle == null
            ? AppSizes.choiceRow
            : AppSizes.choiceRowWithDescription,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize: AppFontSizes.picker,
            height: AppLineHeights.title,
            color: colors.textPrimary,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
        trailing: selected
            ? Icon(
                Icons.check_rounded,
                color: colors.accent,
                size: AppSizes.largeIcon,
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}
