import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../theme/app_control_styles.dart';

/// Shows a notice near the top of the window, clear of composer controls. Runs through the root [Overlay] so
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
    final accessibleAction =
        toast.action != null &&
        (MediaQuery.maybeOf(toast.overlay.context)?.accessibleNavigation ??
            false);
    if (!accessibleAction) {
      autoDismissTimer = Timer(toast.duration, controller.dismiss);
    }
  }

  void _dropStaleQueuedToasts() {
    _queue.removeWhere((toast) => !toast.overlay.mounted);
  }
}

class _QueuedToast {
  const _QueuedToast({
    required this.overlay,
    required this.message,
    required this.duration,
    required this.action,
  });
  final OverlayState overlay;
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
    required this.message,
    required this.onDismiss,
    required this.onDisposed,
    this.action,
  });

  final _ToastController controller;
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
    duration: AppMotion.reveal,
    reverseDuration: AppMotion.quick,
  );
  bool _dismissing = false;
  bool _completed = false;
  late final Animation<double> _fade = CurvedAnimation(
    parent: _anim,
    curve: AppMotion.standard,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    if (widget.controller.dismissed) {
      // A short-lived toast can be dismissed by its timer before this overlay
      // gets its first frame. The controller notification is then already
      // over, so checking the current value is required to avoid leaving an
      // undismissable overlay behind.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _completeDismiss();
        }
      });
    } else {
      _anim.forward();
    }
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
    final desktop = AppSizes.usesPointerControls(theme.platform);
    final snackTheme = theme.snackBarTheme;
    return Positioned(
      top: media.padding.top + (desktop ? AppSizes.control : AppSpacing.sm),
      left: AppSpacing.lg,
      right: AppSpacing.lg,
      child: FadeTransition(
        opacity: _fade,
        child: Align(
          alignment: desktop ? Alignment.topRight : Alignment.topCenter,
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Material(
              color: snackTheme.backgroundColor,
              elevation: snackTheme.elevation ?? 0,
              shape: snackTheme.shape,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: AppSizes.toastWidth,
                  maxHeight: media.size.height * 0.5,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.xs,
                    AppSpacing.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.message,
                          style: snackTheme.contentTextStyle,
                        ),
                      ),
                      if (widget.action != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        TextButton(
                          onPressed: () {
                            widget.action!.onPressed();
                            widget.controller.dismiss();
                          },
                          style: snackTheme.actionTextColor == null
                              ? null
                              : AppControlStyles.foreground(
                                  snackTheme.actionTextColor!,
                                ),
                          child: Text(widget.action!.label),
                        ),
                      ],
                      const SizedBox(width: AppSpacing.xs),
                      IconButton(
                        tooltip: 'Dismiss',
                        iconSize: AppSizes.compactIcon,
                        onPressed: _ToastQueue.instance.clear,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
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
