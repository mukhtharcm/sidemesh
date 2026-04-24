import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../fs_languages.dart';
import '../../fs_models.dart';
import '../../models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mesh_widgets.dart';
import '../file_browser_screen.dart';
import '../file_viewer_pane.dart';
import 'inspector_controller.dart';

/// Builds an [InspectorSurface] that hosts the workspace browser
/// (file tree + viewer) in pane 3 on desktop.
InspectorSurface buildInspectorWorkspaceBrowserSurface({
  required String ownerKey,
  required HostProfile host,
  required ApiClient api,
  required String root,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.fileBrowser,
    ownerKey: ownerKey,
    title: baseName(root),
    icon: Icons.folder_open_rounded,
    bodyBuilder: (context) => WorkspaceBrowserPane(
      host: host,
      api: api,
      root: root,
    ),
  );
}

/// Split-pane workspace browser body: file tree on the left, viewer on
/// the right, and a compact toolbar above the viewer exposing the
/// standard [FileViewerActions] for the currently selected file.
class WorkspaceBrowserPane extends StatefulWidget {
  const WorkspaceBrowserPane({
    super.key,
    required this.host,
    required this.api,
    required this.root,
    this.treeWidth = 260,
  });

  final HostProfile host;
  final ApiClient api;
  final String root;
  final double treeWidth;

  @override
  State<WorkspaceBrowserPane> createState() => _WorkspaceBrowserPaneState();
}

class _WorkspaceBrowserPaneState extends State<WorkspaceBrowserPane> {
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: widget.treeWidth,
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
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ViewerToolbar(
                      path: _selected!,
                      viewerObservable: _viewerObservable,
                      viewerKey: _viewerKey,
                    ),
                    Divider(height: 1, color: colors.border),
                    Expanded(
                      child: FileViewerPane(
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
    );
  }
}

class _ViewerToolbar extends StatelessWidget {
  const _ViewerToolbar({
    required this.path,
    required this.viewerObservable,
    required this.viewerKey,
  });

  final String path;
  final ValueNotifier<int> viewerObservable;
  final GlobalKey<FileViewerPaneState> viewerKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final language = languageForPath(path);
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  baseName(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (language != null) ...[
                      MeshPill(label: language, mono: true),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        path,
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
          ListenableBuilder(
            listenable: viewerObservable,
            builder: (context, _) =>
                FileViewerActions(state: viewerKey.currentState),
          ),
        ],
      ),
    );
  }
}
