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
import '../widgets/app_snackbar.dart';
import '../widgets/markdown_content.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/syntax_code_block.dart';
import 'image_viewer_screen.dart';

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
        _imagePreview = !_editing &&
            _looksLikeImageFile(file.path, file.mimeHint);
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final colors = context.colors;
        return AlertDialog(
          title: const Text('Save file?'),
          content: Text(
            widget.path,
            style: monoStyle(color: colors.textSecondary, fontSize: 12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
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
      showAppSnackBar(context, 'Saved ${baseName(widget.path)}');
      await _load(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _bump();
      showAppSnackBar(context, 'Save failed: ${friendlyError(error)}');
    }
  }

  void toggleEdit() {
    if (_file == null) return;
    setState(() {
      _editing = !_editing;
      if (_editing) {
        _markdownPreview = false;
        _imagePreview = false;
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
  bool get supportsMarkdownPreview =>
      !_editing && _file != null && isMarkdownFile;
  bool get supportsImagePreview => !_editing && _file != null && isImageFile;
  bool get markdownPreview => _markdownPreview;
  bool get imagePreview => _imagePreview;

  @override
  Widget build(BuildContext context) {
    if (_loading && _file == null) {
      return const Center(child: MeshLoader());
    }
    if (_error != null && _file == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: MeshEmptyState(
          icon: Icons.error_outline_rounded,
          title: "Couldn't open file",
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
      return Padding(
        padding: outerPadding,
        child: ImageViewerPane(
          source: ImageViewerSource.loader(
            title: baseName(widget.path),
            subtitle:
                '${formatBytes(file.size)} • ${file.mimeHint.isEmpty ? 'image' : file.mimeHint}',
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
    if (file.binary) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: MeshEmptyState(
          icon: isImageFile ? Icons.image_rounded : Icons.description_rounded,
          title: isImageFile ? 'Image file' : 'Binary file',
          body:
              '${formatBytes(file.size)} • ${file.mimeHint.isEmpty ? 'unknown type' : file.mimeHint}',
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
                        'Preview truncated at 2 MiB — file is '
                        '${formatBytes(file.size)}.',
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
    final markdownPreview = s?.markdownPreview ?? false;
    final imagePreview = s?.imagePreview ?? false;
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
          tooltip: editing ? 'Stop editing' : 'Edit',
          onPressed: canUseTextContents ? () => s?.toggleEdit() : null,
          icon: Icon(
            editing ? Icons.visibility_rounded : Icons.edit_rounded,
            size: 18,
          ),
        ),
        IconButton(
          tooltip: 'Copy contents',
          onPressed: canUseTextContents ? () => s?.copyContents() : null,
          icon: const Icon(Icons.content_copy_rounded, size: 18),
        ),
        if (canPreviewMarkdown)
          IconButton(
            tooltip: markdownPreview ? 'View source' : 'Preview markdown',
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
            tooltip: imagePreview ? 'Hide image preview' : 'Preview image',
            onPressed: hasFile && !editing ? () => s?.toggleImagePreview() : null,
            icon: Icon(
              imagePreview ? Icons.description_rounded : Icons.image_rounded,
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
