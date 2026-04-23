import 'package:flutter/material.dart';

import '../api_client.dart';
import '../fs_languages.dart';
import '../fs_models.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
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
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (dialogContext) => _WorkspaceBrowserDialog(
      host: host,
      api: api,
      root: root,
    ),
  );
}

class _WorkspaceBrowserDialog extends StatefulWidget {
  const _WorkspaceBrowserDialog({
    required this.host,
    required this.api,
    required this.root,
  });

  final HostProfile host;
  final ApiClient api;
  final String root;

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
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.toDouble(),
          maxHeight: maxHeight.toDouble(),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DialogHeader(
              host: widget.host,
              root: widget.root,
              selected: _selected,
              viewerObservable: _viewerObservable,
              viewerKey: _viewerKey,
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
                      color: colors.surfaceElevated,
                      child: FileBrowserTree(
                        host: widget.host,
                        api: widget.api,
                        root: widget.root,
                        selectedPath: _selected,
                        onOpenFile: (path, liveStream) {
                          setState(() {
                            _selected = path;
                            _liveStream = liveStream;
                          });
                        },
                      ),
                    ),
                  ),
                  VerticalDivider(width: 1, color: colors.border),
                  Expanded(
                    child: _selected == null
                        ? Center(
                            child: MeshEmptyState(
                              icon: Icons.description_outlined,
                              title: 'Select a file',
                              body: 'Pick a file on the left to view or edit.',
                            ),
                          )
                        : FileViewerPane(
                            key: _viewerKey,
                            host: widget.host,
                            api: widget.api,
                            path: _selected!,
                            observable: _viewerObservable,
                            dense: true,
                            liveStream: _liveStream,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({
    required this.host,
    required this.root,
    required this.selected,
    required this.viewerObservable,
    required this.viewerKey,
    required this.onClose,
  });

  final HostProfile host;
  final String root;
  final String? selected;
  final ValueNotifier<int> viewerObservable;
  final GlobalKey<FileViewerPaneState> viewerKey;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final selectedPath = selected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.folder_open_rounded, size: 18, color: colors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selectedPath == null
                      ? baseName(root)
                      : baseName(selectedPath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (selectedPath != null &&
                        languageForPath(selectedPath) != null) ...[
                      MeshPill(
                        label: languageForPath(selectedPath)!,
                        mono: true,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        selectedPath ?? '$root • ${host.label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (selectedPath != null)
            ListenableBuilder(
              listenable: viewerObservable,
              builder: (context, _) =>
                  FileViewerActions(state: viewerKey.currentState),
            ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
