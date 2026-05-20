import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../fs_languages.dart';
import '../fs_models.dart';
import '../image_blob_cache_store.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/markdown_content.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/syntax_code_block.dart';
import 'image_viewer_screen.dart';
import 'video_viewer_pane.dart';

/// Embeddable read/edit pane for a single workspace file. Does not render a
/// Scaffold — use [FileViewerScreen] for the mobile-route variant.
class FileViewerPane extends StatefulWidget {
  const FileViewerPane({
    super.key,
    required this.host,
    required this.api,
    required this.path,
    this.agentProvider,
    this.sessionId,
    this.liveStream,
    this.dense = false,
    this.observable,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String? agentProvider;
  final String? sessionId;
  final Stream<FsChangeEvent>? liveStream;

  /// When true, uses tighter padding suitable for embedding in a desktop
  /// dialog pane.
  final bool dense;

  /// Bumped by the pane whenever observable state (file/editing/saving)
  /// changes, so external UI (app bar, dialog header) can rebuild.
  final ValueNotifier<int>? observable;

  @override
  State<FileViewerPane> createState() => FileViewerPaneState();
}

class FileViewerPaneState extends State<FileViewerPane> {
  FsFile? _file;
  Object? _error;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _markdownPreview = false;
  bool _imagePreview = false;
  bool _videoPreview = false;
  late final TextEditingController _editController = TextEditingController();
  StreamSubscription<FsChangeEvent>? _liveSub;

  /// Bumped whenever observable state (file/editing/saving) changes so
  /// external UI (e.g. the mobile viewer's AppBar) can rebuild.
  late final ValueNotifier<int> changes =
      widget.observable ?? ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _load();
    _attachLiveStream(widget.liveStream);
  }

  @override
  void didUpdateWidget(covariant FileViewerPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _editing = false;
      _markdownPreview = false;
      _imagePreview = false;
      _videoPreview = false;
      _editController.clear();
      _load();
    }
    if (oldWidget.liveStream != widget.liveStream) {
      _attachLiveStream(widget.liveStream);
    }
  }

  void _attachLiveStream(Stream<FsChangeEvent>? stream) {
    _liveSub?.cancel();
    _liveSub = null;
    if (stream == null) return;
    _liveSub = stream.listen((event) {
      if (!mounted) return;
      final matches =
          event.changedPaths.contains(widget.path) || event.path == widget.path;
      if (matches && !_editing) {
        _load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    _editController.dispose();
    if (widget.observable == null) {
      changes.dispose();
    }
    super.dispose();
  }

  void _bump() => changes.value++;

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final file = await widget.api.readFile(
        widget.host,
        widget.path,
        agentProvider: widget.agentProvider,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      setState(() {
        _file = file;
        _loading = false;
        _error = null;
        _imagePreview =
            !_editing && _looksLikeImageFile(file.path, file.mimeHint);
        _videoPreview =
            !_editing &&
            _videoPreview &&
            _looksLikeVideoFile(file.path, file.mimeHint);
        if (!_editing) {
          _editController.text = file.contents;
        }
      });
      _bump();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
      _bump();
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    final confirmed = await showMeshConfirmDialog(
      context,
      icon: Icons.save_outlined,
      title: 'Save these changes?',
      description:
          'This will overwrite the file on the connected machine with what you see here now.',
      confirmLabel: 'Save changes',
      child: Builder(
        builder: (dialogContext) {
          final colors = dialogContext.colors;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'File',
                style: Theme.of(
                  dialogContext,
                ).textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
              ),
              const SizedBox(height: 4),
              SelectableText(
                widget.path,
                style: monoStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true) return;
    setState(() => _saving = true);
    _bump();
    try {
      await widget.api.writeFile(
        widget.host,
        path: widget.path,
        contents: _editController.text,
        agentProvider: widget.agentProvider,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
      });
      _bump();
      showAppSnackBar(context, 'Saved changes');
      await _load(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _bump();
      showAppSnackBar(
        context,
        'Could not save changes: ${friendlyError(error)}',
      );
    }
  }

  void toggleEdit() {
    if (_file == null) return;
    setState(() {
      _editing = !_editing;
      if (_editing) {
        _markdownPreview = false;
        _imagePreview = false;
        _videoPreview = false;
      }
      if (_editing) {
        _editController.text = _file!.contents;
      }
    });
    _bump();
  }

  void refresh() => _load();

  void toggleMarkdownPreview() {
    if (!supportsMarkdownPreview) {
      return;
    }
    setState(() {
      _markdownPreview = !_markdownPreview;
      if (_markdownPreview) {
        _imagePreview = false;
        _videoPreview = false;
      }
    });
    _bump();
  }

  void toggleImagePreview() {
    if (!supportsImagePreview) {
      return;
    }
    setState(() {
      _imagePreview = !_imagePreview;
      if (_imagePreview) {
        _markdownPreview = false;
        _videoPreview = false;
      }
    });
    _bump();
  }

  void toggleVideoPreview() {
    if (!supportsVideoPreview) {
      return;
    }
    setState(() {
      _videoPreview = !_videoPreview;
      if (_videoPreview) {
        _markdownPreview = false;
        _imagePreview = false;
      }
    });
    _bump();
  }

  Future<void> copyContents() async {
    final file = _file;
    if (file == null) return;
    await Clipboard.setData(ClipboardData(text: file.contents));
    if (!mounted) return;
    showAppSnackBar(context, 'Copied');
  }

  bool get editing => _editing;
  bool get saving => _saving;
  FsFile? get file => _file;
  VoidCallback? get saveAction => _editing ? _save : null;
  bool get isMarkdownFile => languageForPath(widget.path) == 'markdown';
  bool get isImageFile => _looksLikeImageFile(widget.path, _file?.mimeHint);
  bool get isVideoFile => _looksLikeVideoFile(widget.path, _file?.mimeHint);
  bool get supportsMarkdownPreview =>
      !_editing && _file != null && isMarkdownFile;
  bool get supportsImagePreview => !_editing && _file != null && isImageFile;
  bool get supportsVideoPreview => !_editing && _file != null && isVideoFile;
  bool get markdownPreview => _markdownPreview;
  bool get imagePreview => _imagePreview;
  bool get videoPreview => _videoPreview;

  @override
  Widget build(BuildContext context) {
    if (_loading && _file == null) {
      return _FileViewerLoadingState(dense: widget.dense);
    }
    if (_error != null && _file == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: MeshEmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Could not open file',
          body: friendlyError(_error!),
        ),
      );
    }
    final file = _file!;
    return _buildBody(context, file);
  }

  Widget _buildBody(BuildContext context, FsFile file) {
    final colors = context.colors;
    final outerPadding = widget.dense
        ? const EdgeInsets.fromLTRB(10, 8, 10, 12)
        : const EdgeInsets.fromLTRB(12, 10, 12, 24);

    if (supportsImagePreview && _imagePreview) {
      final mimeLabel = _displayMimeLabel(
        file.path,
        file.mimeHint,
        fallback: 'image',
      );
      return Padding(
        padding: outerPadding,
        child: ImageViewerPane(
          source: ImageViewerSource.loader(
            title: baseName(widget.path),
            subtitle: '${formatBytes(file.size)} • $mimeLabel',
            imageProviderLoader: () async {
              final cached = await ImageBlobCacheStore.instance.load(
                host: widget.host,
                path: widget.path,
                api: widget.api,
              );
              return FileImage(cached);
            },
          ),
          dense: widget.dense,
        ),
      );
    }
    if (supportsVideoPreview && _videoPreview) {
      final mimeLabel = _displayMimeLabel(
        file.path,
        file.mimeHint,
        fallback: 'video',
      );
      return Padding(
        padding: outerPadding,
        child: VideoViewerPane(
          host: widget.host,
          api: widget.api,
          path: widget.path,
          mimeHint: mimeLabel,
          agentProvider: widget.agentProvider,
          sessionId: widget.sessionId,
          dense: widget.dense,
        ),
      );
    }
    if (file.binary) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: MeshEmptyState(
          icon: isImageFile
              ? Icons.image_rounded
              : isVideoFile
              ? Icons.play_circle_outline_rounded
              : Icons.description_rounded,
          title: isImageFile
              ? 'Image file'
              : isVideoFile
              ? 'Video file'
              : 'Preview unavailable',
          body: isImageFile
              ? '${formatBytes(file.size)} • Use Show image to open it.'
              : isVideoFile
              ? '${formatBytes(file.size)} • Use Play video to open it.'
              : '${formatBytes(file.size)} • ${_displayMimeLabel(file.path, file.mimeHint, fallback: 'unknown type')}',
        ),
      );
    }
    if (_editing) {
      return Padding(
        padding: outerPadding,
        child: Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: TextField(
            controller: _editController,
            maxLines: null,
            expands: true,
            style: monoStyle(color: colors.textPrimary, fontSize: 13),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: outerPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (file.truncated)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MeshCard(
                tone: MeshCardTone.surface,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: colors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Showing the first 2 MiB of this ${formatBytes(file.size)} file.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (supportsMarkdownPreview && _markdownPreview)
            Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.border),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: MarkdownContent(
                text: file.contents,
                textColor: colors.textPrimary,
              ),
            )
          else
            SelectionArea(
              child: SyntaxCodeBlock(
                text: file.contents,
                language: languageForPath(file.path),
                showLanguageBadge: false,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shared action row used both on the mobile viewer app bar and the desktop
/// dialog header.
class FileViewerActions extends StatelessWidget {
  const FileViewerActions({super.key, required this.state});

  final FileViewerPaneState? state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final editing = s?.editing ?? false;
    final saving = s?.saving ?? false;
    final hasFile = s?.file != null;
    final canUseTextContents = hasFile && !(s?.file?.binary ?? false);
    final canPreviewMarkdown = s?.isMarkdownFile ?? false;
    final canPreviewImage = s?.isImageFile ?? false;
    final canPreviewVideo = s?.isVideoFile ?? false;
    final markdownPreview = s?.markdownPreview ?? false;
    final imagePreview = s?.imagePreview ?? false;
    final videoPreview = s?.videoPreview ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (editing)
          IconButton(
            tooltip: 'Save',
            onPressed: saving ? null : s?.saveAction,
            icon: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded, size: 20),
          ),
        IconButton(
          tooltip: editing ? 'Done editing' : 'Edit',
          onPressed: canUseTextContents ? () => s?.toggleEdit() : null,
          icon: Icon(
            editing ? Icons.visibility_rounded : Icons.edit_rounded,
            size: 18,
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          onPressed: canUseTextContents ? () => s?.copyContents() : null,
          icon: const Icon(Icons.content_copy_rounded, size: 18),
        ),
        if (canPreviewMarkdown)
          IconButton(
            tooltip: markdownPreview ? 'View file' : 'Preview markdown',
            onPressed: hasFile && !editing
                ? () => s?.toggleMarkdownPreview()
                : null,
            icon: Icon(
              markdownPreview ? Icons.code_rounded : Icons.article_rounded,
              size: 18,
            ),
          ),
        if (canPreviewImage)
          IconButton(
            tooltip: imagePreview ? 'View file' : 'Show image',
            onPressed: hasFile && !editing
                ? () => s?.toggleImagePreview()
                : null,
            icon: Icon(
              imagePreview ? Icons.description_rounded : Icons.image_rounded,
              size: 18,
            ),
          ),
        if (canPreviewVideo)
          IconButton(
            tooltip: videoPreview ? 'View file' : 'Play video',
            onPressed: hasFile && !editing
                ? () => s?.toggleVideoPreview()
                : null,
            icon: Icon(
              videoPreview
                  ? Icons.description_rounded
                  : Icons.play_circle_outline_rounded,
              size: 18,
            ),
          ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: hasFile ? () => s?.refresh() : null,
          icon: const Icon(Icons.refresh_rounded, size: 18),
        ),
      ],
    );
  }
}

class _FileViewerLoadingState extends StatelessWidget {
  const _FileViewerLoadingState({required this.dense});

  final bool dense;

  @override
  Widget build(BuildContext context) {
    final outerPadding = dense
        ? const EdgeInsets.fromLTRB(10, 8, 10, 12)
        : const EdgeInsets.fromLTRB(12, 10, 12, 24);
    return SingleChildScrollView(
      padding: outerPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(
            children: [
              MeshSkeleton(width: 68, height: 20, radius: 999),
              SizedBox(width: 8),
              MeshSkeleton(width: 54, height: 20, radius: 999),
            ],
          ),
          SizedBox(height: 12),
          MeshCard(
            tone: MeshCardTone.muted,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                  widthFactor: 0.24,
                  alignment: Alignment.centerLeft,
                  child: MeshSkeleton(height: 14, radius: AppRadii.badge),
                ),
                SizedBox(height: 14),
                MeshSkeleton(height: 14, radius: AppRadii.badge),
                SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.92,
                  alignment: Alignment.centerLeft,
                  child: MeshSkeleton(height: 14, radius: AppRadii.badge),
                ),
                SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.78,
                  alignment: Alignment.centerLeft,
                  child: MeshSkeleton(height: 14, radius: AppRadii.badge),
                ),
                SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.86,
                  alignment: Alignment.centerLeft,
                  child: MeshSkeleton(height: 14, radius: AppRadii.badge),
                ),
                SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.58,
                  alignment: Alignment.centerLeft,
                  child: MeshSkeleton(height: 14, radius: AppRadii.badge),
                ),
                SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.72,
                  alignment: Alignment.centerLeft,
                  child: MeshSkeleton(height: 14, radius: AppRadii.badge),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String baseName(String path) {
  final trimmed = path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final idx = trimmed.lastIndexOf('/');
  return idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}

String _displayMimeLabel(
  String path,
  String? mimeHint, {
  required String fallback,
}) {
  final mime = (mimeHint ?? '').trim().toLowerCase();
  if (mime.isNotEmpty && mime != 'application/octet-stream') {
    return mime;
  }
  return _guessMimeLabelFromPath(path) ?? fallback;
}

String? _guessMimeLabelFromPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.ico')) return 'image/x-icon';
  if (lower.endsWith('.heic')) return 'image/heic';
  if (lower.endsWith('.heif')) return 'image/heif';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.m4v')) return 'video/x-m4v';
  if (lower.endsWith('.mkv')) return 'video/x-matroska';
  if (lower.endsWith('.avi')) return 'video/x-msvideo';
  if (lower.endsWith('.ogv')) return 'video/ogg';
  if (lower.endsWith('.m3u8')) return 'application/vnd.apple.mpegurl';
  if (lower.endsWith('.md')) return 'text/markdown';
  if (lower.endsWith('.json')) return 'application/json';
  if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return 'text/yaml';
  if (lower.endsWith('.xml')) return 'application/xml';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.zip')) return 'application/zip';
  return null;
}

bool _looksLikeImageFile(String path, String? mimeHint) {
  final mime = (mimeHint ?? '').toLowerCase();
  if (mime == 'image/png' ||
      mime == 'image/jpeg' ||
      mime == 'image/gif' ||
      mime == 'image/webp' ||
      mime == 'image/bmp' ||
      mime == 'image/x-icon' ||
      mime == 'image/vnd.microsoft.icon' ||
      mime == 'image/heic' ||
      mime == 'image/heif') {
    return true;
  }
  final lower = path.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp') ||
      lower.endsWith('.ico') ||
      lower.endsWith('.heic') ||
      lower.endsWith('.heif');
}

bool _looksLikeVideoFile(String path, String? mimeHint) {
  final mime = (mimeHint ?? '').toLowerCase();
  if (mime == 'video/mp4' ||
      mime == 'video/webm' ||
      mime == 'video/quicktime' ||
      mime == 'video/x-matroska' ||
      mime == 'video/x-msvideo' ||
      mime == 'video/ogg' ||
      mime == 'application/vnd.apple.mpegurl' ||
      mime == 'application/x-mpegurl') {
    return true;
  }
  final lower = path.toLowerCase();
  return lower.endsWith('.mp4') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.m4v') ||
      lower.endsWith('.mkv') ||
      lower.endsWith('.avi') ||
      lower.endsWith('.ogv') ||
      lower.endsWith('.m3u8');
}
