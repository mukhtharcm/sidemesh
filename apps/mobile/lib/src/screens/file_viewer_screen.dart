import 'package:flutter/material.dart';

import '../api_client.dart';
import '../fs_languages.dart';
import '../fs_models.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';
import 'file_viewer_pane.dart';
import 'pdf_viewer_pane.dart';

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
    this.pdfViewerBuilder,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String? agentProvider;
  final String? sessionId;
  final double? topPadding;
  final Stream<FsChangeEvent>? liveStream;
  final PdfViewerPanePreviewBuilder? pdfViewerBuilder;

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
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: colors.border)),
        title: ListenableBuilder(
          listenable: _observable,
          builder: (context, _) {
            final state = _paneKey.currentState;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  baseName(widget.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (languageId != null) ...[
                      MeshPill(label: languageId, mono: true),
                      const SizedBox(width: 6),
                    ],
                    if (state?.file != null)
                      Flexible(
                        child: Text(
                          '${formatBytes(state!.file!.size)} on ${widget.host.label}',
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
            );
          },
        ),
        actions: [
          ListenableBuilder(
            listenable: _observable,
            builder: (context, _) =>
                FileViewerActions(state: _paneKey.currentState),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: FileViewerPane(
        key: _paneKey,
        host: widget.host,
        api: widget.api,
        path: widget.path,
        agentProvider: widget.agentProvider,
        sessionId: widget.sessionId,
        liveStream: widget.liveStream,
        observable: _observable,
        pdfViewerBuilder: widget.pdfViewerBuilder,
        onOpenFile: (path) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FileViewerScreen(
                host: widget.host,
                api: widget.api,
                path: path,
                agentProvider: widget.agentProvider,
                sessionId: widget.sessionId,
                liveStream: widget.liveStream,
                pdfViewerBuilder: widget.pdfViewerBuilder,
              ),
            ),
          );
        },
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
