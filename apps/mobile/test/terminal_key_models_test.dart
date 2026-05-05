import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:sidemesh_mobile/src/terminal_key_models.dart';

void main() {
  group('TerminalKeyAction', () {
    test('serialises and deserialises a key action with modifiers', () {
      const action = TerminalKeyAction(
        label: 'Ctrl+C',
        key: xterm.TerminalKey.keyC,
        ctrl: true,
      );
      final json = action.toJson();
      final restored = TerminalKeyAction.fromJson(json);

      expect(restored.label, 'Ctrl+C');
      expect(restored.key, xterm.TerminalKey.keyC);
      expect(restored.ctrl, true);
      expect(restored.alt, false);
      expect(restored.shift, false);
      expect(restored.rawText, null);
    });

    test('serialises and deserialises a raw text action', () {
      const action = TerminalKeyAction(label: '|', rawText: '|');
      final json = action.toJson();
      final restored = TerminalKeyAction.fromJson(json);

      expect(restored.label, '|');
      expect(restored.key, null);
      expect(restored.rawText, '|');
    });

    test('round-trips all modifier flags', () {
      const action = TerminalKeyAction(
        label: 'Shift+Ctrl+A',
        key: xterm.TerminalKey.keyA,
        ctrl: true,
        shift: true,
      );
      final restored = TerminalKeyAction.fromJson(action.toJson());
      expect(restored.ctrl, true);
      expect(restored.shift, true);
      expect(restored.alt, false);
    });
  });

  group('TerminalKeyCategory', () {
    test('serialises and deserialises a category', () {
      const category = TerminalKeyCategory(
        id: 'nav',
        label: 'Nav',
        actions: [
          TerminalKeyAction(label: 'Esc', key: xterm.TerminalKey.escape),
          TerminalKeyAction(label: '↑', key: xterm.TerminalKey.arrowUp),
        ],
      );
      final json = category.toJson();
      final restored = TerminalKeyCategory.fromJson(json);

      expect(restored.id, 'nav');
      expect(restored.label, 'Nav');
      expect(restored.actions.length, 2);
      expect(restored.actions[0].label, 'Esc');
      expect(restored.actions[0].key, xterm.TerminalKey.escape);
    });
  });

  group('defaultTerminalKeyCategories', () {
    test('provides at least five categories', () {
      final categories = defaultTerminalKeyCategories();
      expect(categories.length, greaterThanOrEqualTo(5));
    });

    test('nav category includes escape and arrows', () {
      final nav = defaultTerminalKeyCategories().firstWhere((c) => c.id == 'nav');
      final labels = nav.actions.map((a) => a.label).toList();
      expect(labels, contains('Esc'));
      expect(labels, contains('↑'));
      expect(labels, contains('↓'));
      expect(labels, contains('←'));
      expect(labels, contains('→'));
    });

    test('combo category includes ctrl combos', () {
      final combo = defaultTerminalKeyCategories().firstWhere((c) => c.id == 'combo');
      final labels = combo.actions.map((a) => a.label).toList();
      expect(labels, contains('Ctrl+C'));
      expect(labels, contains('Ctrl+D'));
      expect(labels, contains('Ctrl+Z'));
    });

    test('sym category includes pipe and backslash', () {
      final sym = defaultTerminalKeyCategories().firstWhere((c) => c.id == 'sym');
      final labels = sym.actions.map((a) => a.label).toList();
      expect(labels, contains('|'));
      expect(labels, contains(r'\'));
    });

    test('fn category includes all twelve F keys', () {
      final fn = defaultTerminalKeyCategories().firstWhere((c) => c.id == 'fn');
      expect(fn.actions.length, 12);
      for (var i = 1; i <= 12; i++) {
        expect(fn.actions.any((a) => a.label == 'F$i'), true);
      }
    });
  });
}
