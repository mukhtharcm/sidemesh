import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';
import '../theme/app_tokens.dart';
import '../theme/app_status_styles.dart';

class AudioViewerPane extends StatefulWidget {
  const AudioViewerPane({
    super.key,
    required this.host,
    required this.api,
    required this.path,
    required this.mimeHint,
    this.agentProvider,
    this.sessionId,
    this.dense = false,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String mimeHint;
  final String? agentProvider;
  final String? sessionId;
  final bool dense;

  @override
  State<AudioViewerPane> createState() => _AudioViewerPaneState();
}

class _AudioViewerPaneState extends State<AudioViewerPane> {
  VideoPlayerController? _controller;
  Object? _error;
  bool _loading = true;
  int _loadGeneration = 0;
  Duration? _seekPreviewPosition;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant AudioViewerPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host ||
        oldWidget.path != widget.path ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.agentProvider != widget.agentProvider) {
      _initialize();
    }
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_handleControllerChanged);
    controller?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final generation = ++_loadGeneration;
    final previous = _controller;
    _controller = null;
    _seekPreviewPosition = null;
    previous?.removeListener(_handleControllerChanged);
    setState(() {
      _loading = true;
      _error = null;
    });
    await previous?.dispose();
    if (!mounted || generation != _loadGeneration) return;

    final controller = VideoPlayerController.networkUrl(
      widget.api.fsBlobUri(
        widget.host,
        widget.path,
        agentProvider: widget.agentProvider,
        sessionId: widget.sessionId,
      ),
      httpHeaders: widget.api.authHeaders(widget.host),
    );
    controller.addListener(_handleControllerChanged);
    _controller = controller;

    try {
      await controller.initialize();
      await controller.setLooping(false);
    } catch (error) {
      controller.removeListener(_handleControllerChanged);
      unawaited(controller.dispose());
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      if (identical(_controller, controller)) {
        _controller = null;
      }
      setState(() {
        _loading = false;
        _error = error;
      });
      return;
    }

    if (!mounted || generation != _loadGeneration) {
      controller.removeListener(_handleControllerChanged);
      await controller.dispose();
      if (identical(_controller, controller)) {
        _controller = null;
      }
      return;
    }

    setState(() {
      _loading = false;
      _error = null;
    });
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized) return;
    if (value.isPlaying) {
      await controller.pause();
      return;
    }
    if (value.isCompleted) {
      await controller.seekTo(Duration.zero);
    }
    await controller.play();
  }

  void _handleSeekChanged(double value) {
    setState(() {
      _seekPreviewPosition = Duration(milliseconds: value.round());
    });
  }

  Future<void> _handleSeekCommitted(double value) async {
    final controller = _controller;
    if (controller == null) return;
    final position = Duration(milliseconds: value.round());
    setState(() {
      _seekPreviewPosition = null;
    });
    await controller.seekTo(position);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _controller == null) {
      return const _AudioViewerLoadingState();
    }
    final controller = _controller;
    final error =
        _error ??
        (controller?.value.hasError == true
            ? controller?.value.errorDescription
            : null);
    if (error != null) {
      return _AudioViewerErrorState(
        error: friendlyError(error),
        onRetry: _initialize,
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      if (error != null) {
        return _AudioViewerErrorState(
          error: friendlyError(error),
          onRetry: _initialize,
        );
      }
      return const _AudioViewerLoadingState();
    }

    final value = controller.value;
    final colors = context.colors;
    final surfacePadding = widget.dense
        ? const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
          )
        : const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.lg,
          );
    final duration = value.duration;
    final durationMs = duration.inMilliseconds;
    final position = _clampPosition(
      _seekPreviewPosition ?? value.position,
      duration,
    );
    final int positionMs = position.inMilliseconds.clamp(0, durationMs).toInt();
    final double sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final double sliderValue = positionMs
        .toDouble()
        .clamp(0.0, sliderMax)
        .toDouble();
    final mimeLabel = widget.mimeHint.isEmpty ? 'audio' : widget.mimeHint;

    return MeshSurface(
      padding: EdgeInsets.zero,
      tone: MeshSurfaceTone.surface,
      child: Padding(
        padding: surfacePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadii.panel),
                border: Border.all(color: colors.border),
              ),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: colors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.border),
                    ),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      size: AppSizes.iconWell,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Audio preview',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: AppWeights.strong,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.tight),
                  Text(
                    'Streamed from ${widget.host.label}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  MeshPill(label: mimeLabel, mono: true),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                IconButton(
                  tooltip: value.isPlaying ? 'Pause audio' : 'Play audio',
                  onPressed: _togglePlayback,
                  iconSize: AppSizes.featureIcon,
                  icon: Icon(
                    value.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : value.isCompleted
                        ? Icons.replay_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: sliderValue,
                    min: 0,
                    max: sliderMax,
                    onChanged: durationMs > 0 ? _handleSeekChanged : null,
                    onChangeEnd: durationMs > 0 ? _handleSeekCommitted : null,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  _formatDuration(position),
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: AppFontSizes.caption,
                  ),
                ),
                const Spacer(),
                Text(
                  _formatDuration(duration),
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: AppFontSizes.caption,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.compact),
            Text(
              'Tap play to start, then drag the seek bar to scrub.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioViewerLoadingState extends StatelessWidget {
  const _AudioViewerLoadingState();
  @override
  Widget build(BuildContext context) =>
      const MeshLoader(label: 'Loading audio');
}

class _AudioViewerErrorState extends StatelessWidget {
  const _AudioViewerErrorState({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => MeshEmptyState.compact(
    icon: Icons.error_outline_rounded,
    title: 'Could not load audio',
    body: error,
    action: TextButton(onPressed: onRetry, child: const Text('Retry')),
  );
}

Duration _clampPosition(Duration position, Duration duration) {
  if (position.isNegative) {
    return Duration.zero;
  }
  if (duration <= Duration.zero) {
    return position;
  }
  if (position > duration) {
    return duration;
  }
  return position;
}

String _formatDuration(Duration value) {
  final totalSeconds = value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}
