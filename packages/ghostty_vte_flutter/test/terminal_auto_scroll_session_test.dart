import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  group('terminal auto-scroll session', () {
    test('tracks layout, drag position, and direction', () {
      final session = GhosttyTerminalAutoScrollSession<int>();

      session.updateLayout(layoutSize: const Size(640, 480), metrics: 24);
      session.updateDragPosition(const Offset(12, 34));
      session.updateDirection(-1);

      expect(session.layoutSize, const Size(640, 480));
      expect(session.metrics, 24);
      expect(session.dragPosition, const Offset(12, 34));
      expect(session.direction, -1);
    });

    test('starts and stops its timer without clearing layout context', () {
      final session = GhosttyTerminalAutoScrollSession<int>();

      session.updateLayout(layoutSize: const Size(320, 200), metrics: 12);
      session.ensureTimer(const Duration(minutes: 1), () {});

      expect(session.isActive, isTrue);

      session.stop();

      expect(session.isActive, isFalse);
      expect(session.dragPosition, isNull);
      expect(session.direction, 0);
      expect(session.layoutSize, const Size(320, 200));
      expect(session.metrics, 12);
    });

    test('reset clears timer and layout context', () {
      final session = GhosttyTerminalAutoScrollSession<int>();

      session.updateLayout(layoutSize: const Size(500, 300), metrics: 7);
      session.updateDragPosition(const Offset(2, 3));
      session.updateDirection(1);
      session.ensureTimer(const Duration(minutes: 1), () {});

      session.reset();

      expect(session.isActive, isFalse);
      expect(session.dragPosition, isNull);
      expect(session.direction, 0);
      expect(session.layoutSize, isNull);
      expect(session.metrics, isNull);
    });
  });
}
