import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';
import '../theme/app_tokens.dart';
import '../theme/app_status_styles.dart';

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
      duration: AppMotion.quick,
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
    await _controller.goTo(destination, duration: AppMotion.quick);
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
      duration: AppMotion.quick,
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
      return const MeshLoader(label: 'Loading PDF');
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
      pageDropShadow: AppShadows.surface(colors.textPrimary),
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
        ? const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.compact,
            AppSpacing.md,
            AppSpacing.compact,
          )
        : const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
          );
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
        const SizedBox(height: AppSpacing.md),
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
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Expanded(
                    child: Text(
                      pageLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: AppFontSizes.caption,
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
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  IconButton(
                    tooltip: 'Zoom out',
                    onPressed: _controller.isReady
                        ? () => _stepZoom(false)
                        : null,
                    icon: const Icon(Icons.remove_rounded),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      zoomLabel,
                      textAlign: TextAlign.center,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: AppFontSizes.caption,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zoom in',
                    onPressed: _controller.isReady
                        ? () => _stepZoom(true)
                        : null,
                    icon: const Icon(Icons.add_rounded),
                  ),
                  IconButton(
                    tooltip: 'Fit width',
                    onPressed: _controller.isReady ? _fitWidth : null,
                    icon: const Icon(Icons.fit_screen_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
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

class _PdfViewerErrorState extends StatelessWidget {
  const _PdfViewerErrorState({required this.error, required this.onRetry});

  final String error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return MeshEmptyState.compact(
      icon: Icons.picture_as_pdf_rounded,
      title: 'Could not load PDF',
      body: error,
      action: TextButton(onPressed: onRetry, child: const Text('Retry')),
    );
  }
}
