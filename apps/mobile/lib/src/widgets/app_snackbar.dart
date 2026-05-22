import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart' hide Icon, Icons, IconData;
import './app_icons.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// Shows a floating toast anchored to the bottom-right corner on wide windows
/// (desktop) and bottom-center on phones. Runs through the root [Overlay] so
/// it isn't bounded by a nested Scaffold — important in the desktop shell
/// where the session pane is nested inside another Scaffold.
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
  SnackBarAction? action,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _ToastQueue.instance.enqueue(
    overlay: overlay,
    colors: context.colors,
    message: message,
    duration: duration,
    action: action,
  );
}

class _ToastQueue {
  _ToastQueue._();
  static final _ToastQueue instance = _ToastQueue._();

  static const int _maxPending = 6;

  final Queue<_QueuedToast> _queue = Queue<_QueuedToast>();
  _ActiveToast? _active;

  int get length => _queue.length;

  void enqueue({
    required OverlayState overlay,
    required AppColors colors,
    required String message,
    required Duration duration,
    SnackBarAction? action,
  }) {
    _dropStaleQueuedToasts();
    final actionLabel = action?.label;
    if (_active != null &&
        _active!.message == message &&
        _active!.actionLabel == actionLabel) {
      return;
    }
    if (_queue.any(
      (t) => t.message == message && t.action?.label == actionLabel,
    )) {
      return;
    }
    while (_queue.length >= _maxPending) {
      _queue.removeFirst();
    }
    _queue.add(
      _QueuedToast(
        overlay: overlay,
        colors: colors,
        message: message,
        duration: duration,
        action: action,
      ),
    );
    _drain();
  }

  /// Dismiss the active toast and drop everything still queued.
  void clear() {
    _queue.clear();
    _active?.controller.dismiss();
  }

  void _drain() {
    if (_active != null) return;
    _dropStaleQueuedToasts();
    if (_queue.isEmpty) return;
    final next = _queue.removeFirst();
    _show(next);
  }

  void _show(_QueuedToast toast) {
    if (!toast.overlay.mounted) {
      _drain();
      return;
    }
    final controller = _ToastController();
    late final OverlayEntry entry;
    Timer? autoDismissTimer;
    var completed = false;
    void complete({required bool drain}) {
      if (completed) return;
      completed = true;
      autoDismissTimer?.cancel();
      if (entry.mounted) {
        entry.remove();
      }
      final active = _active;
      if (active != null && identical(active.controller, controller)) {
        _active = null;
      }
      if (toast.overlay.mounted) {
        if (drain) {
          _drain();
        }
      } else {
        _dropStaleQueuedToasts();
      }
    }

    entry = OverlayEntry(
      builder: (context) => _ToastOverlay(
        controller: controller,
        colors: toast.colors,
        message: toast.message,
        action: toast.action,
        onDismiss: () => complete(drain: true),
        onDisposed: () => complete(drain: false),
      ),
    );
    _active = _ActiveToast(
      entry: entry,
      controller: controller,
      message: toast.message,
      actionLabel: toast.action?.label,
    );
    toast.overlay.insert(entry);
    autoDismissTimer = Timer(toast.duration, () {
      controller.dismiss();
    });
  }

  void _dropStaleQueuedToasts() {
    _queue.removeWhere((toast) => !toast.overlay.mounted);
  }
}

class _QueuedToast {
  const _QueuedToast({
    required this.overlay,
    required this.colors,
    required this.message,
    required this.duration,
    required this.action,
  });
  final OverlayState overlay;
  final AppColors colors;
  final String message;
  final Duration duration;
  final SnackBarAction? action;
}

class _ActiveToast {
  _ActiveToast({
    required this.entry,
    required this.controller,
    required this.message,
    required this.actionLabel,
  });
  final OverlayEntry entry;
  final _ToastController controller;
  final String message;
  final String? actionLabel;
}

class _ToastController extends ChangeNotifier {
  bool _dismissed = false;
  bool get dismissed => _dismissed;
  void dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    notifyListeners();
  }
}

class _ToastOverlay extends StatefulWidget {
  const _ToastOverlay({
    required this.controller,
    required this.colors,
    required this.message,
    required this.onDismiss,
    required this.onDisposed,
    this.action,
  });

  final _ToastController controller;
  final AppColors colors;
  final String message;
  final SnackBarAction? action;
  final VoidCallback onDismiss;
  final VoidCallback onDisposed;

  @override
  State<_ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<_ToastOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );
  bool _dismissing = false;
  bool _completed = false;
  late final Animation<double> _fade = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _anim.forward();
  }

  void _onControllerChanged() {
    if (widget.controller.dismissed) {
      _playOut();
    }
  }

  Future<void> _playOut() async {
    if (_dismissing) return;
    _dismissing = true;
    if (!mounted) {
      _completeDismiss();
      return;
    }
    // Don't await reverse() directly — if the ticker is canceled (e.g. the
    // overlay is removed while reversing) the TickerFuture never completes and
    // the queue stalls forever.
    unawaited(_anim.reverse().catchError((_) {}));
    await Future<void>.delayed(
      _anim.reverseDuration ?? const Duration(milliseconds: 180),
    );
    if (!mounted) {
      _completeDismiss();
      return;
    }
    _completeDismiss();
  }

  void _completeDismiss() {
    if (_completed) return;
    _completed = true;
    widget.onDismiss();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _anim.dispose();
    if (!_completed) {
      _completed = true;
      widget.onDisposed();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final isWide = media.size.width > 640;
    final double right = isWide ? 20 : 12;
    final double left = isWide ? media.size.width - 440 - right : 12;
    final double bottom = isWide ? 20 : 20 + media.padding.bottom;
    final colors = widget.colors;
    return Positioned(
      left: left,
      right: right,
      bottom: bottom,
      child: IgnorePointer(
        ignoring: false,
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.35),
              end: Offset.zero,
            ).animate(_fade),
            child: Align(
              alignment: isWide
                  ? Alignment.bottomRight
                  : Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    decoration: BoxDecoration(
                      color: colors.surfaceElevated,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                      border: Border.all(color: colors.borderStrong),
                      boxShadow: [
                        BoxShadow(
                          color: colors.canvas.withValues(alpha: 0.1),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            widget.message,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                        ),
                        if (widget.action != null) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              widget.action!.onPressed();
                              widget.controller.dismiss();
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: colors.textPrimary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              minimumSize: const Size(0, 34),
                              visualDensity: VisualDensity.compact,
                              textStyle: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: Text(widget.action!.label),
                          ),
                        ],
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Dismiss',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          onPressed: _ToastQueue.instance.clear,
                          icon: Icon(
                            Icons.close_rounded,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
