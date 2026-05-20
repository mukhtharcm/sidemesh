import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';

class VideoViewerPane extends StatefulWidget {
  const VideoViewerPane({
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
  State<VideoViewerPane> createState() => _VideoViewerPaneState();
}

class _VideoViewerPaneState extends State<VideoViewerPane> {
  VideoPlayerController? _controller;
  Object? _error;
  bool _loading = true;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant VideoViewerPane oldWidget) {
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
    previous?.removeListener(_handleControllerChanged);
    setState(() {
      _loading = true;
      _error = null;
    });
    await previous?.dispose();

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
      await controller.dispose();
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

  @override
  Widget build(BuildContext context) {
    if (_loading && _controller == null) {
      return const _VideoViewerLoadingState();
    }
    final controller = _controller;
    final error =
        _error ??
        (controller?.value.hasError == true
            ? controller?.value.errorDescription
            : null);
    if (error != null && controller == null) {
      return _VideoViewerErrorState(error: friendlyError(error));
    }
    if (controller == null || !controller.value.isInitialized) {
      if (error != null) {
        return _VideoViewerErrorState(error: friendlyError(error));
      }
      return const _VideoViewerLoadingState();
    }

    final value = controller.value;
    final colors = context.colors;
    final controlPadding = widget.dense
        ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
        : const EdgeInsets.fromLTRB(14, 12, 14, 14);
    final aspectRatio = value.aspectRatio > 0 ? value.aspectRatio : 16 / 9;
    final mimeLabel = widget.mimeHint.isEmpty ? 'video' : widget.mimeHint;

    final preview = GestureDetector(
      onTap: _togglePlayback,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Center(child: VideoPlayer(controller)),
          if (!value.isPlaying)
            Center(
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Icon(
                  value.isCompleted
                      ? Icons.replay_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 34,
                ),
              ),
            ),
          if (value.isBuffering)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: colors.accent,
                backgroundColor: colors.surfaceMuted,
              ),
            ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final previewBody = AspectRatio(
          aspectRatio: aspectRatio,
          child: preview,
        );
        final boundedPreview = constraints.maxHeight.isFinite
            ? Expanded(child: Center(child: previewBody))
            : previewBody;

        return MeshSurface(
          padding: EdgeInsets.zero,
          tone: MeshSurfaceTone.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              boundedPreview,
              Padding(
                padding: controlPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: value.isPlaying
                              ? 'Pause video'
                              : 'Play video',
                          onPressed: _togglePlayback,
                          icon: Icon(
                            value.isPlaying
                                ? Icons.pause_rounded
                                : value.isCompleted
                                ? Icons.replay_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                            style: monoStyle(
                              color: colors.textSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        MeshPill(label: mimeLabel, mono: true),
                      ],
                    ),
                    VideoProgressIndicator(
                      controller,
                      allowScrubbing: true,
                      colors: VideoProgressColors(
                        playedColor: colors.accent,
                        bufferedColor: colors.accentMuted,
                        backgroundColor: colors.surfaceMuted,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap the video to play or pause.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _VideoViewerLoadingState extends StatelessWidget {
  const _VideoViewerLoadingState();

  @override
  Widget build(BuildContext context) {
    return MeshSurface(
      padding: EdgeInsets.zero,
      tone: MeshSurfaceTone.surface,
      child: const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _VideoViewerErrorState extends StatelessWidget {
  const _VideoViewerErrorState({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MeshEmptyState(
      icon: Icons.error_outline_rounded,
      title: 'Could not load video',
      body: error,
    );
  }
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
