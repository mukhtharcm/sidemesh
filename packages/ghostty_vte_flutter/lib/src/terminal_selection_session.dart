import 'terminal_interactions.dart';

/// Shared mutable selection state for terminal widgets.
///
/// This owns the small interaction state machine that both terminal views
/// currently share: active selection, hovered hyperlink, the line-selection
/// anchor row, and the one-shot tap-clear guard used after word selection.
final class GhosttyTerminalSelectionSession<SelectionT> {
  SelectionT? _selection;
  String? _hoveredHyperlink;
  int? _lineSelectionAnchorRow;
  bool _ignoreNextTapClear = false;

  SelectionT? get selection => _selection;
  String? get hoveredHyperlink => _hoveredHyperlink;
  int? get lineSelectionAnchorRow => _lineSelectionAnchorRow;
  bool get hasSelection => _selection != null;

  bool updateSelection(SelectionT? nextSelection) {
    if (_selection == nextSelection) {
      return false;
    }
    _selection = nextSelection;
    return true;
  }

  void clearSelection() {
    _selection = null;
  }

  bool updateHoveredHyperlink(String? uri) {
    final normalized = ghosttyTerminalNormalizedHyperlink(uri);
    if (_hoveredHyperlink == normalized) {
      return false;
    }
    _hoveredHyperlink = normalized;
    return true;
  }

  bool clearHoveredHyperlink() {
    if (_hoveredHyperlink == null) {
      return false;
    }
    _hoveredHyperlink = null;
    return true;
  }

  void setLineSelectionAnchorRow(int? row) {
    _lineSelectionAnchorRow = row;
  }

  void clearLineSelectionAnchorRow() {
    _lineSelectionAnchorRow = null;
  }

  void armIgnoreNextTapClear() {
    _ignoreNextTapClear = true;
  }

  void resetIgnoreNextTapClear() {
    _ignoreNextTapClear = false;
  }

  bool consumeIgnoreNextTapClear() {
    final ignored = _ignoreNextTapClear;
    _ignoreNextTapClear = false;
    return ignored;
  }

  void reset() {
    _selection = null;
    _hoveredHyperlink = null;
    _lineSelectionAnchorRow = null;
    _ignoreNextTapClear = false;
  }
}
