import 'dart:async';

import 'package:flutter/foundation.dart';

/// A lightweight process-wide ticker that fires once per second so
/// relative-time labels (e.g. "last connected 12s ago") stay fresh
/// without every widget running its own [Timer.periodic].
///
/// Widgets that display relative timestamps can wrap just the text
/// portion in a [ListenableBuilder] driven by this instance.  The timer
/// only runs while at least one listener is attached.
class RelativeTimeTicker extends ChangeNotifier {
  RelativeTimeTicker._();
  static final RelativeTimeTicker instance = RelativeTimeTicker._();

  Timer? _timer;
  int _listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    if (_timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        notifyListeners();
      });
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
}
