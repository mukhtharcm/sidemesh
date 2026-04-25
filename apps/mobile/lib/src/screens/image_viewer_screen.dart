import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';

enum ImageViewerPresentation { auto, route, dialog }

class ImageViewerSource {
  const ImageViewerSource({
    required this.imageProvider,
    required this.heroTag,
    required this.title,
    this.subtitle,
  });

  final ImageProvider<Object> imageProvider;
  final String heroTag;
  final String title;
  final String? subtitle;
}

Future<void> showImageViewer(
  BuildContext context, {
  required ImageViewerSource source,
  ImageViewerPresentation presentation = ImageViewerPresentation.auto,
}) {
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
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => _ImageViewerDialog(source: source),
    );
  }

  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ImageViewerScreen(source: source)),
  );
}

class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({super.key, required this.source});

  final ImageViewerSource source;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  final GlobalKey<ImageViewerPaneState> _paneKey =
      GlobalKey<ImageViewerPaneState>();
  final ValueNotifier<int> _observable = ValueNotifier<int>(0);

  @override
  void dispose() {
    _observable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: colors.border)),
        title: _ImageViewerHeaderText(
          title: widget.source.title,
          subtitle: widget.source.subtitle,
        ),
        actions: [
          ListenableBuilder(
            listenable: _observable,
            builder: (context, _) =>
                ImageViewerActions(state: _paneKey.currentState),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ImageViewerPane(
        key: _paneKey,
        source: widget.source,
        observable: _observable,
      ),
    );
  }
}

class ImageViewerPane extends StatefulWidget {
  const ImageViewerPane({
    super.key,
    required this.source,
    this.dense = false,
    this.observable,
  });

  final ImageViewerSource source;
  final bool dense;
  final ValueNotifier<int>? observable;

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

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _transformController.addListener(_handleTransformChanged);
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
      CurvedAnimation(parent: controller, curve: Curves.easeOutCubic),
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

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final outerPadding = widget.dense
        ? const EdgeInsets.fromLTRB(10, 8, 10, 12)
        : const EdgeInsets.fromLTRB(12, 10, 12, 24);
    final panelRadius = BorderRadius.circular(widget.dense ? 18 : 22);

    return Padding(
      padding: outerPadding,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: panelRadius,
          border: Border.all(color: colors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: panelRadius,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [colors.surfaceElevated, colors.surfaceMuted],
                  ),
                ),
                child: GestureDetector(
                  onDoubleTapDown: (details) =>
                      _doubleTapLocalPosition = details.localPosition,
                  onDoubleTap: _handleDoubleTap,
                  child: ClipRect(
                    child: InteractiveViewer(
                      transformationController: _transformController,
                      minScale: _minScale,
                      maxScale: _maxScale,
                      boundaryMargin: const EdgeInsets.all(72),
                      clipBehavior: Clip.hardEdge,
                      trackpadScrollCausesScale: true,
                      scaleFactor: 200,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                        child: Center(
                          child: Hero(
                            tag: widget.source.heroTag,
                            child: Image(
                              image: widget.source.imageProvider,
                              fit: BoxFit.contain,
                              frameBuilder: (context, child, frame, _) {
                                if (frame != null) return child;
                                return const Center(
                                  child: MeshLoader(size: 30),
                                );
                              },
                              errorBuilder: (context, error, stackTrace) =>
                                  _ImageViewerErrorState(
                                    title: widget.source.title,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class ImageViewerActions extends StatelessWidget {
  const ImageViewerActions({super.key, required this.state});

  final ImageViewerPaneState? state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MeshPill(label: s?.scaleLabel ?? '100%', mono: true),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Zoom out',
          onPressed: s?.canZoomOut == true ? s?.zoomOut : null,
          icon: const Icon(Icons.remove_rounded, size: 18),
        ),
        IconButton(
          tooltip: 'Zoom in',
          onPressed: s?.canZoomIn == true ? s?.zoomIn : null,
          icon: const Icon(Icons.add_rounded, size: 18),
        ),
        IconButton(
          tooltip: 'Reset zoom',
          onPressed: s?.canReset == true ? s?.reset : null,
          icon: const Icon(Icons.center_focus_strong_rounded, size: 18),
        ),
      ],
    );
  }
}

class _ImageViewerDialog extends StatefulWidget {
  const _ImageViewerDialog({required this.source});

  final ImageViewerSource source;

  @override
  State<_ImageViewerDialog> createState() => _ImageViewerDialogState();
}

class _ImageViewerDialogState extends State<_ImageViewerDialog> {
  final GlobalKey<ImageViewerPaneState> _paneKey =
      GlobalKey<ImageViewerPaneState>();
  final ValueNotifier<int> _observable = ValueNotifier<int>(0);

  @override
  void dispose() {
    _observable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mediaSize = MediaQuery.of(context).size;
    final maxWidth = (mediaSize.width * 0.88).clamp(720.0, 1180.0).toDouble();
    final maxHeight = (mediaSize.height * 0.88).clamp(520.0, 900.0).toDouble();

    return Dialog(
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colors.accentMuted,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colors.accent.withValues(alpha: 0.32),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.image_rounded,
                      size: 18,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ImageViewerHeaderText(
                      title: widget.source.title,
                      subtitle: widget.source.subtitle,
                    ),
                  ),
                  ListenableBuilder(
                    listenable: _observable,
                    builder: (context, _) =>
                        ImageViewerActions(state: _paneKey.currentState),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: ImageViewerPane(
                key: _paneKey,
                source: widget.source,
                dense: true,
                observable: _observable,
              ),
            ),
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
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitleText.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitleText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(color: colors.textTertiary, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _ImageViewerErrorState extends StatelessWidget {
  const _ImageViewerErrorState({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: colors.dangerMuted,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.danger.withValues(alpha: 0.25)),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.broken_image_outlined,
              size: 28,
              color: colors.danger,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Could not load image',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
