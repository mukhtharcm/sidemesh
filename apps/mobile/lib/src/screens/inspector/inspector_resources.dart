import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api_client.dart';
import '../../image_blob_cache_store.dart';
import '../../models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/mesh_widgets.dart';
import '../image_viewer_screen.dart';
import 'inspector_controller.dart';
import '../../app_icons.dart';

InspectorSurface buildInspectorResourcesSurface({
  required String ownerKey,
  required HostProfile host,
  required SessionSummary session,
  required ApiClient api,
  void Function(String path)? onOpenFile,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.resources,
    ownerKey: ownerKey,
    title: 'Resources',
    icon: AppIcons.perm_media_rounded,
    bodyBuilder: (context) => SessionResourcesPanel(
      host: host,
      session: session,
      api: api,
      onOpenFile: onOpenFile,
    ),
  );
}

class SessionResourcesPanel extends StatefulWidget {
  const SessionResourcesPanel({
    super.key,
    required this.host,
    required this.session,
    required this.api,
    this.onOpenFile,
    this.onClose,
    this.showDragHandle = false,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;
  final void Function(String path)? onOpenFile;
  final VoidCallback? onClose;
  final bool showDragHandle;

  @override
  State<SessionResourcesPanel> createState() => _SessionResourcesPanelState();
}

enum _ResourceFilter { all, media, links, files }

class _SessionResourcesPanelState extends State<SessionResourcesPanel> {
  List<SessionResource> _resources = const <SessionResource>[];
  bool _loading = true;
  Object? _error;
  _ResourceFilter _filter = _ResourceFilter.all;
  DateTime? _updatedAt;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant SessionResourcesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.id != widget.host.id ||
        oldWidget.host.baseUrl != widget.host.baseUrl ||
        oldWidget.host.token != widget.host.token ||
        oldWidget.session.id != widget.session.id) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      _loading = true;
      _error = null;
    }

    try {
      final payload = await widget.api.fetchResources(
        widget.host,
        widget.session.id,
      );
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _resources = payload.resources;
        _updatedAt = payload.updatedAt;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<SessionResource> _filteredResources() {
    return _resources
        .where((resource) {
          switch (_filter) {
            case _ResourceFilter.all:
              return true;
            case _ResourceFilter.media:
              return resource.isImage;
            case _ResourceFilter.links:
              return resource.isLink;
            case _ResourceFilter.files:
              return resource.isFile || (resource.isImage && resource.hasPath);
          }
        })
        .toList(growable: false);
  }

  int _countFor(_ResourceFilter filter) {
    switch (filter) {
      case _ResourceFilter.all:
        return _resources.length;
      case _ResourceFilter.media:
        return _resources.where((item) => item.isImage).length;
      case _ResourceFilter.links:
        return _resources.where((item) => item.isLink).length;
      case _ResourceFilter.files:
        return _resources
            .where((item) => item.isFile || (item.isImage && item.hasPath))
            .length;
    }
  }

  List<SessionResource> get _mediaResources =>
      _resources.where((item) => item.isImage).toList(growable: false);

  Future<void> _openUrl(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      if (mounted) showAppSnackBar(context, 'Could not open link');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showAppSnackBar(context, 'Could not open link');
    }
  }

  void _openFile(String path) {
    widget.onClose?.call();
    widget.onOpenFile?.call(path);
  }

  void _openImageGallery(SessionResource resource) {
    final media = _mediaResources;
    if (media.isEmpty) {
      return;
    }
    final initialIndex = media.indexWhere((item) => item.id == resource.id);
    if (initialIndex < 0) {
      return;
    }
    showImageGalleryViewer(
      context,
      sources: media.map(_imageViewerSourceFor).toList(growable: false),
      initialIndex: initialIndex,
    );
  }

  ImageViewerSource _imageViewerSourceFor(SessionResource resource) {
    final path = resource.path;
    if ((path ?? '').isNotEmpty) {
      return ImageViewerSource.loader(
        heroTag: 'session-resource:${widget.host.id}:${resource.id}',
        title: resource.title,
        subtitle: _gallerySubtitle(resource),
        imageProviderLoader: () async {
          final file = await ImageBlobCacheStore.instance.load(
            host: widget.host,
            path: path!,
            api: widget.api,
          );
          return FileImage(file);
        },
      );
    }

    final url = resource.url ?? '';
    final provider = _imageProviderForUrl(url);
    if (provider != null) {
      return ImageViewerSource(
        imageProvider: provider,
        heroTag: 'session-resource:${widget.host.id}:${resource.id}',
        title: resource.title,
        subtitle: _gallerySubtitle(resource),
      );
    }

    return ImageViewerSource.loader(
      heroTag: 'session-resource:${widget.host.id}:${resource.id}',
      title: resource.title,
      subtitle: _gallerySubtitle(resource),
      imageProviderLoader: () async {
        throw StateError('Unsupported image source');
      },
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final colors = context.colors;
    final updatedAt = _updatedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_resources.length} items',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  updatedAt == null
                      ? widget.session.title
                      : 'Updated ${_formatTimestamp(updatedAt)}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          MeshIconButton(
            icon: AppIcons.refresh_rounded,
            tooltip: 'Refresh',
            color: colors.textSecondary,
            onTap: _load,
          ),
        ],
      ),
    );
  }

  Widget _buildFilters(BuildContext context) {
    final labels = <(_ResourceFilter, String)>[
      (_ResourceFilter.all, 'All'),
      (_ResourceFilter.media, 'Media'),
      (_ResourceFilter.links, 'Links'),
      (_ResourceFilter.files, 'Files'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: labels
            .map((entry) {
              final selected = entry.$1 == _filter;
              return ChoiceChip(
                label: Text('${entry.$2} ${_countFor(entry.$1)}'),
                selected: selected,
                onSelected: (_) => setState(() => _filter = entry.$1),
              );
            })
            .toList(growable: false),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final resources = _filteredResources();
    if (_loading && _resources.isEmpty) {
      return _ResourcesLoadingState(filter: _filter);
    }
    if (_error != null && _resources.isEmpty) {
      return _ResourcesEmptyState(
        icon: AppIcons.error_outline_rounded,
        title: 'Could not load items',
        detail: _error.toString(),
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    if (resources.isEmpty) {
      final detail = switch (_filter) {
        _ResourceFilter.all => 'Nothing from this session has been saved yet.',
        _ResourceFilter.media => 'No images yet.',
        _ResourceFilter.links => 'No links yet.',
        _ResourceFilter.files => 'No files yet.',
      };
      return _ResourcesEmptyState(
        icon: AppIcons.perm_media_rounded,
        title: 'Nothing saved yet',
        detail: detail,
      );
    }

    if (_filter == _ResourceFilter.media) {
      return RefreshIndicator(
        onRefresh: _load,
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.92,
          ),
          itemCount: resources.length,
          itemBuilder: (context, index) => _ResourceMediaCard(
            host: widget.host,
            api: widget.api,
            resource: resources[index],
            onTap: () => _openImageGallery(resources[index]),
          ),
        ),
      );
    }

    if (_filter == _ResourceFilter.all) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
          itemCount: resources.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final resource = resources[index];
            if (resource.isImage) {
              return SizedBox(
                height: 250,
                child: _ResourceMediaCard(
                  host: widget.host,
                  api: widget.api,
                  resource: resource,
                  onTap: () => _openImageGallery(resource),
                ),
              );
            }
            return _ResourceListCard(
              resource: resource,
              sessionCwd: widget.session.cwd,
              preferFileOpen: false,
              onOpenUrl: _openUrl,
              onOpenFile: _openFile,
            );
          },
        ),
      );
    }

    final preferFileOpen = _filter == _ResourceFilter.files;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
        itemCount: resources.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _ResourceListCard(
          resource: resources[index],
          sessionCwd: widget.session.cwd,
          preferFileOpen: preferFileOpen,
          onOpenUrl: _openUrl,
          onOpenFile: _openFile,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.canvas,
      shape: widget.showDragHandle
          ? const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showDragHandle)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          _buildToolbar(context),
          _buildFilters(context),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }
}

class _ResourceListCard extends StatelessWidget {
  const _ResourceListCard({
    required this.resource,
    required this.sessionCwd,
    required this.preferFileOpen,
    required this.onOpenUrl,
    required this.onOpenFile,
  });

  final SessionResource resource;
  final String sessionCwd;
  final bool preferFileOpen;
  final Future<void> Function(String raw) onOpenUrl;
  final void Function(String path) onOpenFile;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final path = resource.path;
    final href = resource.url;
    VoidCallback? onTap;
    if (preferFileOpen && (path?.isNotEmpty ?? false)) {
      onTap = () => onOpenFile(path!);
    } else if (resource.isLink && (href?.isNotEmpty ?? false)) {
      onTap = () => unawaited(onOpenUrl(href!));
    } else if (resource.isFile && (path?.isNotEmpty ?? false)) {
      onTap = () => onOpenFile(path!);
    }

    return MeshCard(
      tone: MeshCardTone.surface,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShapes.input,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: AppShapes.input,
                  border: Border.all(color: colors.border),
                ),
                alignment: Alignment.center,
                child: Icon(
                  _resourceIcon(resource, preferFileOpen: preferFileOpen),
                  size: 18,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resource.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: AppWeights.emphasis,
                        height: 1.3,
                      ),
                    ),
                    if ((resource.subtitle ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        resource.subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        MeshPill(
                          label: _sourceLabel(resource),
                          tone: MeshPillTone.info,
                          mono: true,
                        ),
                        MeshPill(
                          label: _formatTimestamp(resource.createdAt),
                          mono: true,
                        ),
                      ],
                    ),
                    if ((path ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _relativeSessionPath(path!, sessionCwd),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 10.5,
                        ),
                      ),
                    ] else if ((href ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        href!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResourcesLoadingState extends StatelessWidget {
  const _ResourcesLoadingState({required this.filter});

  final _ResourceFilter filter;

  @override
  Widget build(BuildContext context) {
    if (filter == _ResourceFilter.media) {
      return GridView.count(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.92,
        children: const [
          _ResourceMediaTileSkeleton(),
          _ResourceMediaTileSkeleton(),
          _ResourceMediaTileSkeleton(),
          _ResourceMediaTileSkeleton(),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
      children: [
        if (filter == _ResourceFilter.all) ...[
          const SizedBox(height: 250, child: _ResourceMediaTileSkeleton()),
          const SizedBox(height: 10),
        ],
        const MeshListRowSkeleton(
          titleWidthFactor: 0.52,
          subtitleWidthFactor: 0.76,
          showMeta: true,
        ),
        const SizedBox(height: 10),
        MeshListRowSkeleton(
          titleWidthFactor: 0.44,
          subtitleWidthFactor: 0.68,
          showMeta: filter == _ResourceFilter.files,
          showTrailing: filter != _ResourceFilter.links,
        ),
        const SizedBox(height: 10),
        const MeshListRowSkeleton(
          titleWidthFactor: 0.6,
          subtitleWidthFactor: 0.72,
          showMeta: true,
        ),
      ],
    );
  }
}

class _ResourceMediaTileSkeleton extends StatelessWidget {
  const _ResourceMediaTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return MeshCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Expanded(
            child: MeshSkeleton(
              width: double.infinity,
              height: double.infinity,
              radius: 16,
            ),
          ),
          SizedBox(height: 12),
          MeshSkeleton(height: 12),
          SizedBox(height: 8),
          FractionallySizedBox(
            widthFactor: 0.66,
            alignment: Alignment.centerLeft,
            child: MeshSkeleton(height: 10),
          ),
        ],
      ),
    );
  }
}

class _ResourceMediaCard extends StatelessWidget {
  const _ResourceMediaCard({
    required this.host,
    required this.api,
    required this.resource,
    this.onTap,
  });

  final HostProfile host;
  final ApiClient api;
  final SessionResource resource;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.surface,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShapes.input,
        child: ClipRRect(
          borderRadius: AppShapes.input,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _ResourceImagePreview(
                  host: host,
                  api: api,
                  resource: resource,
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(top: BorderSide(color: colors.border)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resource.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: AppWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _sourceLabel(resource),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(
                        color: colors.textTertiary,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResourceImagePreview extends StatelessWidget {
  const _ResourceImagePreview({
    required this.host,
    required this.api,
    required this.resource,
  });

  final HostProfile host;
  final ApiClient api;
  final SessionResource resource;

  @override
  Widget build(BuildContext context) {
    if ((resource.path ?? '').isNotEmpty) {
      return _LocalResourceImage(host: host, api: api, path: resource.path!);
    }
    return _RemoteResourceImage(url: resource.url ?? '');
  }
}

class _RemoteResourceImage extends StatefulWidget {
  const _RemoteResourceImage({required this.url});

  final String url;

  @override
  State<_RemoteResourceImage> createState() => _RemoteResourceImageState();
}

class _RemoteResourceImageState extends State<_RemoteResourceImage> {
  Uint8List? _dataUrlBytes;

  @override
  void initState() {
    super.initState();
    _decodeInlineDataUrl();
  }

  @override
  void didUpdateWidget(covariant _RemoteResourceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _decodeInlineDataUrl();
    }
  }

  void _decodeInlineDataUrl() {
    final bytes = _decodeImageDataUrl(widget.url);
    if (!mounted) {
      _dataUrlBytes = bytes;
      return;
    }
    setState(() => _dataUrlBytes = bytes);
  }

  ImageProvider<Object>? _provider() {
    if (_dataUrlBytes != null) {
      return MemoryImage(_dataUrlBytes!);
    }
    if (widget.url.startsWith('http://') || widget.url.startsWith('https://')) {
      return NetworkImage(widget.url);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final provider = _provider();
    if (provider == null) {
      return _MediaFallback(title: 'Image', detail: widget.url, colors: colors);
    }
    return _MediaPreview(provider: provider, fallbackLabel: widget.url);
  }
}

class _LocalResourceImage extends StatefulWidget {
  const _LocalResourceImage({
    required this.host,
    required this.api,
    required this.path,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;

  @override
  State<_LocalResourceImage> createState() => _LocalResourceImageState();
}

class _LocalResourceImageState extends State<_LocalResourceImage> {
  File? _file;
  Object? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _LocalResourceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.id != widget.host.id ||
        oldWidget.host.baseUrl != widget.host.baseUrl ||
        oldWidget.host.token != widget.host.token ||
        oldWidget.path != widget.path) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    setState(() {
      _file = null;
      _error = null;
    });
    try {
      final file = await ImageBlobCacheStore.instance.load(
        host: widget.host,
        path: widget.path,
        api: widget.api,
      );
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _file = file);
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final file = _file;
    if (file == null) {
      return _MediaFallback(
        title: _basename(widget.path),
        detail: _error == null ? 'Loading image...' : widget.path,
        colors: colors,
      );
    }
    return _MediaPreview(provider: FileImage(file), fallbackLabel: widget.path);
  }
}

class _MediaPreview extends StatelessWidget {
  const _MediaPreview({required this.provider, required this.fallbackLabel});

  final ImageProvider<Object> provider;
  final String fallbackLabel;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => _MediaFallback(
        title: 'Image',
        detail: fallbackLabel,
        colors: context.colors,
      ),
    );
  }
}

class _MediaFallback extends StatelessWidget {
  const _MediaFallback({
    required this.title,
    required this.detail,
    required this.colors,
  });

  final String title;
  final String detail;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surfaceMuted,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(AppIcons.image_rounded, color: colors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourcesEmptyState extends StatelessWidget {
  const _ResourcesEmptyState({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: colors.textTertiary),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: AppWeights.emphasis,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
                height: 1.45,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: onAction,
                icon: const Icon(AppIcons.refresh_rounded),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

IconData _resourceIcon(
  SessionResource resource, {
  required bool preferFileOpen,
}) {
  if (preferFileOpen && resource.hasPath) {
    return AppIcons.insert_drive_file_rounded;
  }
  if (resource.isImage) {
    return AppIcons.image_rounded;
  }
  if (resource.isLink) {
    return AppIcons.link_rounded;
  }
  return AppIcons.insert_drive_file_rounded;
}

String _sourceLabel(SessionResource resource) {
  final label = switch (resource.source) {
    'message_attachment' => 'attachment',
    'message_link' => 'link',
    'message_file' => 'file',
    'web_search' => 'web',
    'image_generation' => 'generated',
    _ => resource.source.replaceAll('_', ' '),
  };
  return _titleCaseWords(label);
}

String _gallerySubtitle(SessionResource resource) {
  final parts = <String>[
    _sourceLabel(resource),
    _formatTimestamp(resource.createdAt),
  ];
  final subtitle = resource.subtitle?.trim() ?? '';
  if (subtitle.isNotEmpty) {
    parts.add(subtitle);
  } else if ((resource.path ?? '').isNotEmpty) {
    parts.add(_basename(resource.path!));
  } else if ((resource.url ?? '').isNotEmpty) {
    parts.add(resource.url!);
  }
  return parts.join('  •  ');
}

String _relativeSessionPath(String path, String cwd) {
  if (cwd.isEmpty) return path;
  if (path == cwd) return '.';
  if (path.startsWith('$cwd/')) {
    return path.substring(cwd.length + 1);
  }
  return path;
}

String _formatTimestamp(DateTime time) {
  final now = DateTime.now();
  final local = time.toLocal();
  final sameDay =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (sameDay) {
    return '$hh:$mm';
  }
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$month/$day $hh:$mm';
}

String _titleCaseWords(String value) {
  final parts = value
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  return parts
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  if (slash < 0 || slash == normalized.length - 1) {
    return normalized;
  }
  return normalized.substring(slash + 1);
}

Uint8List? _decodeImageDataUrl(String raw) {
  if (!raw.startsWith('data:image/')) return null;
  final comma = raw.indexOf(',');
  if (comma <= 0 || comma >= raw.length - 1) return null;
  final metadata = raw.substring(0, comma).toLowerCase();
  final payload = raw.substring(comma + 1);
  if (!metadata.endsWith(';base64')) return null;
  try {
    return base64Decode(payload);
  } catch (_) {
    return null;
  }
}

ImageProvider<Object>? _imageProviderForUrl(String raw) {
  final bytes = _decodeImageDataUrl(raw);
  if (bytes != null) {
    return MemoryImage(bytes);
  }
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    return NetworkImage(raw);
  }
  return null;
}
