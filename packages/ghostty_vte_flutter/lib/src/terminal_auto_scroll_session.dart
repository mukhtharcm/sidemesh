import 'dart:async';
import 'dart:ui';

/// Shared mutable auto-scroll session state for terminal widgets.
///
/// This keeps the timer and drag/layout context needed by selection auto-scroll
/// flows while allowing each renderer to keep its own coordinate math.
final class GhosttyTerminalAutoScrollSession<MetricsT> {
  Timer? _timer;
  Offset? _dragPosition;
  Size? _layoutSize;
  MetricsT? _metrics;
  int _direction = 0;

  Offset? get dragPosition => _dragPosition;
  Size? get layoutSize => _layoutSize;
  MetricsT? get metrics => _metrics;
  int get direction => _direction;
  bool get isActive => _timer != null;

  void updateLayout({required Size layoutSize, required MetricsT metrics}) {
    _layoutSize = layoutSize;
    _metrics = metrics;
  }

  void updateDragPosition(Offset? dragPosition) {
    _dragPosition = dragPosition;
  }

  void updateDirection(int direction) {
    _direction = direction;
  }

  void ensureTimer(Duration period, void Function() onTick) {
    _timer ??= Timer.periodic(period, (_) => onTick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _dragPosition = null;
    _direction = 0;
  }

  void reset() {
    stop();
    _layoutSize = null;
    _metrics = null;
  }
}
