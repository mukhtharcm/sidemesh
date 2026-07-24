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
  String? agentProvider,
  String? sessionId,
  String? selectedPath,
}) {
  // Shared notifier so the header's reload action can trigger a refresh
  // inside the body without needing a GlobalKey or BuildContext indirection.
  final reloadNotifier = ValueNotifier<int>(0);
  return InspectorSurface(
    kind: InspectorSurfaceKind.fileBrowser,
    ownerKey: ownerKey,
    title: 'Files',
    icon: Icons.folder_open_rounded,
    actionsBuilder: (context) => [
      Tooltip(
        message: 'Reload files',
        child: InkResponse(
          radius: 18,
          onTap: () => reloadNotifier.value++,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              Icons.refresh_rounded,
              size: 16,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    ],
    bodyBuilder: (context) => WorkspaceBrowserPane(
      // ValueKey on ownerKey ensures the widget is fully replaced (and its
      // state reset) when the active session changes. Without this, Flutter
      // reuses _WorkspaceBrowserPaneState across sessions and FileBrowserTree
      // keeps showing the previous session's directory tree.
      key: ValueKey(ownerKey),
      host: host,
      api: api,
      root: root,
      agentProvider: agentProvider,
      sessionId: sessionId,
      initialSelectedPath: selectedPath,
      reloadNotifier: reloadNotifier,
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
    this.agentProvider,
    this.sessionId,
    this.initialSelectedPath,
    this.reloadNotifier,
  });

  final HostProfile host;
  final ApiClient api;
  final String root;
  final String? agentProvider;
  final String? sessionId;
  final String? initialSelectedPath;
  /// When incremented, forces the file tree to reload from the host.
  final ValueNotifier<int>? reloadNotifier;

  @override
  State<WorkspaceBrowserPane> createState() => _WorkspaceBrowserPaneState();
}

class _WorkspaceBrowserPaneState extends State<WorkspaceBrowserPane> {
  late String? _selected = widget.initialSelectedPath;
  Stream<FsChangeEvent>? _liveStream;
  final ValueNotifier<int> _viewerObservable = ValueNotifier<int>(0);
  final GlobalKey<FileViewerPaneState> _viewerKey =
      GlobalKey<FileViewerPaneState>();
  late bool _inViewerMode = widget.initialSelectedPath != null;
  // Incremented to force FileBrowserTree to rebuild and re-fetch from host.
  int _treeGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.reloadNotifier?.addListener(_onReload);
  }

  void _onReload() {
    setState(() {
      _treeGeneration++;
      _selected = null;
      _inViewerMode = false;
      _liveStream = null;
    });
    _clearViewer();
  }

  @override
  void didUpdateWidget(covariant WorkspaceBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadNotifier != widget.reloadNotifier) {
      oldWidget.reloadNotifier?.removeListener(_onReload);
      widget.reloadNotifier?.addListener(_onReload);
    }
    final initialChanged =
        oldWidget.initialSelectedPath != widget.initialSelectedPath;
    final rootChanged = oldWidget.root != widget.root;
    if (!initialChanged && !rootChanged) {
      return;
    }
    setState(() {
      _selected = widget.initialSelectedPath;
      _inViewerMode = widget.initialSelectedPath != null;
      _liveStream = null;
      _treeGeneration++;
    });
  }

  @override
  void dispose() {
    widget.reloadNotifier?.removeListener(_onReload);
    _viewerObservable.dispose();
    super.dispose();
  }

  void _backToTree() {
    setState(() {
      _liveStream = null;
      // Keep _selected so the tree can highlight the last-viewed file
      // — makes sibling navigation fast.
    });
    _clearViewer();
  }

  void _clearViewer() {
    // Force viewer teardown by bumping the state key to null on next
    // build via _inViewerMode flag.
    setState(() => _inViewerMode = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Always kept mounted so the tree's fetched directory state is
        // preserved when the user toggles back from a file viewer.
        Offstage(
          offstage: _inViewerMode,
          child: TickerMode(
            enabled: !_inViewerMode,
            child: Container(
              color: colors.surfaceElevated,
              child: FileBrowserTree(
                key: ValueKey(_treeGeneration),
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
                    _inViewerMode = true;
                  });
                },
              ),
            ),
          ),
        ),
        if (_inViewerMode && _selected != null)
          Positioned.fill(
            child: Container(
              color: colors.canvas,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ViewerToolbar(
                    path: _selected!,
                    viewerObservable: _viewerObservable,
                    viewerKey: _viewerKey,
                    onBack: _backToTree,
                  ),
                  Divider(height: 1, color: colors.border),
                  Expanded(
                    child: FileViewerPane(
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
    required this.onBack,
  });

  final String path;
  final ValueNotifier<int> viewerObservable;
  final GlobalKey<FileViewerPaneState> viewerKey;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final language = languageForPath(path);
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
      child: Row(
        children: [
          InkResponse(
            radius: 20,
            onTap: onBack,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.arrow_back_rounded,
                size: 18,
                color: colors.textSecondary,
              ),
            ),
          ),
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
