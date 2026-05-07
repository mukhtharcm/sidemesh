import 'dart:async';

import 'package:flutter/foundation.dart';

/// A lightweight process-wide ticker for relative-time labels.
///
/// Widgets that display relative timestamps can wrap just the text
/// portion in a [ListenableBuilder] driven by one of these instances. The
/// timers only run while at least one listener is attached.
class RelativeTimeTicker extends ChangeNotifier {
  RelativeTimeTicker._(this._interval);

  /// Default to minute-level ticks for list and status surfaces.
  static final RelativeTimeTicker instance = minutes;
  static final RelativeTimeTicker minutes = RelativeTimeTicker._(
    const Duration(minutes: 1),
  );
  static final RelativeTimeTicker seconds = RelativeTimeTicker._(
    const Duration(seconds: 1),
  );

  final Duration _interval;

  Timer? _timer;
  int _listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    if (_timer == null) {
      _scheduleNextTick();
      // Fire immediately so the first frame is correct.
      notifyListeners();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount--;
    if (_listenerCount <= 0) {
      _timer?.cancel();
      _timer = null;
      _listenerCount = 0;
    }
  }

  void _scheduleNextTick() {
    _timer?.cancel();
    if (_listenerCount <= 0) {
      return;
    }
    _timer = Timer(_nextDelay(), () {
      if (_listenerCount <= 0) {
        return;
      }
      notifyListeners();
      _scheduleNextTick();
    });
  }

  Duration _nextDelay() {
    if (_interval == const Duration(minutes: 1)) {
      final now = DateTime.now();
      final elapsedMs = now.second * 1000 + now.millisecond;
      final nextMinuteMs = 60000 - elapsedMs;
      return Duration(milliseconds: nextMinuteMs == 0 ? 60000 : nextMinuteMs);
    }
    return _interval;
  }
}
