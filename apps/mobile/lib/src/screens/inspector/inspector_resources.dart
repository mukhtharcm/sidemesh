import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api_client.dart';
import '../../image_blob_cache_store.dart';
import '../../models.dart';
import '../../resource_reference.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/app_primitives.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/mesh_widgets.dart';
import '../image_viewer_screen.dart';
import 'inspector_controller.dart';
import '../../theme/app_status_styles.dart';

InspectorSurface buildInspectorResourcesSurface({
  required String ownerKey,
  required HostProfile host,
  required SessionSummary session,
  required ApiClient api,
  void Function(String path)? onOpenFile,
  void Function(String url)? onOpenHostUrl,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.resources,
    ownerKey: ownerKey,
    title: 'Resources',
    icon: Icons.perm_media_rounded,
    bodyBuilder: (context) => SessionResourcesPanel(
      host: host,
      session: session,
      api: api,
      onOpenFile: onOpenFile,
      onOpenHostUrl: onOpenHostUrl,
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
    this.onOpenHostUrl,
    this.onClose,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;
  final void Function(String path)? onOpenFile;
  final void Function(String url)? onOpenHostUrl;
  final VoidCallback? onClose;

  @override
  State<SessionResourcesPanel> createState() => _SessionResourcesPanelState();
}

enum _ResourceFilter { all, media, links, files }

class _SessionResourcesPanelState extends State<SessionResourcesPanel> {
  List<SessionResource> _resources = const <SessionResource>[];
  bool _loading = true;
  Object? _error;
  _ResourceFilter _filter = _ResourceFilter.all;
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
    if (isHostLoopbackUrl(raw) && widget.onOpenHostUrl != null) {
      widget.onClose?.call();
      widget.onOpenHostUrl!(raw);
      return;
    }
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
        title: _resourceTitle(resource),
        subtitle: _gallerySubtitle(resource),
        imageProviderLoader: () async {
          try {
            return await ImageBlobCacheStore.instance.loadImageProvider(
              host: widget.host,
              path: path!,
              api: widget.api,
              sessionId: widget.session.id,
            );
          } on ApiException catch (error) {
            if (error.statusCode != 403) rethrow;
            final artifact = await widget.api.publishSessionArtifact(
              widget.host,
              sessionId: widget.session.id,
              source: path!,
            );
            return MemoryImage(
              await widget.api.fetchSessionArtifact(widget.host, artifact.id),
            );
          }
        },
      );
    }

    final url = resource.url ?? '';
    if (isHostLoopbackUrl(url)) {
      return ImageViewerSource.loader(
        heroTag: 'session-resource:${widget.host.id}:${resource.id}',
        title: _resourceTitle(resource),
        subtitle: _gallerySubtitle(resource),
        imageProviderLoader: () async =>
            MemoryImage(await widget.api.fetchHostResource(widget.host, url)),
      );
    }
    final provider = _imageProviderForUrl(url);
    if (provider != null) {
      return ImageViewerSource(
        imageProvider: provider,
        heroTag: 'session-resource:${widget.host.id}:${resource.id}',
        title: _resourceTitle(resource),
        subtitle: _gallerySubtitle(resource),
      );
    }

    return ImageViewerSource.loader(
      heroTag: 'session-resource:${widget.host.id}:${resource.id}',
      title: _resourceTitle(resource),
      subtitle: _gallerySubtitle(resource),
      imageProviderLoader: () async {
        throw StateError('Unsupported image source');
      },
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final colors = context.colors;
    const labels = ['All', 'Media', 'Links', 'Files'];
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.compact),
      child: Row(
        children: [
          Expanded(
            child: AppSelect<_ResourceFilter>(
              value: _filter,
              values: _ResourceFilter.values,
              expanded: true,
              label: (filter) =>
                  '${labels[filter.index]} (${_countFor(filter)})',
              onChanged: (filter) => setState(() => _filter = filter),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh resources',
            color: colors.textSecondary,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final resources = _filteredResources();
    if (_loading && _resources.isEmpty) {
      return MeshLoader(label: 'Loading resources');
    }
    if (_error != null && _resources.isEmpty) {
      return MeshEmptyState.compact(
        icon: Icons.error_outline_rounded,
        title: 'Could not load items',
        body: _error.toString(),
        action: TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    if (resources.isEmpty) {
      return MeshEmptyState.compact(
        icon: Icons.perm_media_rounded,
        title: switch (_filter) {
          _ResourceFilter.all => 'No resources yet',
          _ResourceFilter.media => 'No images yet',
          _ResourceFilter.links => 'No links yet',
          _ResourceFilter.files => 'No files yet',
        },
      );
    }

    if (_filter == _ResourceFilter.media) {
      return RefreshIndicator(
        onRefresh: _load,
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.lg,
          ),
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
            sessionId: widget.session.id,
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
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          itemCount: resources.length,
          separatorBuilder: (context, index) {
            if (resources[index].isImage || resources[index + 1].isImage) {
              return const SizedBox(height: AppSpacing.md);
            }
            return Divider(
              height: 1,
              indent: AppSizes.iconWell + AppSpacing.sm,
              color: context.colors.border,
            );
          },
          itemBuilder: (context, index) {
            final resource = resources[index];
            if (resource.isImage) {
              return SizedBox(
                height: 250,
                child: _ResourceMediaCard(
                  host: widget.host,
                  api: widget.api,
                  sessionId: widget.session.id,
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
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        itemCount: resources.length,
        separatorBuilder: (context, _) => Divider(
          height: 1,
          indent: AppSizes.iconWell + AppSpacing.sm,
          color: context.colors.border,
        ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(context),
        Expanded(child: _buildBody(context)),
      ],
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

    final location = (path ?? '').isNotEmpty
        ? _relativeSessionPath(path!, sessionCwd)
        : href;
    return MeshListRow(
      onTap: onTap,
      framed: false,
      leading: AppIconWell(
        icon: _resourceIcon(resource, preferFileOpen: preferFileOpen),
      ),
      title: Text(resource.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: (resource.subtitle ?? '').trim().isEmpty
          ? null
          : Text(
              resource.subtitle!.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      badges: [
        MeshPill(
          label: _sourceLabel(resource),
          tone: MeshPillTone.info,
          mono: true,
        ),
        MeshPill(label: _formatTimestamp(resource.createdAt), mono: true),
      ],
      meta: location == null || location.isEmpty
          ? null
          : Text(
              location,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                color: colors.textTertiary,
                fontSize: AppFontSizes.metadata,
              ),
            ),
      trailing: onTap == null
          ? null
          : Icon(
              Icons.chevron_right_rounded,
              size: AppSizes.icon,
              color: colors.textTertiary,
            ),
    );
  }
}

class _ResourceMediaCard extends StatelessWidget {
  const _ResourceMediaCard({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.resource,
    this.onTap,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
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
                  sessionId: sessionId,
                  resource: resource,
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.compact,
                  AppSpacing.md,
                  AppSpacing.compact,
                ),
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(top: BorderSide(color: colors.border)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _resourceTitle(resource),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: AppWeights.emphasis,
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
    required this.sessionId,
    required this.resource,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final SessionResource resource;

  @override
  Widget build(BuildContext context) {
    if ((resource.path ?? '').isNotEmpty) {
      return _LocalResourceImage(
        host: host,
        api: api,
        sessionId: sessionId,
        path: resource.path!,
      );
    }
    return _RemoteResourceImage(host: host, api: api, url: resource.url ?? '');
  }
}

class _RemoteResourceImage extends StatefulWidget {
  const _RemoteResourceImage({
    required this.host,
    required this.api,
    required this.url,
  });

  final HostProfile host;
  final ApiClient api;
  final String url;

  @override
  State<_RemoteResourceImage> createState() => _RemoteResourceImageState();
}

class _RemoteResourceImageState extends State<_RemoteResourceImage> {
  Uint8List? _dataUrlBytes;
  Uint8List? _hostUrlBytes;
  Object? _hostUrlError;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _decodeInlineDataUrl();
    unawaited(_loadHostUrlIfNeeded());
  }

  @override
  void didUpdateWidget(covariant _RemoteResourceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.host.id != widget.host.id ||
        oldWidget.host.baseUrl != widget.host.baseUrl ||
        oldWidget.host.token != widget.host.token) {
      _decodeInlineDataUrl();
      unawaited(_loadHostUrlIfNeeded());
    }
  }

  Future<void> _loadHostUrlIfNeeded() async {
    final gen = ++_loadGeneration;
    if (!isHostLoopbackUrl(widget.url)) {
      if (mounted) {
        setState(() {
          _hostUrlBytes = null;
          _hostUrlError = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _hostUrlBytes = null;
        _hostUrlError = null;
      });
    }
    try {
      final bytes = await widget.api.fetchHostResource(widget.host, widget.url);
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _hostUrlBytes = bytes);
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _hostUrlError = error);
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
    if (_hostUrlBytes != null) {
      return MemoryImage(_hostUrlBytes!);
    }
    if (isHostLoopbackUrl(widget.url)) {
      return null;
    }
    if (widget.url.startsWith('http://') || widget.url.startsWith('https://')) {
      return NetworkImage(widget.url);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider();
    if (provider == null) {
      if (isHostLoopbackUrl(widget.url) && _hostUrlError == null) {
        return const MeshLoader(label: 'Loading image');
      }
      return MeshEmptyState.compact(
        icon: Icons.broken_image_rounded,
        title: 'Could not load image',
        action: TextButton(
          onPressed: _loadHostUrlIfNeeded,
          child: const Text('Retry'),
        ),
      );
    }
    return _MediaPreview(provider: provider);
  }
}

class _LocalResourceImage extends StatefulWidget {
  const _LocalResourceImage({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.path,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final String path;

  @override
  State<_LocalResourceImage> createState() => _LocalResourceImageState();
}

class _LocalResourceImageState extends State<_LocalResourceImage> {
  ImageProvider<Object>? _imageProvider;
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
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.path != widget.path) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    setState(() {
      _imageProvider = null;
      _error = null;
    });
    try {
      ImageProvider<Object> imageProvider;
      try {
        imageProvider = await ImageBlobCacheStore.instance.loadImageProvider(
          host: widget.host,
          path: widget.path,
          api: widget.api,
          sessionId: widget.sessionId,
        );
      } on ApiException catch (error) {
        if (error.statusCode != 403) rethrow;
        final artifact = await widget.api.publishSessionArtifact(
          widget.host,
          sessionId: widget.sessionId,
          source: widget.path,
        );
        imageProvider = MemoryImage(
          await widget.api.fetchSessionArtifact(widget.host, artifact.id),
        );
      }
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _imageProvider = imageProvider);
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageProvider = _imageProvider;
    if (imageProvider == null) {
      if (_error == null) return const MeshLoader(label: 'Loading image');
      return MeshEmptyState.compact(
        icon: Icons.broken_image_rounded,
        title: 'Could not load image',
        body: friendlyError(_error!),
        action: TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    return _MediaPreview(provider: imageProvider);
  }
}

class _MediaPreview extends StatefulWidget {
  const _MediaPreview({required this.provider});
  final ImageProvider<Object> provider;
  @override
  State<_MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<_MediaPreview> {
  int _retry = 0;
  Future<void> _reload() async {
    await widget.provider.evict();
    if (mounted) setState(() => _retry++);
  }

  @override
  Widget build(BuildContext context) => Image(
    key: ValueKey(_retry),
    image: widget.provider,
    fit: BoxFit.cover,
    frameBuilder: (context, child, frame, _) =>
        frame == null ? const MeshLoader(label: 'Loading image') : child,
    errorBuilder: (context, error, stackTrace) => MeshEmptyState.compact(
      icon: Icons.broken_image_rounded,
      title: 'Could not load image',
      action: TextButton(onPressed: _reload, child: const Text('Retry')),
    ),
  );
}

IconData _resourceIcon(
  SessionResource resource, {
  required bool preferFileOpen,
}) {
  if (preferFileOpen && resource.hasPath) {
    return Icons.insert_drive_file_rounded;
  }
  if (resource.isImage) {
    return Icons.image_rounded;
  }
  if (resource.isLink) {
    return Icons.link_rounded;
  }
  return Icons.insert_drive_file_rounded;
}

String _sourceLabel(SessionResource resource) {
  final label = switch (resource.source) {
    'message_attachment' => 'attachment',
    'tool_attachment' => 'tool output',
    'message_link' => 'link',
    'message_file' => 'file',
    'web_search' => 'web',
    'image_generation' => 'generated',
    _ => resource.source.replaceAll('_', ' '),
  };
  return _titleCaseWords(label);
}

String _resourceTitle(SessionResource resource) {
  final title = resource.title.trim();
  if (title.isNotEmpty && title != 'Tool output image' && title != 'Image') {
    return title;
  }
  if (resource.hasPath) return _basename(resource.path!);
  return 'Image · ${_formatTimestamp(resource.createdAt)}';
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
