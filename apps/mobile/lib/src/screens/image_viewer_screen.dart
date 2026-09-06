import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../widgets/mesh_widgets.dart';

enum ImageViewerPresentation { auto, route, dialog }

typedef ImageProviderLoader = Future<ImageProvider<Object>> Function();

class ImageViewerSource {
  const ImageViewerSource({
    required ImageProvider<Object> imageProvider,
    required String heroTag,
    required String title,
    String? subtitle,
  }) : this._(
         imageProvider: imageProvider,
         imageProviderLoader: null,
         heroTag: heroTag,
         title: title,
         subtitle: subtitle,
       );

  const ImageViewerSource.loader({
    required ImageProviderLoader imageProviderLoader,
    String? heroTag,
    required String title,
    String? subtitle,
  }) : this._(
         imageProvider: null,
         imageProviderLoader: imageProviderLoader,
         heroTag: heroTag,
         title: title,
         subtitle: subtitle,
       );

  const ImageViewerSource._({
    required this.imageProvider,
    required this.imageProviderLoader,
    required this.heroTag,
    required this.title,
    required this.subtitle,
  });

  final ImageProvider<Object>? imageProvider;
  final ImageProviderLoader? imageProviderLoader;
  final String? heroTag;
  final String title;
  final String? subtitle;
}

Future<void> showImageViewer(
  BuildContext context, {
  required ImageViewerSource source,
  ImageViewerPresentation presentation = ImageViewerPresentation.auto,
}) {
  return showImageGalleryViewer(
    context,
    sources: <ImageViewerSource>[source],
    presentation: presentation,
  );
}

Future<void> showImageGalleryViewer(
  BuildContext context, {
  required List<ImageViewerSource> sources,
  int initialIndex = 0,
  ImageViewerPresentation presentation = ImageViewerPresentation.auto,
}) {
  if (sources.isEmpty) {
    return Future<void>.value();
  }
  final clampedIndex = initialIndex.clamp(0, sources.length - 1);
  final resolved = switch (presentation) {
    ImageViewerPresentation.auto =>
      MediaQuery.sizeOf(context).width >= 900
          ? ImageViewerPresentation.dialog
          : ImageViewerPresentation.route,
    ImageViewerPresentation.route => ImageViewerPresentation.route,
    ImageViewerPresentation.dialog => ImageViewerPresentation.dialog,
  };

  if (resolved == ImageViewerPresentation.dialog) {
    return showDialog<void>(
      context: context,
      barrierColor: AppOverlayColors.modalBarrier,
      builder: (_) =>
          _ImageViewerDialog(sources: sources, initialIndex: clampedIndex),
    );
  }

  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          ImageViewerScreen(sources: sources, initialIndex: clampedIndex),
    ),
  );
}

class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({
    super.key,
    required this.sources,
    this.initialIndex = 0,
  });

  final List<ImageViewerSource> sources;
  final int initialIndex;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _pageController;
  late final List<GlobalKey<ImageViewerPaneState>> _paneKeys;
  late final List<ValueNotifier<int>> _observables;
  late int _index;
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.sources.length - 1);
    _pageController = PageController(initialPage: _index);
    _paneKeys = List<GlobalKey<ImageViewerPaneState>>.generate(
      widget.sources.length,
      (_) => GlobalKey<ImageViewerPaneState>(),
      growable: false,
    );
    _observables = List<ValueNotifier<int>>.generate(
      widget.sources.length,
      (_) => ValueNotifier<int>(0),
      growable: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final observable in _observables) {
      observable.dispose();
    }
    super.dispose();
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
  }

  ImageViewerSource get _currentSource => widget.sources[_index];
  ImageViewerPaneState? get _currentPaneState => _paneKeys[_index].currentState;
  bool get _canGoPrevious => _index > 0;
  bool get _canGoNext => _index < widget.sources.length - 1;

  void _goPrevious() {
    if (!_canGoPrevious) return;
    _pageController.previousPage(
      duration: AppMotion.quick,
      curve: AppMotion.standard,
    );
  }

  void _goNext() {
    if (!_canGoNext) return;
    _pageController.nextPage(
      duration: AppMotion.quick,
      curve: AppMotion.standard,
    );
  }

  void _zoomInCurrent() {
    final state = _currentPaneState;
    if (state?.canZoomIn == true) state?.zoomIn();
  }

  void _zoomOutCurrent() {
    final state = _currentPaneState;
    if (state?.canZoomOut == true) state?.zoomOut();
  }

  void _resetCurrentZoom() {
    final state = _currentPaneState;
    if (state?.canReset == true) state?.reset();
  }

  @override
  Widget build(BuildContext context) {
    final countLabel = widget.sources.length > 1
        ? '${_index + 1} / ${widget.sources.length}'
        : null;
    return _ImageViewerKeyboardScope(
      onPrevious: _goPrevious,
      onNext: _goNext,
      onZoomIn: _zoomInCurrent,
      onZoomOut: _zoomOutCurrent,
      onResetZoom: _resetCurrentZoom,
      onClose: () => Navigator.of(context).maybePop(),
      onToggleChrome: _toggleChrome,
      child: Scaffold(
        backgroundColor: AppMediaColors.background,
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: widget.sources.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (context, index) => ImageViewerPane(
                    key: _paneKeys[index],
                    source: widget.sources[index],
                    immersive: true,
                    onTap: _toggleChrome,
                    observable: _observables[index],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: AnimatedOpacity(
                  duration: AppMotion.quick,
                  opacity: _chromeVisible ? AppEmphasis.full : 0,
                  child: SafeArea(
                    bottom: false,
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        AppSpacing.md,
                        AppSpacing.md,
                        0,
                      ),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm,
                        AppSpacing.sm,
                        AppSpacing.compact,
                        AppSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: AppMediaColors.overlay,
                        borderRadius: AppShapes.panel,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: AppMediaColors.foreground,
                            ),
                          ),
                          if (countLabel != null)
                            Expanded(
                              child: Text(
                                countLabel,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: AppMediaColors.foreground,
                                      fontWeight: AppWeights.strong,
                                    ),
                              ),
                            )
                          else
                            const Spacer(),
                          ListenableBuilder(
                            listenable: _observables[_index],
                            builder: (context, _) => SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ImageViewerActions(
                                state: _paneKeys[_index].currentState,
                                compact: true,
                                dark: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: AnimatedOpacity(
                  duration: AppMotion.quick,
                  opacity: _chromeVisible ? AppEmphasis.full : 0,
                  child: _ImageViewerCaption(
                    title: _currentSource.title,
                    subtitle: _currentSource.subtitle,
                    dark: true,
                    margin: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      0,
                      AppSpacing.md,
                      AppSpacing.md,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ImageViewerPane extends StatefulWidget {
  const ImageViewerPane({
    super.key,
    required this.source,
    this.dense = false,
    this.immersive = false,
    this.observable,
    this.onTap,
  });

  final ImageViewerSource source;
  final bool dense;
  final bool immersive;
  final ValueNotifier<int>? observable;
  final VoidCallback? onTap;

  @override
  State<ImageViewerPane> createState() => ImageViewerPaneState();
}

class ImageViewerPaneState extends State<ImageViewerPane>
    with SingleTickerProviderStateMixin {
  static const _minScale = 1.0;
  static const _maxScale = 5.0;
  static const _zoomSteps = <double>[1.0, 2.0, 3.0, 4.0, 5.0];

  late final TransformationController _transformController =
      TransformationController();
  AnimationController? _animationController;
  Animation<Matrix4>? _matrixAnimation;
  late final ValueNotifier<int> changes =
      widget.observable ?? ValueNotifier<int>(0);

  Offset? _doubleTapLocalPosition;
  Size _viewportSize = Size.zero;
  ImageProvider<Object>? _resolvedImageProvider;
  Object? _loadError;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: AppMotion.quick,
    );
    _transformController.addListener(_handleTransformChanged);
    unawaited(_resolveImageProvider());
  }

  @override
  void didUpdateWidget(covariant ImageViewerPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      reset();
      unawaited(_resolveImageProvider());
    }
  }

  @override
  void dispose() {
    _animationController
      ?..stop()
      ..dispose();
    _transformController
      ..removeListener(_handleTransformChanged)
      ..dispose();
    if (widget.observable == null) {
      changes.dispose();
    }
    super.dispose();
  }

  Future<void> _resolveImageProvider() async {
    final gen = ++_loadGeneration;
    final imageProvider = widget.source.imageProvider;
    if (imageProvider != null) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _resolvedImageProvider = imageProvider;
        _loadError = null;
      });
      return;
    }

    final loader = widget.source.imageProviderLoader;
    if (loader == null) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _resolvedImageProvider = null;
        _loadError = StateError('No image provider available');
      });
      return;
    }

    setState(() {
      _resolvedImageProvider = null;
      _loadError = null;
    });
    try {
      final loaded = await loader();
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _resolvedImageProvider = loaded;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _resolvedImageProvider = null;
        _loadError = error;
      });
    }
  }

  Future<void> _retryImage() async {
    final provider = _resolvedImageProvider;
    setState(() {
      _resolvedImageProvider = null;
      _loadError = null;
    });
    await provider?.evict();
    if (mounted) await _resolveImageProvider();
  }

  void _handleTransformChanged() => changes.value++;

  double get scale => _transformController.value.getMaxScaleOnAxis();
  String get scaleLabel => '${(scale * 100).round()}%';
  bool get canReset => scale > 1.01;
  bool get canZoomIn => scale < (_maxScale - 0.01);
  bool get canZoomOut => scale > (_minScale + 0.01);

  void reset() => _animateToScale(_minScale);

  void zoomIn() {
    final current = scale;
    final target = _zoomSteps.firstWhere(
      (step) => step > (current + 0.05),
      orElse: () => _maxScale,
    );
    _animateToScale(target);
  }

  void zoomOut() {
    final current = scale;
    final reversed = _zoomSteps.reversed;
    final target = reversed.firstWhere(
      (step) => step < (current - 0.05),
      orElse: () => _minScale,
    );
    _animateToScale(target);
  }

  void _animateToScale(double targetScale, {Offset? focalPoint}) {
    final clampedScale = targetScale.clamp(_minScale, _maxScale);
    if (_viewportSize.isEmpty) {
      _transformController.value = _matrixForScale(
        clampedScale,
        _viewportCenter,
      );
      return;
    }

    final begin = Matrix4.copy(_transformController.value);
    final end = _matrixForScale(clampedScale, focalPoint ?? _viewportCenter);
    final controller = _animationController;
    if (controller == null) {
      _transformController.value = end;
      return;
    }

    controller.stop();
    _matrixAnimation?.removeListener(_handleMatrixAnimationTick);
    _matrixAnimation = Matrix4Tween(begin: begin, end: end).animate(
      CurvedAnimation(parent: controller, curve: AppMotion.standard),
    )..addListener(_handleMatrixAnimationTick);
    controller
      ..reset()
      ..forward();
  }

  void _handleMatrixAnimationTick() {
    final value = _matrixAnimation?.value;
    if (value == null) return;
    _transformController.value = value;
  }

  Offset get _viewportCenter =>
      Offset(_viewportSize.width / 2, _viewportSize.height / 2);

  Matrix4 _matrixForScale(double targetScale, Offset focalPoint) {
    if (targetScale <= 1.001 || _viewportSize.isEmpty) {
      return Matrix4.identity();
    }
    final clampedFocal = Offset(
      focalPoint.dx.clamp(0.0, _viewportSize.width),
      focalPoint.dy.clamp(0.0, _viewportSize.height),
    );
    final translateX = clampedFocal.dx - (clampedFocal.dx * targetScale);
    final translateY = clampedFocal.dy - (clampedFocal.dy * targetScale);
    return Matrix4.identity()
      ..translateByDouble(translateX, translateY, 0, 1)
      ..scaleByDouble(targetScale, targetScale, 1, 1);
  }

  void _handleDoubleTap() {
    if (canReset) {
      reset();
      return;
    }
    _animateToScale(
      2.0,
      focalPoint: _doubleTapLocalPosition ?? _viewportCenter,
    );
  }

  Widget _buildImageChild(BoxConstraints constraints) {
    final imageProvider = _resolvedImageProvider;
    Widget child;
    if (imageProvider == null) {
      child = _loadError == null
          ? const MeshLoader(label: 'Loading image')
          : _ImageViewerErrorState(onRetry: _retryImage);
    } else {
      child = Image(
        image: imageProvider,
        fit: BoxFit.contain,
        frameBuilder: (context, imageChild, frame, _) {
          if (frame != null) return imageChild;
          return const MeshLoader(label: 'Loading image');
        },
        errorBuilder: (context, error, stackTrace) =>
            _ImageViewerErrorState(onRetry: _retryImage),
      );
      final heroTag = widget.source.heroTag;
      if ((heroTag ?? '').isNotEmpty) {
        child = Hero(tag: heroTag!, child: child);
      }
    }

    return SizedBox(
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      child: Center(child: child),
    );
  }

  Widget _buildInteractiveViewport(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (_resolvedImageProvider == null) {
          return _buildImageChild(constraints);
        }
        return GestureDetector(
          onTap: widget.onTap,
          onDoubleTapDown: (details) =>
              _doubleTapLocalPosition = details.localPosition,
          onDoubleTap: _handleDoubleTap,
          child: ClipRect(
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: _minScale,
              maxScale: _maxScale,
              boundaryMargin: const EdgeInsets.all(AppSizes.previewGutter),
              clipBehavior: Clip.hardEdge,
              trackpadScrollCausesScale: true,
              scaleFactor: 200,
              child: _buildImageChild(constraints),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (widget.immersive) {
      return ColoredBox(
        color: AppMediaColors.background,
        child: _buildInteractiveViewport(context),
      );
    }

    final outerPadding = widget.dense
        ? const EdgeInsets.fromLTRB(
            AppSpacing.compact,
            AppSpacing.sm,
            AppSpacing.compact,
            AppSpacing.md,
          )
        : const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.compact,
            AppSpacing.md,
            AppSpacing.xl,
          );
    final panelRadius = AppShapes.panel;

    return Padding(
      padding: outerPadding,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: panelRadius,
          border: Border.all(color: colors.border),
          boxShadow: [AppShadows.surface(colors.textPrimary)],
        ),
        child: ClipRRect(
          borderRadius: panelRadius,
          child: DecoratedBox(
            decoration: BoxDecoration(color: colors.surfaceMuted),
            child: _buildInteractiveViewport(context),
          ),
        ),
      ),
    );
  }
}

class ImageViewerActions extends StatelessWidget {
  const ImageViewerActions({
    super.key,
    required this.state,
    this.compact = false,
    this.dark = false,
  });

  final ImageViewerPaneState? state;
  final bool compact;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final foreground = dark ? AppMediaColors.foreground : null;
    final iconSize = AppSizes.inlineIcon;
    final spacing = compact ? 2.0 : 4.0;
    return IconTheme(
      data: IconThemeData(color: foreground),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MeshPill(label: s?.scaleLabel ?? '100%', mono: true),
          SizedBox(width: spacing),
          IconButton(
            tooltip: 'Zoom out',
            color: foreground,
            visualDensity: compact ? VisualDensity.compact : null,
            onPressed: s?.canZoomOut == true ? s?.zoomOut : null,
            icon: Icon(Icons.remove_rounded, size: iconSize),
          ),
          IconButton(
            tooltip: 'Zoom in',
            color: foreground,
            visualDensity: compact ? VisualDensity.compact : null,
            onPressed: s?.canZoomIn == true ? s?.zoomIn : null,
            icon: Icon(Icons.add_rounded, size: iconSize),
          ),
          IconButton(
            tooltip: 'Actual size',
            color: foreground,
            visualDensity: compact ? VisualDensity.compact : null,
            onPressed: s?.canReset == true ? s?.reset : null,
            icon: Icon(Icons.center_focus_strong_rounded, size: iconSize),
          ),
        ],
      ),
    );
  }
}

class _ImageViewerDialog extends StatefulWidget {
  const _ImageViewerDialog({required this.sources, required this.initialIndex});

  final List<ImageViewerSource> sources;
  final int initialIndex;

  @override
  State<_ImageViewerDialog> createState() => _ImageViewerDialogState();
}

class _ImageViewerDialogState extends State<_ImageViewerDialog> {
  late final PageController _pageController;
  late final List<GlobalKey<ImageViewerPaneState>> _paneKeys;
  late final List<ValueNotifier<int>> _observables;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.sources.length - 1);
    _pageController = PageController(initialPage: _index);
    _paneKeys = List<GlobalKey<ImageViewerPaneState>>.generate(
      widget.sources.length,
      (_) => GlobalKey<ImageViewerPaneState>(),
      growable: false,
    );
    _observables = List<ValueNotifier<int>>.generate(
      widget.sources.length,
      (_) => ValueNotifier<int>(0),
      growable: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final observable in _observables) {
      observable.dispose();
    }
    super.dispose();
  }

  ImageViewerPaneState? get _currentPaneState => _paneKeys[_index].currentState;
  bool get _canGoPrevious => _index > 0;
  bool get _canGoNext => _index < widget.sources.length - 1;

  void _goPrevious() {
    if (!_canGoPrevious) return;
    _pageController.previousPage(
      duration: AppMotion.quick,
      curve: AppMotion.standard,
    );
  }

  void _goNext() {
    if (!_canGoNext) return;
    _pageController.nextPage(
      duration: AppMotion.quick,
      curve: AppMotion.standard,
    );
  }

  void _zoomInCurrent() {
    final state = _currentPaneState;
    if (state?.canZoomIn == true) state?.zoomIn();
  }

  void _zoomOutCurrent() {
    final state = _currentPaneState;
    if (state?.canZoomOut == true) state?.zoomOut();
  }

  void _resetCurrentZoom() {
    final state = _currentPaneState;
    if (state?.canReset == true) state?.reset();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mediaSize = MediaQuery.of(context).size;
    final maxWidth = (mediaSize.width * 0.88).clamp(720.0, 1180.0).toDouble();
    final maxHeight = (mediaSize.height * 0.88).clamp(520.0, 900.0).toDouble();
    final source = widget.sources[_index];

    return _ImageViewerKeyboardScope(
      onPrevious: _goPrevious,
      onNext: _goNext,
      onZoomIn: _zoomInCurrent,
      onZoomOut: _zoomOutCurrent,
      onResetZoom: _resetCurrentZoom,
      onClose: () => Navigator.of(context).maybePop(),
      child: Dialog(
        backgroundColor: colors.surface,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxxl,
          vertical: AppSpacing.xxxl,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.compact,
                  AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: colors.accentMuted,
                        borderRadius: AppShapes.iconWell,
                        border: Border.all(
                          color: colors.accent.withValues(
                            alpha: AppEmphasis.borderTint,
                          ),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.image_rounded,
                        size: AppSizes.inlineIcon,
                        color: colors.accent,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: _ImageViewerHeaderText(
                        title: source.title,
                        subtitle: source.subtitle,
                      ),
                    ),
                    if (widget.sources.length > 1) ...[
                      IconButton(
                        tooltip: 'Previous',
                        onPressed: _canGoPrevious ? _goPrevious : null,
                        icon: const Icon(
                          Icons.chevron_left_rounded,
                          size: AppSizes.icon,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next',
                        onPressed: _canGoNext ? _goNext : null,
                        icon: const Icon(
                          Icons.chevron_right_rounded,
                          size: AppSizes.icon,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      MeshPill(
                        label: '${_index + 1} / ${widget.sources.length}',
                        mono: true,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    ListenableBuilder(
                      listenable: _observables[_index],
                      builder: (context, _) => ImageViewerActions(
                        state: _paneKeys[_index].currentState,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: AppSizes.icon,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.border),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: widget.sources.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (context, index) => ImageViewerPane(
                    key: _paneKeys[index],
                    source: widget.sources[index],
                    dense: true,
                    observable: _observables[index],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviousImageIntent extends Intent {
  const _PreviousImageIntent();
}

class _NextImageIntent extends Intent {
  const _NextImageIntent();
}

class _ZoomInImageIntent extends Intent {
  const _ZoomInImageIntent();
}

class _ZoomOutImageIntent extends Intent {
  const _ZoomOutImageIntent();
}

class _ResetImageZoomIntent extends Intent {
  const _ResetImageZoomIntent();
}

class _CloseImageViewerIntent extends Intent {
  const _CloseImageViewerIntent();
}

class _ToggleImageChromeIntent extends Intent {
  const _ToggleImageChromeIntent();
}

class _ImageViewerKeyboardScope extends StatelessWidget {
  const _ImageViewerKeyboardScope({
    required this.child,
    required this.onPrevious,
    required this.onNext,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onResetZoom,
    required this.onClose,
    this.onToggleChrome,
  });

  final Widget child;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onResetZoom;
  final VoidCallback onClose;
  final VoidCallback? onToggleChrome;

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.arrowLeft):
          const _PreviousImageIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowUp):
          const _PreviousImageIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowRight):
          const _NextImageIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowDown):
          const _NextImageIntent(),
      const SingleActivator(LogicalKeyboardKey.equal):
          const _ZoomInImageIntent(),
      const SingleActivator(LogicalKeyboardKey.equal, shift: true):
          const _ZoomInImageIntent(),
      const SingleActivator(LogicalKeyboardKey.numpadAdd):
          const _ZoomInImageIntent(),
      const SingleActivator(LogicalKeyboardKey.minus):
          const _ZoomOutImageIntent(),
      const SingleActivator(LogicalKeyboardKey.numpadSubtract):
          const _ZoomOutImageIntent(),
      const SingleActivator(LogicalKeyboardKey.digit0):
          const _ResetImageZoomIntent(),
      const SingleActivator(LogicalKeyboardKey.escape):
          const _CloseImageViewerIntent(),
    };
    if (onToggleChrome != null) {
      shortcuts[const SingleActivator(LogicalKeyboardKey.space)] =
          const _ToggleImageChromeIntent();
    }

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PreviousImageIntent: CallbackAction<_PreviousImageIntent>(
            onInvoke: (_) {
              onPrevious();
              return null;
            },
          ),
          _NextImageIntent: CallbackAction<_NextImageIntent>(
            onInvoke: (_) {
              onNext();
              return null;
            },
          ),
          _ZoomInImageIntent: CallbackAction<_ZoomInImageIntent>(
            onInvoke: (_) {
              onZoomIn();
              return null;
            },
          ),
          _ZoomOutImageIntent: CallbackAction<_ZoomOutImageIntent>(
            onInvoke: (_) {
              onZoomOut();
              return null;
            },
          ),
          _ResetImageZoomIntent: CallbackAction<_ResetImageZoomIntent>(
            onInvoke: (_) {
              onResetZoom();
              return null;
            },
          ),
          _CloseImageViewerIntent: CallbackAction<_CloseImageViewerIntent>(
            onInvoke: (_) {
              onClose();
              return null;
            },
          ),
          if (onToggleChrome != null)
            _ToggleImageChromeIntent: CallbackAction<_ToggleImageChromeIntent>(
              onInvoke: (_) {
                onToggleChrome?.call();
                return null;
              },
            ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _ImageViewerCaption extends StatelessWidget {
  const _ImageViewerCaption({
    required this.title,
    required this.subtitle,
    required this.dark,
    this.margin = EdgeInsets.zero,
  });

  final String title;
  final String? subtitle;
  final bool dark;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final subtitleText = (subtitle ?? '').trim();
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: dark ? AppMediaColors.foreground : null,
      fontWeight: AppWeights.strong,
    );
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: dark ? AppMediaColors.secondary : context.colors.textTertiary,
      height: AppLineHeights.caption,
    );
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        margin: margin,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        decoration: BoxDecoration(
          color: dark ? AppMediaColors.overlay : null,
          borderRadius: AppShapes.panel,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
            if (subtitleText.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitleText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: subtitleStyle,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ImageViewerHeaderText extends StatelessWidget {
  const _ImageViewerHeaderText({required this.title, required this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final subtitleText = (subtitle ?? '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: AppWeights.strong),
        ),
        if (subtitleText.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            subtitleText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
        ],
      ],
    );
  }
}

class _ImageViewerErrorState extends StatelessWidget {
  const _ImageViewerErrorState({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => MeshEmptyState.compact(
    icon: Icons.broken_image_rounded,
    title: 'Could not load image',
    action: TextButton(onPressed: onRetry, child: const Text('Retry')),
  );
}
