import 'dart:async';

import 'package:flutter/material.dart';

import '../recent_session_view_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

class RecentSessionFilters {
  const RecentSessionFilters({
    this.runningOnly = false,
    this.unreadOnly = false,
    this.favoritesOnly = false,
  });

  final bool runningOnly;
  final bool unreadOnly;
  final bool favoritesOnly;

  bool get isAnyActive => runningOnly || unreadOnly || favoritesOnly;

  RecentSessionFilters copyWith({
    bool? runningOnly,
    bool? unreadOnly,
    bool? favoritesOnly,
  }) {
    return RecentSessionFilters(
      runningOnly: runningOnly ?? this.runningOnly,
      unreadOnly: unreadOnly ?? this.unreadOnly,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    );
  }
}

/// Compact adaptive control for recent-session grouping and filters.
///
/// The options are exposed directly in one menu. Checkboxes stay open so a
/// user can change several filters without repeatedly reopening the overflow.
class RecentSessionControlsMenu extends StatelessWidget {
  const RecentSessionControlsMenu({
    super.key,
    this.store,
    this.showGrouping = true,
    this.filters,
    this.onRunningOnlyChanged,
    this.onUnreadOnlyChanged,
    this.onFavoritesOnlyChanged,
    this.onRefresh,
    this.onOpenSettings,
  });

  final RecentSessionViewStore? store;
  final bool showGrouping;
  final RecentSessionFilters? filters;
  final ValueChanged<bool>? onRunningOnlyChanged;
  final ValueChanged<bool>? onUnreadOnlyChanged;
  final ValueChanged<bool>? onFavoritesOnlyChanged;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenSettings;

  bool get _showsFilters => filters != null;

  bool get _showsActions => onRefresh != null || onOpenSettings != null;

  @override
  Widget build(BuildContext context) {
    final viewStore = store ?? RecentSessionViewStore.instance;
    return ListenableBuilder(
      listenable: viewStore,
      builder: (context, _) {
        final colors = context.colors;
        final grouping = viewStore.grouping;
        final currentFilters = filters;
        final filtersActive = currentFilters?.isAnyActive == true;
        final menuChildren = <Widget>[
          if (showGrouping) ...[
            const _MenuSectionLabel('Group by'),
            RadioMenuButton<RecentSessionGrouping>(
              value: RecentSessionGrouping.project,
              groupValue: grouping,
              closeOnActivate: false,
              onChanged: (value) {
                if (value != null) {
                  unawaited(viewStore.setGrouping(value));
                }
              },
              child: const Text('Project'),
            ),
            RadioMenuButton<RecentSessionGrouping>(
              value: RecentSessionGrouping.singleList,
              groupValue: grouping,
              closeOnActivate: false,
              onChanged: (value) {
                if (value != null) {
                  unawaited(viewStore.setGrouping(value));
                }
              },
              child: const Text('Single list'),
            ),
          ],
          if (showGrouping && _showsFilters) const Divider(height: 1),
          if (currentFilters != null) ...[
            const _MenuSectionLabel('Filter'),
            CheckboxMenuButton(
              value: currentFilters.favoritesOnly,
              closeOnActivate: false,
              onChanged: onFavoritesOnlyChanged == null
                  ? null
                  : (value) => onFavoritesOnlyChanged!(value ?? false),
              child: const Text('Favorites'),
            ),
            CheckboxMenuButton(
              value: currentFilters.runningOnly,
              closeOnActivate: false,
              onChanged: onRunningOnlyChanged == null
                  ? null
                  : (value) => onRunningOnlyChanged!(value ?? false),
              child: const Text('Running'),
            ),
            CheckboxMenuButton(
              value: currentFilters.unreadOnly,
              closeOnActivate: false,
              onChanged: onUnreadOnlyChanged == null
                  ? null
                  : (value) => onUnreadOnlyChanged!(value ?? false),
              child: const Text('Unread'),
            ),
          ],
          if ((showGrouping || _showsFilters) && _showsActions)
            const Divider(height: 1),
          if (onRefresh != null)
            MenuItemButton(
              leadingIcon: const Icon(Icons.refresh_rounded),
              onPressed: onRefresh,
              child: const Text('Refresh'),
            ),
          if (onOpenSettings != null)
            MenuItemButton(
              leadingIcon: const Icon(Icons.tune_rounded),
              onPressed: onOpenSettings,
              child: const Text('Settings'),
            ),
        ];

        return MenuAnchor(
          animated: true,
          style: MenuStyle(
            minimumSize: const WidgetStatePropertyAll(Size(220, 0)),
            backgroundColor: WidgetStatePropertyAll(colors.surfaceElevated),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
                side: BorderSide(color: colors.border),
              ),
            ),
          ),
          menuChildren: menuChildren,
          builder: (context, controller, _) {
            final tooltip = switch ((showGrouping, _showsFilters)) {
              (true, true) when filtersActive =>
                'View and filter, filters active',
              (true, true) => 'View and filter',
              (true, false) => 'Group sessions',
              (false, true) when filtersActive => 'Filter, filters active',
              (false, true) => 'Filter',
              (false, false) => 'More',
            };
            return IconButton(
              tooltip: tooltip,
              onPressed: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    Icons.more_horiz_rounded,
                    color: colors.textSecondary,
                    size: AppSizes.icon,
                  ),
                  if (filtersActive)
                    PositionedDirectional(
                      top: -1,
                      end: -2,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: colors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _MenuSectionLabel extends StatelessWidget {
  const _MenuSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: context.colors.textTertiary,
          fontWeight: AppWeights.emphasis,
        ),
      ),
    );
  }
}
