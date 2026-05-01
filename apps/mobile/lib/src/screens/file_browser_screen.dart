import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../fs_models.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../workspace_live_store.dart';
import 'file_viewer_pane.dart';
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
    return ListView(
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
      appBar: AppBar(
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
              baseName(root),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              root,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textTertiary, fontSize: 11),
            ),
          ],
        ),
      ),
      body: FileBrowserTree(
        host: host,
        api: api,
        root: root,
        agentProvider: agentProvider,
        sessionId: sessionId,
      ),
    );
    if (topPadding == null) return scaffold;
    return Padding(
      padding: EdgeInsets.only(top: topPadding!),
      child: scaffold,
    );
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
              friendlyError(_error!),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.danger),
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
              );
            }
            return _Row(
              indent: indent + 14.0,
              icon: Icons.description_rounded,
              iconColor: colors.textSecondary,
              title: entry.name,
              modified: widget.changedPaths.contains(entry.path),
              selected: widget.selectedPath == entry.path,
              onTap: () {
                widget.onEntryChanged(entry.path);
                widget.onOpenFile(entry.path);
              },
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
  });

  final double indent;
  final IconData icon;
  final Color iconColor;
  final String title;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool modified;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: selected ? colors.accentMuted : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.fromLTRB(indent + 8, 6, 8, 6),
          child: Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
