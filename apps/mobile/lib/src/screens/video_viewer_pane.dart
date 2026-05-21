import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';
import '../app_icons.dart';

class VideoViewerPane extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return _MediaKitVideoViewerPane(
        host: host,
        api: api,
        path: path,
        mimeHint: mimeHint,
        agentProvider: agentProvider,
        sessionId: sessionId,
        dense: dense,
      );
    }
    return _VideoPlayerVideoViewerPane(
      host: host,
      api: api,
      path: path,
      mimeHint: mimeHint,
      agentProvider: agentProvider,
      sessionId: sessionId,
      dense: dense,
    );
  }
}

class _VideoPlayerVideoViewerPane extends StatefulWidget {
  const _VideoPlayerVideoViewerPane({
    required this.host,
    required this.api,
    required this.path,
    required this.mimeHint,
    this.agentProvider,
    this.sessionId,
    required this.dense,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String mimeHint;
  final String? agentProvider;
  final String? sessionId;
  final bool dense;

  @override
  State<_VideoPlayerVideoViewerPane> createState() =>
      _VideoPlayerVideoViewerPaneState();
}

class _VideoPlayerVideoViewerPaneState
    extends State<_VideoPlayerVideoViewerPane> {
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
  void didUpdateWidget(covariant _VideoPlayerVideoViewerPane oldWidget) {
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
                      ? AppIcons.replay_rounded
                      : AppIcons.play_arrow_rounded,
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
                                ? AppIcons.pause_rounded
                                : value.isCompleted
                                ? AppIcons.replay_rounded
                                : AppIcons.play_arrow_rounded,
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

class _MediaKitVideoViewerPane extends StatefulWidget {
  const _MediaKitVideoViewerPane({
    required this.host,
    required this.api,
    required this.path,
    required this.mimeHint,
    this.agentProvider,
    this.sessionId,
    required this.dense,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final String mimeHint;
  final String? agentProvider;
  final String? sessionId;
  final bool dense;

  @override
  State<_MediaKitVideoViewerPane> createState() =>
      _MediaKitVideoViewerPaneState();
}

class _MediaKitVideoViewerPaneState extends State<_MediaKitVideoViewerPane> {
  Player? _player;
  VideoController? _controller;
  Object? _error;
  bool _loading = true;
  int _loadGeneration = 0;
  Duration? _seekPreviewPosition;
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant _MediaKitVideoViewerPane oldWidget) {
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
    unawaited(_disposeCurrentPlayer());
    super.dispose();
  }

  Future<void> _disposeCurrentPlayer() async {
    await _disposeSubscriptions();
    final player = _player;
    _controller = null;
    _player = null;
    await player?.dispose();
  }

  Future<void> _disposeSubscriptions() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _initialize() async {
    final generation = ++_loadGeneration;
    await _disposeCurrentPlayer();
    _seekPreviewPosition = null;
    if (!mounted || generation != _loadGeneration) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final player = Player();
    final controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        hwdec: 'no',
        enableHardwareAcceleration: false,
      ),
    );
    _player = player;
    _controller = controller;

    void repaint() {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        if (_loading && _error == null) {
          final width = player.state.width ?? 0;
          final height = player.state.height ?? 0;
          if (player.state.duration > Duration.zero ||
              (width > 0 && height > 0)) {
            _loading = false;
          }
        }
      });
    }

    _subscriptions.addAll([
      player.stream.position.listen((_) => repaint()),
      player.stream.duration.listen((_) => repaint()),
      player.stream.playing.listen((_) => repaint()),
      player.stream.completed.listen((_) => repaint()),
      player.stream.buffering.listen((_) => repaint()),
      player.stream.width.listen((_) => repaint()),
      player.stream.height.listen((_) => repaint()),
      player.stream.error.listen((message) {
        if (!mounted || generation != _loadGeneration) {
          return;
        }
        setState(() {
          _loading = false;
          _error = message;
        });
      }),
    ]);

    try {
      await player.open(
        Media(
          widget.api
              .fsBlobUri(
                widget.host,
                widget.path,
                agentProvider: widget.agentProvider,
                sessionId: widget.sessionId,
              )
              .toString(),
          httpHeaders: widget.api.authHeaders(widget.host),
        ),
        play: false,
      );
    } catch (error) {
      await _disposeCurrentPlayer();
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error;
      });
      return;
    }

    if (!mounted || generation != _loadGeneration) {
      await _disposeCurrentPlayer();
      return;
    }

    setState(() {
      _loading = false;
      _error = null;
    });
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null) {
      return;
    }
    if (player.state.playing) {
      await player.pause();
      return;
    }
    if (player.state.completed) {
      await player.seek(Duration.zero);
    }
    await player.play();
  }

  void _handleSeekChanged(double value) {
    setState(() {
      _seekPreviewPosition = Duration(milliseconds: value.round());
    });
  }

  Future<void> _handleSeekCommitted(double value) async {
    final player = _player;
    if (player == null) {
      return;
    }
    final position = Duration(milliseconds: value.round());
    setState(() {
      _seekPreviewPosition = null;
    });
    await player.seek(position);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _controller == null) {
      return const _VideoViewerLoadingState();
    }
    final player = _player;
    final controller = _controller;
    if (_error != null) {
      return _VideoViewerErrorState(
        error: friendlyError(_error ?? 'Unknown video error'),
      );
    }
    if (player == null || controller == null) {
      return const _VideoViewerLoadingState();
    }

    final state = player.state;
    final colors = context.colors;
    final controlPadding = widget.dense
        ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
        : const EdgeInsets.fromLTRB(14, 12, 14, 14);
    final width = state.width ?? 0;
    final height = state.height ?? 0;
    final aspectRatio = width > 0 && height > 0 ? width / height : 16 / 9;
    final mimeLabel = widget.mimeHint.isEmpty ? 'video' : widget.mimeHint;
    final duration = state.duration;
    final durationMs = duration.inMilliseconds;
    final position = _clampPosition(
      _seekPreviewPosition ?? state.position,
      duration,
    );
    final int positionMs = position.inMilliseconds.clamp(0, durationMs).toInt();
    final double sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final double sliderValue = positionMs
        .toDouble()
        .clamp(0.0, sliderMax)
        .toDouble();

    final preview = GestureDetector(
      onTap: _togglePlayback,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Center(
            child: Video(
              controller: controller,
              controls: NoVideoControls,
              wakelock: false,
              pauseUponEnteringBackgroundMode: false,
              resumeUponEnteringForegroundMode: false,
            ),
          ),
          if (!state.playing)
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
                  state.completed
                      ? AppIcons.replay_rounded
                      : AppIcons.play_arrow_rounded,
                  color: Colors.white,
                  size: 34,
                ),
              ),
            ),
          if (state.buffering)
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
                          tooltip: state.playing
                              ? 'Pause video'
                              : 'Play video',
                          onPressed: _togglePlayback,
                          icon: Icon(
                            state.playing
                                ? AppIcons.pause_rounded
                                : state.completed
                                ? AppIcons.replay_rounded
                                : AppIcons.play_arrow_rounded,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${_formatDuration(position)} / ${_formatDuration(duration)}',
                            style: monoStyle(
                              color: colors.textSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        MeshPill(label: mimeLabel, mono: true),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        activeTrackColor: colors.accent,
                        inactiveTrackColor: colors.surfaceMuted,
                        thumbColor: colors.accent,
                      ),
                      child: Slider(
                        min: 0,
                        max: sliderMax,
                        value: sliderValue,
                        onChanged: durationMs > 0 ? _handleSeekChanged : null,
                        onChangeEnd:
                            durationMs > 0 ? _handleSeekCommitted : null,
                      ),
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
      icon: AppIcons.error_outline_rounded,
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

Duration _clampPosition(Duration position, Duration duration) {
  if (duration <= Duration.zero) {
    return position < Duration.zero ? Duration.zero : position;
  }
  if (position < Duration.zero) {
    return Duration.zero;
  }
  if (position > duration) {
    return duration;
  }
  return position;
}
