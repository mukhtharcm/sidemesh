import 'package:flutter/material.dart' hide Icon, Icons, IconData;
import './app_icons.dart';

import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
import '../theme/app_tokens.dart';
import 'mesh_widgets.dart';

class MeshBottomSheetScaffold extends StatelessWidget {
  const MeshBottomSheetScaffold({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.child,
    this.maxWidth = 720,
    this.maxHeightFactor = 0.82,
    this.padding = const EdgeInsets.fromLTRB(14, 10, 14, 14),
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget child;
  final double maxWidth;
  final double maxHeightFactor;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconForeground = readableSemanticForeground(
      colors,
      background: colors.accentMuted,
      preferred: colors.accent,
    );
    final maxHeight = MediaQuery.sizeOf(context).height * maxHeightFactor;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxHeight,
              maxWidth: maxWidth,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceElevated,
                borderRadius: AppShapes.sheet,
                border: Border.all(color: colors.border),
                boxShadow: AppShadows.sheet(colors.textPrimary),
              ),
              child: ClipRRect(
                borderRadius: AppShapes.sheet,
                child: Padding(
                  padding: padding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 34,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.borderStrong.withValues(alpha: 0.55),
                            borderRadius: AppShapes.pill,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: colors.accentMuted,
                              borderRadius: AppShapes.iconWell,
                              border: Border.all(
                                color: colors.accent.withValues(alpha: 0.24),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              icon,
                              size: 19,
                              color: iconForeground,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: colors.textPrimary,
                                        fontWeight: AppWeights.title,
                                        letterSpacing: -0.2,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  description,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colors.textSecondary,
                                        fontWeight: AppWeights.body,
                                        height: 1.35,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          MeshIconButton(
                            icon: Icons.close_rounded,
                            tooltip: 'Close',
                            color: colors.textSecondary,
                            onTap: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Expanded(child: child),
                    ],
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
