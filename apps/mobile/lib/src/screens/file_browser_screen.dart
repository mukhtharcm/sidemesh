import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../fs_models.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/mesh_breadcrumb.dart';
import '../widgets/mesh_status_line.dart';
import '../workspace_live_store.dart';
import 'file_viewer_screen.dart';

/// Embeddable workspace browser tree. Manages its own live subscription,
/// changed-path badges, and expansion state. Use [FileBrowserScreen] for
/// the mobile-route variant.
class FileBrowserTree extends StatefulWidget {
  const FileBrowserTree({
    super.key,
    required this.host,
    required this.api,
    required this.root,
    this.agentProvider,
    this.sessionId,
    this.onOpenFile,
    this.selectedPath,
  });

  final HostProfile host;
  final ApiClient api;
  final String root;
  final String? agentProvider;
  final String? sessionId;

  /// Called when the user taps a file. When null, the tree defaults to
  /// pushing a [FileViewerScreen] route.
  final void Function(String path, Stream<FsChangeEvent>? liveStream)?
  onOpenFile;

  /// Highlights the given path as selected (for split-pane layouts).
  final String? selectedPath;

  @override
  State<FileBrowserTree> createState() => _FileBrowserTreeState();
}

class _FileBrowserTreeState extends State<FileBrowserTree> {
  WorkspaceLiveHandle? _live;
  final _changed = <String>{};
  StreamSubscription<FsChangeEvent>? _sub;

  bool _selectionMode = false;
  final Set<String> _selectedPaths = {};

  void _enterSelection(String path) {
    setState(() {
      _selectionMode = true;
      _selectedPaths.add(path);
    });
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
        if (_selectedPaths.isEmpty) _selectionMode = false;
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  @override
  void initState() {
    super.initState();
    _live = WorkspaceLiveStore.instance.subscribe(
      widget.host,
      widget.api,
      agentProvider: widget.agentProvider,
      sessionId: widget.sessionId,
    );
    _sub = _live!.stream.listen((event) {
      if (!mounted) return;
      setState(() {
        for (final p in event.changedPaths) {
          _changed.add(p);
        }
      });
    });
    _live!.watch(widget.root).catchError((_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    final handle = _live;
    if (handle != null) {
      handle.unwatch(widget.root).catchError((_) {});
      WorkspaceLiveStore.instance.release(handle);
    }
    super.dispose();
  }

  void _open(String path) {
    _changed.remove(path);
    final onOpen = widget.onOpenFile;
    if (onOpen != null) {
      onOpen(path, _live?.stream);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileViewerScreen(
          host: widget.host,
          api: widget.api,
          path: path,
          agentProvider: widget.agentProvider,
          sessionId: widget.sessionId,
          liveStream: _live?.stream,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 24),
            children: [
              _DirectoryNode(
                host: widget.host,
                api: widget.api,
                path: widget.root,
                agentProvider: widget.agentProvider,
                sessionId: widget.sessionId,
                depth: 0,
                initiallyExpanded: true,
                changedPaths: _changed,
                selectedPath: widget.selectedPath,
                onOpenFile: _open,
                onEntryChanged: (p) => setState(() => _changed.remove(p)),
                selectionMode: _selectionMode,
                selectedPaths: _selectedPaths,
                onLongPressFile: _enterSelection,
                onTapFileInSelection: _toggleSelection,
              ),
            ],
          ),
        ),
        if (_selectionMode)
          _SelectionBar(
            selectedCount: _selectedPaths.length,
            selectedPaths: _selectedPaths,
            onCopyPaths: () {
              final text = _selectedPaths.join('\n');
              Clipboard.setData(ClipboardData(text: text));
              _exitSelection();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Paths copied')),
              );
            },
            onCancel: _exitSelection,
          ),
      ],
    );
  }
}

/// Mobile-friendly full-screen file browser. Wraps [FileBrowserTree] in a
/// Scaffold + AppBar.
class FileBrowserScreen extends StatelessWidget {
  const FileBrowserScreen({
    super.key,
    required this.host,
    required this.api,
    required this.root,
    this.agentProvider,
    this.sessionId,
    this.topPadding,
  });

  final HostProfile host;
  final ApiClient api;
  final String root;
  final String? agentProvider;
  final String? sessionId;
  final double? topPadding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MeshStatusLine(
                  segments: [
                    MeshStatusSegment(host.label, mono: true),
                    MeshStatusSegment('Files'),
                  ],
                ),
                Container(
                  height: 36,
                  color: colors.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: 4,
                  ),
                  child: MeshBreadcrumb(
                    segments: _buildBreadcrumbs(root),
                  ),
                ),
                Divider(height: 1, color: colors.border),
              ],
            ),
          ),
          Expanded(
            child: FileBrowserTree(
              host: host,
              api: api,
              root: root,
              agentProvider: agentProvider,
              sessionId: sessionId,
            ),
          ),
        ],
      ),
    );
    if (topPadding == null) return scaffold;
    return Padding(
      padding: EdgeInsets.only(top: topPadding!),
      child: scaffold,
    );
  }

  List<MeshBreadcrumbSegment> _buildBreadcrumbs(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return [MeshBreadcrumbSegment(label: '/')];
    final segments = <MeshBreadcrumbSegment>[];
    for (var i = 0; i < parts.length; i++) {
      segments.add(MeshBreadcrumbSegment(label: parts[i]));
    }
    return segments;
  }
}

class _DirectoryNode extends StatefulWidget {
  const _DirectoryNode({
    required this.host,
    required this.api,
    required this.path,
    required this.agentProvider,
    required this.sessionId,
    required this.depth,
    required this.onOpenFile,
    required this.changedPaths,
    required this.onEntryChanged,
    this.initiallyExpanded = false,
    this.selectedPath,
    this.selectionMode = false,
    this.selectedPaths,
    this.onLongPressFile,
    this.onTapFileInSelection,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String? agentProvider;
  final String? sessionId;
  final int depth;
  final bool initiallyExpanded;
  final Set<String> changedPaths;
  final String? selectedPath;
  final void Function(String path) onOpenFile;
  final void Function(String path) onEntryChanged;
  final bool selectionMode;
  final Set<String>? selectedPaths;
  final void Function(String path)? onLongPressFile;
  final void Function(String path)? onTapFileInSelection;

  @override
  State<_DirectoryNode> createState() => _DirectoryNodeState();
}

class _DirectoryNodeState extends State<_DirectoryNode> {
  late bool _expanded = widget.initiallyExpanded;
  bool _loading = false;
  Object? _error;
  FsListing? _listing;

  @override
  void initState() {
    super.initState();
    if (_expanded) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.api.listDirectory(
        widget.host,
        widget.path,
        agentProvider: widget.agentProvider,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final indent = widget.depth * 14.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(
          indent: indent,
          icon: _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
          iconColor: colors.accent,
          title: _baseName(widget.path),
          modified: widget.changedPaths.any((p) => p.startsWith(widget.path)),
          trailing: _loading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 18,
                  color: colors.textTertiary,
                ),
          onTap: () {
            setState(() => _expanded = !_expanded);
            if (_expanded && _listing == null) _load();
          },
        ),
        if (_expanded && _error != null)
          Padding(
            padding: EdgeInsets.fromLTRB(indent + 22, 4, 8, 8),
            child: Text(
              'Could not load: ${friendlyError(_error!)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ),
        if (_expanded && _listing != null && _listing!.entries.isEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(indent + 22, 8, 8, 8),
            child: Text(
              'No files here.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
            ),
          ),
        if (_expanded && _listing != null)
          ..._listing!.entries.map((entry) {
            if (entry.isDirectory) {
              return _DirectoryNode(
                host: widget.host,
                api: widget.api,
                path: entry.path,
                agentProvider: widget.agentProvider,
                sessionId: widget.sessionId,
                depth: widget.depth + 1,
                changedPaths: widget.changedPaths,
                selectedPath: widget.selectedPath,
                onOpenFile: widget.onOpenFile,
                onEntryChanged: widget.onEntryChanged,
                selectionMode: widget.selectionMode,
                selectedPaths: widget.selectedPaths,
                onLongPressFile: widget.onLongPressFile,
                onTapFileInSelection: widget.onTapFileInSelection,
              );
            }
            return _Row(
              indent: indent + 14.0,
              icon: Icons.description_rounded,
              iconColor: colors.textSecondary,
              title: entry.name,
              modified: widget.changedPaths.contains(entry.path),
              selected: widget.selectionMode
                  ? (widget.selectedPaths?.contains(entry.path) ?? false)
                  : widget.selectedPath == entry.path,
              selectionMode: widget.selectionMode,
              onTap: widget.selectionMode
                  ? () => widget.onTapFileInSelection?.call(entry.path)
                  : () {
                      widget.onEntryChanged(entry.path);
                      widget.onOpenFile(entry.path);
                    },
              onLongPress: widget.selectionMode
                  ? null
                  : () => widget.onLongPressFile?.call(entry.path),
            );
          }),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.indent,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.onTap,
    this.trailing,
    this.modified = false,
    this.selected = false,
    this.selectionMode = false,
    this.onLongPress,
  });

  final double indent;
  final IconData icon;
  final Color iconColor;
  final String title;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool modified;
  final bool selected;
  final bool selectionMode;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
      ),
      child: Material(
        color: selected && !selectionMode
            ? colors.accentMuted
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.fromLTRB(indent + 8, 6, 8, 6),
            child: Row(
              children: [
                if (selectionMode)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: selected,
                      onChanged: (_) => onTap(),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                else
                  Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: selected && !selectionMode
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
                if (modified) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
                if (trailing != null) ...[const SizedBox(width: 6), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _baseName(String path) {
  final trimmed = path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final idx = trimmed.lastIndexOf('/');
  return idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selectedCount,
    required this.selectedPaths,
    required this.onCopyPaths,
    required this.onCancel,
  });

  final int selectedCount;
  final Set<String> selectedPaths;
  final VoidCallback onCopyPaths;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Text(
              '$selectedCount selected',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: AppWeights.emphasis,
                color: colors.textPrimary,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: onCopyPaths,
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy path'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onCancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
