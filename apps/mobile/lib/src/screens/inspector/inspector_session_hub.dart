import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_tokens.dart';
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
  required VoidCallback onOpenPorts,
  required VoidCallback onOpenResources,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.sessionHub,
    ownerKey: ownerKey,
    title: 'Session tools',
    icon: Icons.widgets_rounded,
    bodyBuilder: (context) => _SessionHubBody(
      onOpenSearch: onOpenSearch,
      onOpenPinned: onOpenPinned,
      onOpenFiles: onOpenFiles,
      onOpenTerminal: onOpenTerminal,
      onOpenPorts: onOpenPorts,
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
    required this.onOpenPorts,
    required this.onOpenResources,
  });

  final VoidCallback onOpenSearch;
  final VoidCallback onOpenPinned;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenPorts;
  final VoidCallback onOpenResources;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final transcriptTools = [
      _HubTool(
        icon: Icons.search_rounded,
        label: 'Search transcript',
        description: 'Find text across loaded messages.',
        onTap: onOpenSearch,
      ),
      _HubTool(
        icon: Icons.push_pin_rounded,
        label: 'Pinned messages',
        description: 'Review saved excerpts from this session.',
        onTap: onOpenPinned,
      ),
      _HubTool(
        icon: Icons.perm_media_rounded,
        label: 'Resources',
        description: 'Open generated files and attachments.',
        onTap: onOpenResources,
      ),
    ];
    final workspaceTools = [
      _HubTool(
        icon: Icons.folder_rounded,
        label: 'Files',
        description: 'Browse the current workspace.',
        onTap: onOpenFiles,
      ),
      _HubTool(
        icon: Icons.terminal_rounded,
        label: 'Terminal',
        description: 'Open a shell in this workspace.',
        onTap: onOpenTerminal,
      ),
      _HubTool(
        icon: Icons.cable_rounded,
        label: 'Connections',
        description: 'Manage browser previews and port forwards.',
        onTap: onOpenPorts,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MeshCard(
            tone: MeshCardTone.muted,
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: colors.accentMuted,
                    borderRadius: AppShapes.input,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.widgets_rounded,
                    size: 16,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Open a tool',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: AppWeights.title,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Inspector tools stay in this pane so your transcript remains visible.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _HubSection(
            label: 'TRANSCRIPT',
            tools: transcriptTools,
          ),
          const SizedBox(height: AppSpacing.md),
          _HubSection(
            label: 'WORKSPACE',
            tools: workspaceTools,
          ),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Text(
              'You can also jump to these tools from the session toolbar at the top.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
                height: 1.45,
              ),
            ),
          ),
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
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Text(
            label,
            style: monoStyle(
              color: colors.textTertiary,
              fontSize: 10.5,
              fontWeight: AppWeights.emphasis,
            ).copyWith(letterSpacing: AppLetterSpacing.caps),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        MeshCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var index = 0; index < tools.length; index++) ...[
                _HubToolRow(tool: tools[index]),
                if (index != tools.length - 1)
                  Builder(
                    builder: (context) => Padding(
                      padding: const EdgeInsets.only(left: 56, right: 12),
                      child: Divider(height: 1, color: context.colors.border),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: AppShapes.card,
        onTap: tool.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: AppShapes.input,
                ),
                alignment: Alignment.center,
                child: Icon(tool.icon, size: 16, color: colors.accent),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tool.label,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tool.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
