import 'package:flutter/material.dart';

import '../api_client.dart';
import '../fs_languages.dart';
import '../fs_models.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../widgets/mesh_status_line.dart';
import 'file_viewer_pane.dart';

/// Mobile-friendly full-screen file viewer. Wraps [FileViewerPane] in a
/// Scaffold + AppBar.
class FileViewerScreen extends StatefulWidget {
  const FileViewerScreen({
    super.key,
    required this.host,
    required this.api,
    required this.path,
    this.agentProvider,
    this.sessionId,
    this.topPadding,
    this.liveStream,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String? agentProvider;
  final String? sessionId;
  final double? topPadding;
  final Stream<FsChangeEvent>? liveStream;

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  final GlobalKey<FileViewerPaneState> _paneKey =
      GlobalKey<FileViewerPaneState>();
  final ValueNotifier<int> _observable = ValueNotifier<int>(0);

  @override
  void dispose() {
    _observable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final languageId = languageForPath(widget.path);
    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: ListenableBuilder(
              listenable: _observable,
              builder: (context, _) {
                final state = _paneKey.currentState;
                final isEditing = state?.editing ?? false;
                return MeshStatusLine(
                  segments: [
                    MeshStatusSegment(baseName(widget.path), mono: true),
                    if (languageId != null) MeshStatusSegment(languageId),
                    MeshStatusSegment(isEditing ? 'editing' : 'viewing'),
                  ],
                  actions: [
                    ListenableBuilder(
                      listenable: _observable,
                      builder: (context, _) =>
                          FileViewerActions(state: _paneKey.currentState),
                    ),
                  ],
                );
              },
            ),
          ),
          Expanded(
            child: FileViewerPane(
              key: _paneKey,
              host: widget.host,
              api: widget.api,
              path: widget.path,
              agentProvider: widget.agentProvider,
              sessionId: widget.sessionId,
              liveStream: widget.liveStream,
              observable: _observable,
            ),
          ),
        ],
      ),
    );
    final topPadding = widget.topPadding;
    if (topPadding == null) return scaffold;
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: scaffold,
    );
  }
}
