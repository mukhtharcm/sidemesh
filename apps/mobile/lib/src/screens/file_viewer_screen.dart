import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../fs_languages.dart';
import '../fs_models.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/syntax_code_block.dart';

/// Read-only / edit-in-place viewer for a single workspace file.
class FileViewerScreen extends StatefulWidget {
  const FileViewerScreen({
    super.key,
    required this.host,
    required this.api,
    required this.path,
    this.topPadding,
    this.liveStream,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final double? topPadding;

  /// Optional stream of fs change events the caller is already subscribed
  /// to. When provided, the viewer auto-refreshes on matching events.
  final Stream<FsChangeEvent>? liveStream;

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  FsFile? _file;
  Object? _error;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  late final TextEditingController _editController = TextEditingController();
  StreamSubscription<FsChangeEvent>? _liveSub;

  @override
  void initState() {
    super.initState();
    _load();
    final stream = widget.liveStream;
    if (stream != null) {
      _liveSub = stream.listen((event) {
        if (!mounted) return;
        final matches = event.changedPaths.contains(widget.path) ||
            event.path == widget.path;
        if (matches && !_editing) {
          _load(silent: true);
        }
      });
    }
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    _editController.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final file = await widget.api.readFile(widget.host, widget.path);
      if (!mounted) return;
      setState(() {
        _file = file;
        _loading = false;
        _error = null;
        if (!_editing) {
          _editController.text = file.contents;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
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
    try {
      await widget.api.writeFile(
        widget.host,
        path: widget.path,
        contents: _editController.text,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
      });
      showAppSnackBar(context, 'Saved ${_baseName(widget.path)}');
      await _load(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppSnackBar(context, 'Save failed: ${friendlyError(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final topPadding = widget.topPadding;

    Widget body;
    if (_loading && _file == null) {
      body = const Center(child: MeshLoader());
    } else if (_error != null && _file == null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: MeshEmptyState(
          icon: Icons.error_outline_rounded,
          title: "Couldn't open file",
          body: friendlyError(_error!),
        ),
      );
    } else if (_file != null) {
      body = _buildBody(context, _file!);
    } else {
      body = const SizedBox.shrink();
    }

    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      appBar: _FileAppBar(
        host: widget.host,
        path: widget.path,
        file: _file,
        editing: _editing,
        saving: _saving,
        onRefresh: () => _load(),
        onToggleEdit: () {
          if (_file == null) return;
          setState(() {
            _editing = !_editing;
            if (_editing) {
              _editController.text = _file!.contents;
            }
          });
        },
        onSave: _editing ? _save : null,
        onCopy: _file == null
            ? null
            : () async {
                await Clipboard.setData(
                  ClipboardData(text: _file!.contents),
                );
                if (!context.mounted) return;
                showAppSnackBar(context, 'Copied');
              },
      ),
      body: body,
    );
    if (topPadding == null) return scaffold;
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: scaffold,
    );
  }

  Widget _buildBody(BuildContext context, FsFile file) {
    final colors = context.colors;
    if (file.binary) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: MeshEmptyState(
          icon: Icons.description_outlined,
          title: 'Binary file',
          body:
              '${_formatBytes(file.size)} • ${file.mimeHint.isEmpty ? 'unknown type' : file.mimeHint}',
        ),
      );
    }
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
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
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (file.truncated)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MeshCard(
                tone: MeshCardTone.surface,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: colors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Preview truncated at 2 MiB — file is '
                        '${_formatBytes(file.size)}.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
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

class _FileAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _FileAppBar({
    required this.host,
    required this.path,
    required this.file,
    required this.editing,
    required this.saving,
    required this.onRefresh,
    required this.onToggleEdit,
    required this.onCopy,
    required this.onSave,
  });

  final HostProfile host;
  final String path;
  final FsFile? file;
  final bool editing;
  final bool saving;
  final VoidCallback onRefresh;
  final VoidCallback onToggleEdit;
  final VoidCallback? onCopy;
  final VoidCallback? onSave;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final languageId = languageForPath(path);
    return AppBar(
      backgroundColor: colors.surface,
      foregroundColor: colors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: colors.border)),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _baseName(path),
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
              if (file != null)
                Flexible(
                  child: Text(
                    '${_formatBytes(file!.size)} • ${host.label}',
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
      actions: [
        if (editing)
          IconButton(
            tooltip: 'Save',
            onPressed: saving ? null : onSave,
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
          onPressed: onToggleEdit,
          icon: Icon(
            editing ? Icons.visibility_rounded : Icons.edit_rounded,
            size: 18,
          ),
        ),
        IconButton(
          tooltip: 'Copy contents',
          onPressed: onCopy,
          icon: const Icon(Icons.content_copy_rounded, size: 18),
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded, size: 18),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

String _baseName(String path) {
  final idx = path.lastIndexOf('/');
  return idx >= 0 ? path.substring(idx + 1) : path;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
