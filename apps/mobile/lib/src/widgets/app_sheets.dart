import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

class MeshBottomSheetScaffold extends StatelessWidget {
  const MeshBottomSheetScaffold({
    super.key,
    this.icon,
    required this.title,
    this.description = '',
    required this.child,
    this.actions = const <Widget>[],
    this.maxWidth = 720,
    this.maxHeightFactor = 0.82,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.sm,
      AppSpacing.lg,
      AppSpacing.lg,
    ),
  });

  final IconData? icon;
  final String title;
  final String description;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;
  final double maxHeightFactor;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mediaSize = MediaQuery.sizeOf(context);
    final maxHeight = mediaSize.height * maxHeightFactor;
    final compact = mediaSize.width < 760;
    final radius = compact ? AppShapes.sheetTop : AppShapes.dialog;
    return SafeArea(
      top: false,
      bottom: !compact,
      child: Padding(
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                0,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
        child: Align(
          alignment: compact ? Alignment.bottomCenter : Alignment.center,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxHeight,
              maxWidth: maxWidth,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceElevated,
                borderRadius: radius,
                border: compact ? null : Border.all(color: colors.border),
                boxShadow: compact
                    ? null
                    : AppShadows.sheet(colors.textPrimary),
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: SafeArea(
                  top: false,
                  bottom: compact,
                  child: Padding(
                    padding: padding,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (compact)
                          Center(
                            child: Container(
                              width: AppSizes.compactControl,
                              height: 4,
                              decoration: BoxDecoration(
                                color: colors.borderStrong.withValues(
                                  alpha: AppEmphasis.medium,
                                ),
                                borderRadius: AppShapes.pill,
                              ),
                            ),
                          ),
                        const SizedBox(height: AppSpacing.md),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (icon != null) ...[
                              SizedBox(
                                width: AppSizes.icon,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: AppSpacing.xxs,
                                  ),
                                  child: Icon(
                                    icon,
                                    size: AppSizes.icon,
                                    color: colors.accent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: colors.textPrimary,
                                          fontWeight: AppWeights.title,
                                          letterSpacing:
                                              AppLetterSpacing.headline,
                                        ),
                                  ),
                                  if (description.isNotEmpty) ...[
                                    const SizedBox(height: AppSpacing.xs),
                                    Text(
                                      description,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: colors.textSecondary,
                                            fontWeight: AppWeights.body,
                                            height: AppLineHeights.caption,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            ...actions,
                            IconButton(
                              icon: const Icon(Icons.close_rounded),
                              tooltip: 'Close',
                              color: colors.textSecondary,
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Flexible(child: child),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
