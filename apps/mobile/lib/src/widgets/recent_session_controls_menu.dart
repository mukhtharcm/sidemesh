import 'dart:async';

import 'package:flutter/material.dart';

import '../recent_session_view_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'app_menu.dart';

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
    this.onOpenSettings,
  });

  final RecentSessionViewStore? store;
  final bool showGrouping;
  final RecentSessionFilters? filters;
  final ValueChanged<bool>? onRunningOnlyChanged;
  final ValueChanged<bool>? onUnreadOnlyChanged;
  final ValueChanged<bool>? onFavoritesOnlyChanged;
  final VoidCallback? onOpenSettings;

  bool get _showsFilters => filters != null;

  bool get _showsActions => onOpenSettings != null;

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
            const AppMenuSectionLabel('Group by'),
            AppMenuItem(
              label: 'Project',
              selected: grouping == RecentSessionGrouping.project,
              mutuallyExclusive: true,
              closeOnActivate: false,
              onPressed: () => unawaited(
                viewStore.setGrouping(RecentSessionGrouping.project),
              ),
            ),
            AppMenuItem(
              label: 'Single list',
              selected: grouping == RecentSessionGrouping.singleList,
              mutuallyExclusive: true,
              closeOnActivate: false,
              onPressed: () => unawaited(
                viewStore.setGrouping(RecentSessionGrouping.singleList),
              ),
            ),
          ],
          if (showGrouping && _showsFilters) const Divider(height: 1),
          if (currentFilters != null) ...[
            const AppMenuSectionLabel('Filter'),
            AppMenuItem(
              label: 'Favorites',
              selected: currentFilters.favoritesOnly,
              closeOnActivate: false,
              onPressed: onFavoritesOnlyChanged == null
                  ? null
                  : () => onFavoritesOnlyChanged!(
                      !currentFilters.favoritesOnly,
                    ),
            ),
            AppMenuItem(
              label: 'Running',
              selected: currentFilters.runningOnly,
              closeOnActivate: false,
              onPressed: onRunningOnlyChanged == null
                  ? null
                  : () => onRunningOnlyChanged!(!currentFilters.runningOnly),
            ),
            AppMenuItem(
              label: 'Unread',
              selected: currentFilters.unreadOnly,
              closeOnActivate: false,
              onPressed: onUnreadOnlyChanged == null
                  ? null
                  : () => onUnreadOnlyChanged!(!currentFilters.unreadOnly),
            ),
          ],
          if ((showGrouping || _showsFilters) && _showsActions)
            const Divider(height: 1),
          if (onOpenSettings != null)
            AppMenuItem(
              label: 'Settings',
              leadingIcon: Icons.tune_rounded,
              onPressed: onOpenSettings,
            ),
        ];

        return MenuAnchor(
          animated: true,
          style: MenuStyle(
            minimumSize: const WidgetStatePropertyAll(Size(200, 0)),
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
