import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';
import '../app_icons.dart';

typedef PdfViewerPanePreviewBuilder =
    Widget Function(BuildContext context, PdfViewerPanePreviewData data);

class PdfViewerPanePreviewData {
  const PdfViewerPanePreviewData({
    required this.bytes,
    required this.controller,
    required this.params,
    required this.sourceName,
  });

  final Uint8List bytes;
  final PdfViewerController controller;
  final PdfViewerParams params;
  final String sourceName;
}

class PdfViewerPane extends StatefulWidget {
  const PdfViewerPane({
    super.key,
    required this.host,
    required this.api,
    required this.path,
    required this.mimeHint,
    this.agentProvider,
    this.sessionId,
    this.dense = false,
    this.previewBuilder,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String mimeHint;
  final String? agentProvider;
  final String? sessionId;
  final bool dense;
  final PdfViewerPanePreviewBuilder? previewBuilder;

  @override
  State<PdfViewerPane> createState() => _PdfViewerPaneState();
}

class _PdfViewerPaneState extends State<PdfViewerPane> {
  final PdfViewerController _controller = PdfViewerController();

  Uint8List? _bytes;
  Object? _error;
  bool _loading = true;
  int _loadGeneration = 0;
  int? _currentPageNumber;
  int? _pageCount;
  double? _currentZoom;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant PdfViewerPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host ||
        oldWidget.path != widget.path ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.agentProvider != widget.agentProvider) {
      _load();
    }
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted || !_controller.isReady) {
      return;
    }
    final zoom = _controller.currentZoom;
    if (_currentZoom != null && (zoom - _currentZoom!).abs() < 0.001) {
      return;
    }
    setState(() {
      _currentZoom = zoom;
    });
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _bytes = null;
      _error = null;
      _loading = true;
      _currentPageNumber = null;
      _pageCount = null;
      _currentZoom = null;
    });
    try {
      final bytes = await widget.api.fetchFsBlob(
        widget.host,
        widget.path,
        agentProvider: widget.agentProvider,
        sessionId: widget.sessionId,
      );
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _bytes = null;
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _stepZoom(bool zoomIn) async {
    if (!_controller.isReady) {
      return;
    }
    final zoom = zoomIn
        ? _controller.getNextZoom(loop: false)
        : _controller.getPreviousZoom(loop: false);
    await _controller.setZoom(
      _controller.centerPosition,
      zoom,
      duration: const Duration(milliseconds: 180),
    );
  }

  Future<void> _fitWidth() async {
    if (!_controller.isReady) {
      return;
    }
    final pageNumber = _currentPageNumber ?? _controller.pageNumber ?? 1;
    final destination = _controller.calcMatrixFitWidthForPage(
      pageNumber: pageNumber,
    );
    await _controller.goTo(
      destination,
      duration: const Duration(milliseconds: 180),
    );
  }

  Future<void> _goToPage(int pageNumber) async {
    if (!_controller.isReady || pageNumber < 1 || _pageCount == null) {
      return;
    }
    if (pageNumber > _pageCount!) {
      return;
    }
    await _controller.goToPage(
      pageNumber: pageNumber,
      duration: const Duration(milliseconds: 180),
    );
  }

  void _handleViewerReady(
    PdfDocument document,
    PdfViewerController controller,
  ) {
    if (!mounted) {
      return;
    }
    setState(() {
      _pageCount = document.pages.length;
      _currentPageNumber = controller.pageNumber ?? 1;
      _currentZoom = controller.currentZoom;
    });
    unawaited(_fitWidth());
  }

  Widget _buildPreview(BuildContext context, PdfViewerPanePreviewData data) {
    final builder = widget.previewBuilder;
    if (builder != null) {
      return builder(context, data);
    }
    return PdfViewer.data(
      data.bytes,
      sourceName: data.sourceName,
      controller: data.controller,
      params: data.params,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _bytes == null) {
      return const _PdfViewerLoadingState();
    }
    if (_error != null && _bytes == null) {
      return _PdfViewerErrorState(
        error: friendlyError(_error!),
        onRetry: _load,
      );
    }

    final bytes = _bytes!;
    final colors = context.colors;
    final sourceName = widget.path;
    final params = PdfViewerParams(
      margin: widget.dense ? 10 : 14,
      backgroundColor: colors.surfaceMuted,
      pageDropShadow: BoxShadow(
        color: colors.textPrimary.withValues(alpha: 0.08),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
      onPageChanged: (pageNumber) {
        if (!mounted) {
          return;
        }
        setState(() {
          _currentPageNumber = pageNumber ?? _currentPageNumber;
        });
      },
      onViewerReady: _handleViewerReady,
    );
    final preview = _buildPreview(
      context,
      PdfViewerPanePreviewData(
        bytes: bytes,
        controller: _controller,
        params: params,
        sourceName: sourceName,
      ),
    );
    final pageLabel = switch ((_currentPageNumber, _pageCount)) {
      (final current?, final total?) => 'Page $current of $total',
      _ => 'Preparing document',
    };
    final zoomLabel = _currentZoom == null
        ? '...'
        : '${(_currentZoom! * 100).round()}%';
    final controlPadding = widget.dense
        ? const EdgeInsets.fromLTRB(12, 10, 12, 10)
        : const EdgeInsets.fromLTRB(14, 12, 14, 12);
    final viewerBody = LayoutBuilder(
      builder: (context, constraints) {
        final child = MeshSurface(
          padding: EdgeInsets.zero,
          tone: MeshSurfaceTone.surface,
          child: preview,
        );
        if (constraints.maxHeight.isFinite) {
          return child;
        }
        return SizedBox(height: widget.dense ? 420 : 560, child: child);
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: viewerBody),
        const SizedBox(height: 12),
        MeshSurface(
          padding: controlPadding,
          tone: MeshSurfaceTone.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous page',
                    onPressed: (_currentPageNumber ?? 1) > 1
                        ? () => _goToPage((_currentPageNumber ?? 1) - 1)
                        : null,
                    icon: const Icon(AppIcons.chevron_left_rounded),
                  ),
                  Expanded(
                    child: Text(
                      pageLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next page',
                    onPressed:
                        _pageCount != null &&
                            (_currentPageNumber ?? 1) < _pageCount!
                        ? () => _goToPage((_currentPageNumber ?? 1) + 1)
                        : null,
                    icon: const Icon(AppIcons.chevron_right_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Zoom out',
                    onPressed: _controller.isReady
                        ? () => _stepZoom(false)
                        : null,
                    icon: const Icon(AppIcons.remove_rounded),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      zoomLabel,
                      textAlign: TextAlign.center,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zoom in',
                    onPressed: _controller.isReady
                        ? () => _stepZoom(true)
                        : null,
                    icon: const Icon(AppIcons.add_rounded),
                  ),
                  IconButton(
                    tooltip: 'Fit width',
                    onPressed: _controller.isReady ? _fitWidth : null,
                    icon: const Icon(AppIcons.fit_screen_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Scroll to read. Pinch or use the zoom controls to adjust the page.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PdfViewerLoadingState extends StatelessWidget {
  const _PdfViewerLoadingState();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MeshSurface(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            tone: MeshSurfaceTone.surface,
            child: Container(
              color: colors.surfaceMuted,
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  const FractionallySizedBox(
                    widthFactor: 0.72,
                    child: MeshSkeleton(height: 18, radius: 999),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => MeshSkeleton(
                        height: constraints.maxHeight,
                        radius: 18,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const MeshSurface(
          padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
          tone: MeshSurfaceTone.surface,
          child: Row(
            children: [
              MeshSkeleton(width: 32, height: 32, radius: 999),
              SizedBox(width: 12),
              Expanded(child: MeshSkeleton(height: 14, radius: 999)),
              SizedBox(width: 12),
              MeshSkeleton(width: 32, height: 32, radius: 999),
              SizedBox(width: 18),
              MeshSkeleton(width: 32, height: 32, radius: 999),
              SizedBox(width: 10),
              MeshSkeleton(width: 48, height: 14, radius: 999),
              SizedBox(width: 10),
              MeshSkeleton(width: 32, height: 32, radius: 999),
              SizedBox(width: 10),
              MeshSkeleton(width: 32, height: 32, radius: 999),
            ],
          ),
        ),
      ],
    );
  }
}

class _PdfViewerErrorState extends StatelessWidget {
  const _PdfViewerErrorState({required this.error, required this.onRetry});

  final String error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MeshEmptyState(
            icon: AppIcons.picture_as_pdf_rounded,
            title: 'Could not load PDF',
            body: error,
          ),
          TextButton.icon(
            onPressed: () {
              unawaited(onRetry());
            },
            icon: const Icon(AppIcons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
