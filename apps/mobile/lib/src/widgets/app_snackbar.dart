import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

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

  final Queue<_QueuedToast> _queue = Queue<_QueuedToast>();
  _ActiveToast? _active;

  void enqueue({
    required OverlayState overlay,
    required AppColors colors,
    required String message,
    required Duration duration,
    SnackBarAction? action,
  }) {
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

  void _drain() {
    if (_active != null) return;
    if (_queue.isEmpty) return;
    final next = _queue.removeFirst();
    _show(next);
  }

  void _show(_QueuedToast toast) {
    final controller = _ToastController();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _ToastOverlay(
        controller: controller,
        colors: toast.colors,
        message: toast.message,
        action: toast.action,
        onDismiss: () {
          if (entry.mounted) entry.remove();
          _active = null;
          _drain();
        },
      ),
    );
    _active = _ActiveToast(entry: entry, controller: controller);
    toast.overlay.insert(entry);
    // Auto-dismiss.
    Future<void>.delayed(toast.duration, () {
      controller.dismiss();
    });
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
  _ActiveToast({required this.entry, required this.controller});
  final OverlayEntry entry;
  final _ToastController controller;
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
    this.action,
  });

  final _ToastController controller;
  final AppColors colors;
  final String message;
  final SnackBarAction? action;
  final VoidCallback onDismiss;

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
    if (!mounted) return;
    await _anim.reverse();
    if (!mounted) return;
    widget.onDismiss();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
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
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            widget.message,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (widget.action != null) ...[
                          const SizedBox(width: 10),
                          TextButton(
                            onPressed: () {
                              widget.action!.onPressed();
                              widget.controller.dismiss();
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: colors.accent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              minimumSize: const Size(0, 32),
                              visualDensity: VisualDensity.compact,
                              textStyle: const TextStyle(
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
                          splashRadius: 16,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          onPressed: widget.controller.dismiss,
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
