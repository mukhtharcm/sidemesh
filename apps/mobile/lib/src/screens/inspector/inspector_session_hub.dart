import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/app_primitives.dart';
import '../../widgets/mesh_widgets.dart';
import 'inspector_controller.dart';

/// Builds the default inspector surface shown when a session first becomes
/// active and no previously-saved surface exists for it.
///
/// The hub presents quick-launch rows for every inspector tool. Tapping a row
/// calls the corresponding [on*] callback. The callbacks handle their own
/// capability checks and show a snackbar if the tool is not available on the
/// current host.
///
/// The hub is intentionally not persisted: [InspectorPersistence] skips it so
/// that next time the session opens it checks for a real saved surface first,
/// falling back to the hub again only when none is found.
InspectorSurface buildInspectorSessionHubSurface({
  required String ownerKey,
  required VoidCallback onOpenSearch,
  required VoidCallback onOpenPinned,
  required VoidCallback onOpenFiles,
  required VoidCallback onOpenTerminal,
  required VoidCallback onOpenBrowser,
  required VoidCallback onOpenResources,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.sessionHub,
    ownerKey: ownerKey,
    title: 'Tools',
    icon: Icons.widgets_rounded,
    bodyBuilder: (context) => _SessionHubBody(
      onOpenSearch: onOpenSearch,
      onOpenPinned: onOpenPinned,
      onOpenFiles: onOpenFiles,
      onOpenTerminal: onOpenTerminal,
      onOpenBrowser: onOpenBrowser,
      onOpenResources: onOpenResources,
    ),
  );
}

class _SessionHubBody extends StatelessWidget {
  const _SessionHubBody({
    required this.onOpenSearch,
    required this.onOpenPinned,
    required this.onOpenFiles,
    required this.onOpenTerminal,
    required this.onOpenBrowser,
    required this.onOpenResources,
  });

  final VoidCallback onOpenSearch;
  final VoidCallback onOpenPinned;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenBrowser;
  final VoidCallback onOpenResources;

  @override
  Widget build(BuildContext context) {
    final workspaceTools = [
      _HubTool(
        icon: Icons.terminal_rounded,
        label: 'Terminal',
        description: 'Open a command line on this machine.',
        onTap: onOpenTerminal,
      ),
      _HubTool(
        icon: Icons.folder_rounded,
        label: 'Files',
        description: 'Browse files for this session.',
        onTap: onOpenFiles,
      ),
      _HubTool(
        icon: Icons.open_in_browser_rounded,
        label: 'Browser',
        description: 'Open a tab for this session.',
        onTap: onOpenBrowser,
      ),
    ];
    final sessionTools = [
      _HubTool(
        icon: Icons.search_rounded,
        label: 'Search',
        description: 'Search this conversation.',
        onTap: onOpenSearch,
      ),
      _HubTool(
        icon: Icons.push_pin_rounded,
        label: 'Saved messages',
        description: 'Jump back to messages you pinned.',
        onTap: onOpenPinned,
      ),
      _HubTool(
        icon: Icons.perm_media_rounded,
        label: 'Resources',
        description: 'Open images, links, and files from this session.',
        onTap: onOpenResources,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HubSection(label: 'On this machine', tools: workspaceTools),
          const SizedBox(height: AppSpacing.md),
          _HubSection(label: 'This session', tools: sessionTools),
        ],
      ),
    );
  }
}

class _HubSection extends StatelessWidget {
  const _HubSection({required this.label, required this.tools});

  final String label;
  final List<_HubTool> tools;

  @override
  Widget build(BuildContext context) {
    return AppListSection(
      title: label,
      children: [for (final tool in tools) _HubToolRow(tool: tool)],
    );
  }
}

class _HubTool {
  const _HubTool({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
}

class _HubToolRow extends StatelessWidget {
  const _HubToolRow({required this.tool});

  final _HubTool tool;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshListRow(
      onTap: tool.onTap,
      dense: true,
      framed: false,
      radius: AppRadii.control,
      leading: AppIconWell(icon: tool.icon),
      title: Text(
        tool.label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: colors.textPrimary,
          fontWeight: AppWeights.title,
        ),
      ),
      subtitle: Text(
        tool.description,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colors.textSecondary,
          height: 1.35,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: colors.textTertiary,
      ),
    );
  }
}
