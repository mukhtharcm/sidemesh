import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../fs_languages.dart';
import '../fs_models.dart';
import '../image_blob_cache_store.dart';
import '../models.dart';
import '../resource_reference.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/markdown_content.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/syntax_code_block.dart';
import 'archive_preview_pane.dart';
import 'audio_viewer_pane.dart';
import 'image_viewer_screen.dart';
import 'pdf_viewer_pane.dart';
import 'structured_data_preview_pane.dart';
import 'tabular_file_preview.dart';
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
    this.pdfViewerBuilder,
    this.onOpenFile,
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
  final PdfViewerPanePreviewBuilder? pdfViewerBuilder;
  final void Function(String path)? onOpenFile;

  @override
  State<FileViewerPane> createState() => FileViewerPaneState();
}

class FileViewerPaneState extends State<FileViewerPane> {
  FsFile? _file;
  Object? _error;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _changedRemotely = false;
  bool _markdownPreview = false;
  bool _tablePreview = false;
  bool _structuredPreview = false;
  bool _imagePreview = false;
  bool _audioPreview = false;
  bool _videoPreview = false;
  bool _pdfPreview = false;
  bool _archivePreview = false;
  bool _autoEnterPreview = true;
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
      _autoEnterPreview = true;
      _clearPreviewModes();
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
      if (matches) {
        if (_editing) {
          setState(() => _changedRemotely = true);
          _bump();
        } else {
          _load(silent: true);
        }
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
        _applyPreviewStateForFile(
          file,
          autoEnterPreview: _autoEnterPreview && !_editing,
        );
        _autoEnterPreview = false;
        if (!_editing) {
          _editController.text = file.contents;
          _changedRemotely = false;
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
        expectedModifiedAtMs: file.modifiedAtMs,
        expectedSize: file.size,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
        _changedRemotely = false;
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
        _clearPreviewModes();
      }
      if (_editing) {
        _editController.text = _file!.contents;
        _changedRemotely = false;
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
        _clearPreviewModes();
        _markdownPreview = true;
      }
    });
    _bump();
  }

  void toggleTablePreview() {
    if (!supportsTablePreview) {
      return;
    }
    setState(() {
      _tablePreview = !_tablePreview;
      if (_tablePreview) {
        _clearPreviewModes();
        _tablePreview = true;
      }
    });
    _bump();
  }

  void toggleStructuredPreview() {
    if (!supportsStructuredPreview) {
      return;
    }
    setState(() {
      _structuredPreview = !_structuredPreview;
      if (_structuredPreview) {
        _clearPreviewModes();
        _structuredPreview = true;
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
        _clearPreviewModes();
        _imagePreview = true;
      }
    });
    _bump();
  }

  void toggleAudioPreview() {
    if (!supportsAudioPreview) {
      return;
    }
    setState(() {
      _audioPreview = !_audioPreview;
      if (_audioPreview) {
        _clearPreviewModes();
        _audioPreview = true;
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
        _clearPreviewModes();
        _videoPreview = true;
      }
    });
    _bump();
  }

  void togglePdfPreview() {
    if (!supportsPdfPreview) {
      return;
    }
    setState(() {
      _pdfPreview = !_pdfPreview;
      if (_pdfPreview) {
        _clearPreviewModes();
        _pdfPreview = true;
      }
    });
    _bump();
  }

  void toggleArchivePreview() {
    if (!supportsArchivePreview) {
      return;
    }
    setState(() {
      _archivePreview = !_archivePreview;
      if (_archivePreview) {
        _clearPreviewModes();
        _archivePreview = true;
      }
    });
    _bump();
  }

  void _clearPreviewModes() {
    _markdownPreview = false;
    _tablePreview = false;
    _structuredPreview = false;
    _imagePreview = false;
    _audioPreview = false;
    _videoPreview = false;
    _pdfPreview = false;
    _archivePreview = false;
  }

  void _applyPreviewStateForFile(
    FsFile file, {
    required bool autoEnterPreview,
  }) {
    final canPreviewTable =
        !file.binary &&
        delimitedTextFormatForFile(file.path, file.mimeHint) != null;
    final canPreviewStructured =
        !file.binary &&
        structuredDataFormatForFile(file.path, file.mimeHint) != null;
    final canPreviewImage = _looksLikeImageFile(file.path, file.mimeHint);
    final canPreviewAudio = _looksLikeAudioFile(file.path, file.mimeHint);
    final canPreviewVideo = _looksLikeVideoFile(file.path, file.mimeHint);
    final canPreviewPdf = _looksLikePdfFile(file.path, file.mimeHint);
    final canPreviewArchive = looksLikeZipArchiveFile(file.path, file.mimeHint);
    if (autoEnterPreview) {
      _clearPreviewModes();
      if (canPreviewImage) {
        _imagePreview = true;
      } else if (canPreviewAudio) {
        _audioPreview = true;
      } else if (canPreviewVideo) {
        _videoPreview = true;
      } else if (canPreviewPdf) {
        _pdfPreview = true;
      } else if (canPreviewArchive) {
        _archivePreview = true;
      } else if (canPreviewStructured) {
        _structuredPreview = true;
      } else if (canPreviewTable) {
        _tablePreview = true;
      }
      return;
    }
    _tablePreview = canPreviewTable && _tablePreview;
    _structuredPreview = canPreviewStructured && _structuredPreview;
    _imagePreview = canPreviewImage && _imagePreview;
    _audioPreview = canPreviewAudio && _audioPreview;
    _videoPreview = canPreviewVideo && _videoPreview;
    _pdfPreview = canPreviewPdf && _pdfPreview;
    _archivePreview = canPreviewArchive && _archivePreview;
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
  StructuredDataFormat? get structuredDataFormat =>
      structuredDataFormatForFile(_file?.path ?? widget.path, _file?.mimeHint);
  DelimitedTextFormat? get delimitedTextFormat =>
      delimitedTextFormatForFile(_file?.path ?? widget.path, _file?.mimeHint);
  VoidCallback? get saveAction => _editing ? _save : null;
  bool get isMarkdownFile => languageForPath(widget.path) == 'markdown';
  bool get isDelimitedTextFile => delimitedTextFormat != null;
  bool get isStructuredDataFile => structuredDataFormat != null;
  bool get isImageFile => _looksLikeImageFile(widget.path, _file?.mimeHint);
  bool get isAudioFile => _looksLikeAudioFile(widget.path, _file?.mimeHint);
  bool get isVideoFile => _looksLikeVideoFile(widget.path, _file?.mimeHint);
  bool get isPdfFile => _looksLikePdfFile(widget.path, _file?.mimeHint);
  bool get isZipArchiveFile =>
      looksLikeZipArchiveFile(widget.path, _file?.mimeHint);
  bool get supportsMarkdownPreview =>
      !_editing && _file != null && isMarkdownFile;
  bool get supportsTablePreview =>
      !_editing &&
      _file != null &&
      !(_file?.binary ?? true) &&
      isDelimitedTextFile;
  bool get supportsStructuredPreview =>
      !_editing &&
      _file != null &&
      !(_file?.binary ?? true) &&
      isStructuredDataFile;
  bool get supportsImagePreview => !_editing && _file != null && isImageFile;
  bool get supportsAudioPreview => !_editing && _file != null && isAudioFile;
  bool get supportsVideoPreview => !_editing && _file != null && isVideoFile;
  bool get supportsPdfPreview => !_editing && _file != null && isPdfFile;
  bool get supportsArchivePreview =>
      !_editing && (_file?.binary ?? false) && isZipArchiveFile;
  bool get markdownPreview => _markdownPreview;
  bool get tablePreview => _tablePreview;
  bool get structuredPreview => _structuredPreview;
  bool get imagePreview => _imagePreview;
  bool get audioPreview => _audioPreview;
  bool get videoPreview => _videoPreview;
  bool get pdfPreview => _pdfPreview;
  bool get archivePreview => _archivePreview;

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
              return ImageBlobCacheStore.instance.loadImageProvider(
                host: widget.host,
                path: file.path,
                api: widget.api,
                sessionId: widget.sessionId,
                versionHint: file.modifiedAtMs,
                sizeHint: file.size,
              );
            },
          ),
          dense: widget.dense,
        ),
      );
    }
    if (supportsAudioPreview && _audioPreview) {
      final mimeLabel = _displayMimeLabel(
        file.path,
        file.mimeHint,
        fallback: 'audio',
      );
      return Padding(
        padding: outerPadding,
        child: AudioViewerPane(
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
    if (supportsPdfPreview && _pdfPreview) {
      final mimeLabel = _displayMimeLabel(
        file.path,
        file.mimeHint,
        fallback: 'PDF',
      );
      return Padding(
        padding: outerPadding,
        child: PdfViewerPane(
          key: ValueKey('${widget.path}:${file.modifiedAtMs}:${file.size}'),
          host: widget.host,
          api: widget.api,
          path: widget.path,
          mimeHint: mimeLabel,
          agentProvider: widget.agentProvider,
          sessionId: widget.sessionId,
          dense: widget.dense,
          previewBuilder: widget.pdfViewerBuilder,
        ),
      );
    }
    if (supportsArchivePreview && _archivePreview) {
      return Padding(
        padding: outerPadding,
        child: ArchivePreviewPane(
          key: ValueKey(
            '${file.path}:${file.modifiedAtMs}:${file.size}:${widget.dense}',
          ),
          host: widget.host,
          api: widget.api,
          path: widget.path,
          fileSize: file.size,
          modifiedAtMs: file.modifiedAtMs,
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
              : isAudioFile
              ? Icons.audio_file_rounded
              : isVideoFile
              ? Icons.play_circle_outline_rounded
              : isPdfFile
              ? Icons.picture_as_pdf_rounded
              : isZipArchiveFile
              ? Icons.archive_outlined
              : Icons.description_rounded,
          title: isImageFile
              ? 'Image file'
              : isAudioFile
              ? 'Audio file'
              : isVideoFile
              ? 'Video file'
              : isPdfFile
              ? 'PDF document'
              : isZipArchiveFile
              ? 'ZIP archive'
              : 'Preview unavailable',
          body: isImageFile
              ? '${formatBytes(file.size)} • Use Show image to open it.'
              : isAudioFile
              ? '${formatBytes(file.size)} • Use Play audio to open it.'
              : isVideoFile
              ? '${formatBytes(file.size)} • Use Play video to open it.'
              : isPdfFile
              ? '${formatBytes(file.size)} • Use Preview PDF to open it.'
              : isZipArchiveFile
              ? '${formatBytes(file.size)} • Use Preview archive to list its contents.'
              : '${formatBytes(file.size)} • ${_displayMimeLabel(file.path, file.mimeHint, fallback: 'unknown type')}',
        ),
      );
    }
    if (_editing) {
      return Padding(
        padding: outerPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_changedRemotely) ...[
              MeshCard(
                tone: MeshCardTone.muted,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  'This file changed on the host. Reload it before saving to avoid overwriting newer work.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
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
            ),
          ],
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
                host: widget.host,
                api: widget.api,
                sessionId: widget.sessionId,
                basePath: hostPathDirectory(file.path),
                onOpenFile: widget.onOpenFile,
              ),
            )
          else if (supportsStructuredPreview &&
              _structuredPreview &&
              structuredDataFormat != null)
            StructuredDataPreviewPane(
              format: structuredDataFormat!,
              contents: file.contents,
              dense: widget.dense,
            )
          else if (supportsTablePreview &&
              _tablePreview &&
              delimitedTextFormat != null)
            TabularFilePreview(
              contents: file.contents,
              format: delimitedTextFormat!,
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
    final canPreviewTable =
        canUseTextContents && (s?.isDelimitedTextFile ?? false);
    final canPreviewStructured =
        canUseTextContents && (s?.isStructuredDataFile ?? false);
    final canPreviewImage = s?.isImageFile ?? false;
    final canPreviewAudio = s?.isAudioFile ?? false;
    final canPreviewVideo = s?.isVideoFile ?? false;
    final canPreviewPdf = s?.isPdfFile ?? false;
    final canPreviewArchive = s?.supportsArchivePreview ?? false;
    final markdownPreview = s?.markdownPreview ?? false;
    final tablePreview = s?.tablePreview ?? false;
    final structuredPreview = s?.structuredPreview ?? false;
    final imagePreview = s?.imagePreview ?? false;
    final audioPreview = s?.audioPreview ?? false;
    final videoPreview = s?.videoPreview ?? false;
    final pdfPreview = s?.pdfPreview ?? false;
    final archivePreview = s?.archivePreview ?? false;
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
        if (canPreviewTable)
          IconButton(
            tooltip: tablePreview ? 'View file' : 'Preview table',
            onPressed: hasFile && !editing
                ? () => s?.toggleTablePreview()
                : null,
            icon: Icon(
              tablePreview
                  ? Icons.description_rounded
                  : Icons.table_chart_rounded,
              size: 18,
            ),
          ),
        if (canPreviewStructured)
          IconButton(
            tooltip: structuredPreview ? 'View file' : 'Show structure',
            onPressed: hasFile && !editing
                ? () => s?.toggleStructuredPreview()
                : null,
            icon: Icon(
              structuredPreview
                  ? Icons.description_rounded
                  : Icons.account_tree_rounded,
              size: 18,
            ),
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
        if (canPreviewAudio)
          IconButton(
            tooltip: audioPreview ? 'View file' : 'Play audio',
            onPressed: hasFile && !editing
                ? () => s?.toggleAudioPreview()
                : null,
            icon: Icon(
              audioPreview
                  ? Icons.description_rounded
                  : Icons.graphic_eq_rounded,
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
        if (canPreviewPdf)
          IconButton(
            tooltip: pdfPreview ? 'View file' : 'Preview PDF',
            onPressed: hasFile && !editing ? () => s?.togglePdfPreview() : null,
            icon: Icon(
              pdfPreview
                  ? Icons.description_rounded
                  : Icons.picture_as_pdf_rounded,
              size: 18,
            ),
          ),
        if (canPreviewArchive)
          IconButton(
            tooltip: archivePreview ? 'View file' : 'Preview archive',
            onPressed: hasFile && !editing
                ? () => s?.toggleArchivePreview()
                : null,
            icon: Icon(
              archivePreview
                  ? Icons.description_rounded
                  : Icons.archive_outlined,
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
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
  if (lower.endsWith('.aac')) return 'audio/aac';
  if (lower.endsWith('.opus')) return 'audio/opus';
  if (lower.endsWith('.flac')) return 'audio/flac';
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

bool _looksLikeAudioFile(String path, String? mimeHint) {
  final mime = (mimeHint ?? '').toLowerCase();
  if (mime == 'audio/mpeg' ||
      mime == 'audio/mp3' ||
      mime == 'audio/wav' ||
      mime == 'audio/x-wav' ||
      mime == 'audio/wave' ||
      mime == 'audio/vnd.wave' ||
      mime == 'audio/mp4' ||
      mime == 'audio/aac' ||
      mime == 'audio/ogg' ||
      mime == 'audio/opus' ||
      mime == 'audio/flac' ||
      mime == 'audio/x-flac') {
    return true;
  }
  final lower = path.toLowerCase();
  return lower.endsWith('.mp3') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.ogg') ||
      lower.endsWith('.oga') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.opus') ||
      lower.endsWith('.flac');
}

bool _looksLikePdfFile(String path, String? mimeHint) {
  final mime = (mimeHint ?? '').toLowerCase();
  if (mime == 'application/pdf') {
    return true;
  }
  return path.toLowerCase().endsWith('.pdf');
}
