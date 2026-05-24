import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart' as xterm;

@immutable
class TerminalKeyAction {
  const TerminalKeyAction({
    required this.label,
    this.key,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.rawText,
  }) : assert(
         key != null || rawText != null,
         'Either key or rawText must be provided',
       );

  final String label;
  final xterm.TerminalKey? key;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final String? rawText;

  bool get hasModifiers => ctrl || alt || shift;

  Map<String, Object?> toJson() => {
    'label': label,
    if (key != null) 'key': key!.name,
    'ctrl': ctrl,
    'alt': alt,
    'shift': shift,
    if (rawText != null) 'rawText': rawText,
  };

  factory TerminalKeyAction.fromJson(Map<String, dynamic> json) {
    return TerminalKeyAction(
      label: json['label'] as String,
      key: json['key'] != null
          ? xterm.TerminalKey.values.byName(json['key'] as String)
          : null,
      ctrl: json['ctrl'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
      rawText: json['rawText'] as String?,
    );
  }
}

@immutable
class TerminalKeyCategory {
  const TerminalKeyCategory({
    required this.id,
    required this.label,
    required this.actions,
  });

  final String id;
  final String label;
  final List<TerminalKeyAction> actions;

  Map<String, Object> toJson() => {
    'id': id,
    'label': label,
    'actions': actions.map((a) => a.toJson()).toList(),
  };

  factory TerminalKeyCategory.fromJson(Map<String, dynamic> json) {
    return TerminalKeyCategory(
      id: json['id'] as String,
      label: json['label'] as String,
      actions: (json['actions'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(TerminalKeyAction.fromJson)
          .toList(),
    );
  }
}

List<TerminalKeyCategory> defaultTerminalKeyCategories() => [
  const TerminalKeyCategory(
    id: 'nav',
    label: 'Navigation',
    actions: [
      TerminalKeyAction(label: 'Esc', key: xterm.TerminalKey.escape),
      TerminalKeyAction(label: 'Tab', key: xterm.TerminalKey.tab),
      TerminalKeyAction(label: 'Enter', key: xterm.TerminalKey.enter),
      TerminalKeyAction(label: 'Space', key: xterm.TerminalKey.space),
      TerminalKeyAction(label: 'Home', key: xterm.TerminalKey.home),
      TerminalKeyAction(label: 'End', key: xterm.TerminalKey.end),
      TerminalKeyAction(label: 'PgUp', key: xterm.TerminalKey.pageUp),
      TerminalKeyAction(label: 'PgDn', key: xterm.TerminalKey.pageDown),
      TerminalKeyAction(label: '↑', key: xterm.TerminalKey.arrowUp),
      TerminalKeyAction(label: '↓', key: xterm.TerminalKey.arrowDown),
      TerminalKeyAction(label: '←', key: xterm.TerminalKey.arrowLeft),
      TerminalKeyAction(label: '→', key: xterm.TerminalKey.arrowRight),
      TerminalKeyAction(label: 'BS', key: xterm.TerminalKey.backspace),
      TerminalKeyAction(label: 'Del', key: xterm.TerminalKey.delete),
    ],
  ),
  const TerminalKeyCategory(
    id: 'edit',
    label: 'Edit',
    actions: [
      TerminalKeyAction(
        label: 'Ctrl+A',
        key: xterm.TerminalKey.keyA,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+E',
        key: xterm.TerminalKey.keyE,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+U',
        key: xterm.TerminalKey.keyU,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+K',
        key: xterm.TerminalKey.keyK,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+W',
        key: xterm.TerminalKey.keyW,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+Y',
        key: xterm.TerminalKey.keyY,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+P',
        key: xterm.TerminalKey.keyP,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+N',
        key: xterm.TerminalKey.keyN,
        ctrl: true,
      ),
      TerminalKeyAction(label: 'Home', key: xterm.TerminalKey.home),
      TerminalKeyAction(label: 'End', key: xterm.TerminalKey.end),
    ],
  ),
  const TerminalKeyCategory(
    id: 'letters',
    label: 'Letters',
    actions: [
      TerminalKeyAction(label: 'A', key: xterm.TerminalKey.keyA),
      TerminalKeyAction(label: 'B', key: xterm.TerminalKey.keyB),
      TerminalKeyAction(label: 'C', key: xterm.TerminalKey.keyC),
      TerminalKeyAction(label: 'D', key: xterm.TerminalKey.keyD),
      TerminalKeyAction(label: 'E', key: xterm.TerminalKey.keyE),
      TerminalKeyAction(label: 'F', key: xterm.TerminalKey.keyF),
      TerminalKeyAction(label: 'G', key: xterm.TerminalKey.keyG),
      TerminalKeyAction(label: 'H', key: xterm.TerminalKey.keyH),
      TerminalKeyAction(label: 'I', key: xterm.TerminalKey.keyI),
      TerminalKeyAction(label: 'J', key: xterm.TerminalKey.keyJ),
      TerminalKeyAction(label: 'K', key: xterm.TerminalKey.keyK),
      TerminalKeyAction(label: 'L', key: xterm.TerminalKey.keyL),
      TerminalKeyAction(label: 'M', key: xterm.TerminalKey.keyM),
      TerminalKeyAction(label: 'N', key: xterm.TerminalKey.keyN),
      TerminalKeyAction(label: 'O', key: xterm.TerminalKey.keyO),
      TerminalKeyAction(label: 'P', key: xterm.TerminalKey.keyP),
      TerminalKeyAction(label: 'Q', key: xterm.TerminalKey.keyQ),
      TerminalKeyAction(label: 'R', key: xterm.TerminalKey.keyR),
      TerminalKeyAction(label: 'S', key: xterm.TerminalKey.keyS),
      TerminalKeyAction(label: 'T', key: xterm.TerminalKey.keyT),
      TerminalKeyAction(label: 'U', key: xterm.TerminalKey.keyU),
      TerminalKeyAction(label: 'V', key: xterm.TerminalKey.keyV),
      TerminalKeyAction(label: 'W', key: xterm.TerminalKey.keyW),
      TerminalKeyAction(label: 'X', key: xterm.TerminalKey.keyX),
      TerminalKeyAction(label: 'Y', key: xterm.TerminalKey.keyY),
      TerminalKeyAction(label: 'Z', key: xterm.TerminalKey.keyZ),
    ],
  ),
  const TerminalKeyCategory(
    id: 'ctrl',
    label: 'Shortcuts',
    actions: [
      TerminalKeyAction(
        label: 'Ctrl+C',
        key: xterm.TerminalKey.keyC,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+D',
        key: xterm.TerminalKey.keyD,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+Z',
        key: xterm.TerminalKey.keyZ,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+L',
        key: xterm.TerminalKey.keyL,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+R',
        key: xterm.TerminalKey.keyR,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+S',
        key: xterm.TerminalKey.keyS,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+Q',
        key: xterm.TerminalKey.keyQ,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+G',
        key: xterm.TerminalKey.keyG,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+X',
        key: xterm.TerminalKey.keyX,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+V',
        key: xterm.TerminalKey.keyV,
        ctrl: true,
      ),
      TerminalKeyAction(
        label: 'Ctrl+O',
        key: xterm.TerminalKey.keyO,
        ctrl: true,
      ),
    ],
  ),
  const TerminalKeyCategory(
    id: 'sym',
    label: 'Symbols',
    actions: [
      TerminalKeyAction(label: '|', rawText: '|'),
      TerminalKeyAction(label: '~', rawText: '~'),
      TerminalKeyAction(label: r'$', rawText: r'$'),
      TerminalKeyAction(label: '`', rawText: '`'),
      TerminalKeyAction(label: r'\', rawText: r'\'),
      TerminalKeyAction(label: '&', rawText: '&'),
      TerminalKeyAction(label: '!', rawText: '!'),
      TerminalKeyAction(label: '#', rawText: '#'),
      TerminalKeyAction(label: '*', rawText: '*'),
      TerminalKeyAction(label: '(', rawText: '('),
      TerminalKeyAction(label: ')', rawText: ')'),
      TerminalKeyAction(label: '{', rawText: '{'),
      TerminalKeyAction(label: '}', rawText: '}'),
      TerminalKeyAction(label: '[', rawText: '['),
      TerminalKeyAction(label: ']', rawText: ']'),
      TerminalKeyAction(label: ':', rawText: ':'),
      TerminalKeyAction(label: ';', rawText: ';'),
      TerminalKeyAction(label: '<', rawText: '<'),
      TerminalKeyAction(label: '>', rawText: '>'),
      TerminalKeyAction(label: '"', rawText: '"'),
      TerminalKeyAction(label: "'", rawText: "'"),
      TerminalKeyAction(label: '/', rawText: '/'),
      TerminalKeyAction(label: '?', rawText: '?'),
      TerminalKeyAction(label: '-', rawText: '-'),
      TerminalKeyAction(label: '_', rawText: '_'),
      TerminalKeyAction(label: '+', rawText: '+'),
      TerminalKeyAction(label: '=', rawText: '='),
      TerminalKeyAction(label: '%', rawText: '%'),
      TerminalKeyAction(label: '^', rawText: '^'),
      TerminalKeyAction(label: '@', rawText: '@'),
    ],
  ),
  const TerminalKeyCategory(
    id: 'fn',
    label: 'Function',
    actions: [
      TerminalKeyAction(label: 'F1', key: xterm.TerminalKey.f1),
      TerminalKeyAction(label: 'F2', key: xterm.TerminalKey.f2),
      TerminalKeyAction(label: 'F3', key: xterm.TerminalKey.f3),
      TerminalKeyAction(label: 'F4', key: xterm.TerminalKey.f4),
      TerminalKeyAction(label: 'F5', key: xterm.TerminalKey.f5),
      TerminalKeyAction(label: 'F6', key: xterm.TerminalKey.f6),
      TerminalKeyAction(label: 'F7', key: xterm.TerminalKey.f7),
      TerminalKeyAction(label: 'F8', key: xterm.TerminalKey.f8),
      TerminalKeyAction(label: 'F9', key: xterm.TerminalKey.f9),
      TerminalKeyAction(label: 'F10', key: xterm.TerminalKey.f10),
      TerminalKeyAction(label: 'F11', key: xterm.TerminalKey.f11),
      TerminalKeyAction(label: 'F12', key: xterm.TerminalKey.f12),
    ],
  ),
];
