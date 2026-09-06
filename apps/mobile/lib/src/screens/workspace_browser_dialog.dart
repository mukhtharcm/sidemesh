import 'package:flutter/material.dart';

import '../api_client.dart';
import '../fs_models.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/mesh_widgets.dart';
import 'file_browser_screen.dart';
import 'file_viewer_pane.dart';

/// Desktop-friendly workspace browser: split-pane dialog with the file tree
/// on the left and the selected file on the right.
Future<void> showWorkspaceBrowserDialog(
  BuildContext context, {
  required HostProfile host,
  required ApiClient api,
  required String root,
  String? agentProvider,
  String? sessionId,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: AppOverlayColors.modalBarrier,
    builder: (dialogContext) => _WorkspaceBrowserDialog(
      host: host,
      api: api,
      root: root,
      agentProvider: agentProvider,
      sessionId: sessionId,
    ),
  );
}

class _WorkspaceBrowserDialog extends StatefulWidget {
  const _WorkspaceBrowserDialog({
    required this.host,
    required this.api,
    required this.root,
    required this.agentProvider,
    required this.sessionId,
  });

  final HostProfile host;
  final ApiClient api;
  final String root;
  final String? agentProvider;
  final String? sessionId;

  @override
  State<_WorkspaceBrowserDialog> createState() =>
      _WorkspaceBrowserDialogState();
}

class _WorkspaceBrowserDialogState extends State<_WorkspaceBrowserDialog> {
  String? _selected;
  Stream<FsChangeEvent>? _liveStream;
  final ValueNotifier<int> _viewerObservable = ValueNotifier<int>(0);
  final GlobalKey<FileViewerPaneState> _viewerKey =
      GlobalKey<FileViewerPaneState>();

  @override
  void dispose() {
    _viewerObservable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mediaSize = MediaQuery.of(context).size;
    final maxWidth = (mediaSize.width * 0.9).clamp(720.0, 1280.0);
    final maxHeight = (mediaSize.height * 0.88).clamp(520.0, 900.0);

    return Dialog(
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxxl,
        vertical: AppSpacing.xxxl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.toDouble(),
          maxHeight: maxHeight.toDouble(),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceElevated,
            borderRadius: AppShapes.dialog,
            border: Border.all(color: colors.border),
            boxShadow: AppShadows.dialog(colors.textPrimary),
          ),
          child: ClipRRect(
            borderRadius: AppShapes.dialog,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DialogHeader(
                  host: widget.host,
                  root: widget.root,
                  onClose: () => Navigator.of(context).pop(),
                ),
                Divider(height: 1, color: colors.border),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 300,
                        child: Container(
                          color: colors.surface,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _DialogPaneHeader(
                                icon: Icons.folder_copy_rounded,
                                title: 'Folders',
                                subtitle: baseName(widget.root).isEmpty
                                    ? widget.root
                                    : baseName(widget.root),
                              ),
                              Divider(height: 1, color: colors.border),
                              Expanded(
                                child: FileBrowserTree(
                                  host: widget.host,
                                  api: widget.api,
                                  root: widget.root,
                                  agentProvider: widget.agentProvider,
                                  sessionId: widget.sessionId,
                                  selectedPath: _selected,
                                  onOpenFile: (path, liveStream) {
                                    setState(() {
                                      _selected = path;
                                      _liveStream = liveStream;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      VerticalDivider(width: 1, color: colors.border),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _DialogPaneHeader(
                              icon: _selected == null
                                  ? Icons.description_rounded
                                  : Icons.insert_drive_file_rounded,
                              title: _selected == null
                                  ? 'Preview'
                                  : baseName(_selected!),
                              subtitle: _selected == null ? '' : _selected!,
                              trailing: _selected == null
                                  ? null
                                  : ListenableBuilder(
                                      listenable: _viewerObservable,
                                      builder: (context, _) =>
                                          FileViewerActions(
                                            state: _viewerKey.currentState,
                                          ),
                                    ),
                            ),
                            Divider(height: 1, color: colors.border),
                            Expanded(
                              child: _selected == null
                                  ? const Center(
                                      child: MeshEmptyState(
                                        icon: Icons.description_rounded,
                                        title: 'Choose a file',
                                        body:
                                            'Pick a file on the left to open it here.',
                                      ),
                                    )
                                  : FileViewerPane(
                                      key: _viewerKey,
                                      host: widget.host,
                                      api: widget.api,
                                      path: _selected!,
                                      agentProvider: widget.agentProvider,
                                      sessionId: widget.sessionId,
                                      observable: _viewerObservable,
                                      dense: true,
                                      liveStream: _liveStream,
                                      onOpenFile: (path) {
                                        setState(() => _selected = path);
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({
    required this.host,
    required this.root,
    required this.onClose,
  });

  final HostProfile host;
  final String root;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final rootLabel = baseName(root).isEmpty ? root : baseName(root);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.compact,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_open_rounded,
            size: AppSizes.inlineIcon,
            color: colors.accent,
          ),
          const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Browse files',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: AppWeights.strong,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  '${host.label} · $rootLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: AppSizes.icon),
          ),
        ],
      ),
    );
  }
}

class _DialogPaneHeader extends StatelessWidget {
  const _DialogPaneHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: AppShapes.action,
              border: Border.all(color: colors.border),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: AppSizes.inlineIcon, color: colors.accent),
          ),
          const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: AppWeights.strong,
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}
