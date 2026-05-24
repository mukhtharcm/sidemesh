import 'package:flutter/foundation.dart';

/// Minimal controller surface shared by terminal view implementations.
///
/// This intentionally stays focused on session I/O and viewport sizing. It is
/// the contract both the formatter-backed controller and the UV-backed
/// controller can satisfy today without forcing a shared paint model.
abstract interface class GhosttyTerminalSessionController
    implements Listenable {
  int get revision;
  String get title;
  bool get isRunning;
  int get cols;
  int get rows;

  void resize({
    required int cols,
    required int rows,
    int cellWidthPx = 0,
    int cellHeightPx = 0,
  });
  bool write(String text, {bool sanitizePaste = false});
  bool writeBytes(List<int> bytes);
}

/// Minimal interactive render-buffer surface shared by terminal renderers.
///
/// This isolates the shared selection and hyperlink contract from the concrete
/// paint model. Current formatter snapshots and the UV screen can both satisfy
/// this surface today.
abstract interface class GhosttyTerminalInteractiveBuffer<
  PositionT,
  SelectionT
> {
  String textForSelection(SelectionT selection);
  String? hyperlinkAt(PositionT position);
  SelectionT? wordSelectionAt(PositionT position);
  SelectionT? lineSelectionBetweenRows(int startRow, int endRow);
  SelectionT? selectAllSelection();
}
