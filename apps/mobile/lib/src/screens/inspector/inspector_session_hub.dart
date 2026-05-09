import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_tokens.dart';
import 'inspector_controller.dart';

/// Builds the default inspector surface shown when a session first becomes
/// active and no previously-saved surface exists for it.
///
/// The hub presents a quick-launch grid for every inspector tool. Tapping
/// a tile calls the corresponding [on*] callback. The callbacks handle their
/// own capability checks and show a snackbar if the tool is not available on
/// the current host.
///
/// The hub is intentionally not persisted: [InspectorPersistence] skips it
/// so that next time the session opens it checks for a real saved surface
/// first, falling back to the hub again only when none is found.
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

// ── Body ─────────────────────────────────────────────────────────────────────

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
    final tools = [
      _HubTool(
        icon: Icons.search_rounded,
        label: 'Search',
        description: 'Find text across loaded messages.',
        onTap: onOpenSearch,
      ),
      _HubTool(
        icon: Icons.push_pin_rounded,
        label: 'Pinned',
        description: 'Review saved message excerpts.',
        onTap: onOpenPinned,
      ),
      _HubTool(
        icon: Icons.folder_rounded,
        label: 'Files',
        description: 'Browse workspace files.',
        onTap: onOpenFiles,
      ),
      _HubTool(
        icon: Icons.terminal_rounded,
        label: 'Terminal',
        description: 'Shell in this workspace.',
        onTap: onOpenTerminal,
      ),
      _HubTool(
        icon: Icons.cable_rounded,
        label: 'Connections',
        description: 'Port forwards and browser preview.',
        onTap: onOpenPorts,
      ),
      _HubTool(
        icon: Icons.perm_media_rounded,
        label: 'Resources',
        description: 'Session files and attachments.',
        onTap: onOpenResources,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Open a tool',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textSecondary,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: AppSpacing.sm,
              mainAxisSpacing: AppSpacing.sm,
              childAspectRatio: 1.25,
            ),
            itemCount: tools.length,
            itemBuilder: (context, index) =>
                _HubToolCard(tool: tools[index]),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Tools open in this pane. Switch between them using the toolbar buttons at the top of the session view.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tool descriptor ───────────────────────────────────────────────────────────

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

// ── Tile ──────────────────────────────────────────────────────────────────────

class _HubToolCard extends StatelessWidget {
  const _HubToolCard({required this.tool});

  final _HubTool tool;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: tool.onTap,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colors.accentMuted,
                borderRadius: BorderRadius.circular(AppRadii.input),
              ),
              child: Icon(tool.icon, size: 16, color: colors.accent),
            ),
            const Spacer(),
            Text(
              tool.label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: AppWeights.title,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              tool.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
                height: 1.3,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
