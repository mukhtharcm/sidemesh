import 'terminal_selection_session.dart';

/// Shared gesture-side selection coordinator for terminal widgets.
///
/// This centralizes the selection decisions that were previously duplicated in
/// both terminal views while keeping coordinate resolution and renderer-specific
/// selection construction pluggable.
final class GhosttyTerminalGestureCoordinator<PositionT, SelectionT> {
  GhosttyTerminalGestureCoordinator(this.session);

  final GhosttyTerminalSelectionSession<SelectionT> session;

  SelectionT? beginSelection({
    required PositionT? position,
    required SelectionT Function(PositionT position) collapsedSelection,
  }) {
    if (position == null) {
      return null;
    }
    session.clearLineSelectionAnchorRow();
    return collapsedSelection(position);
  }

  SelectionT? updateSelection({
    required SelectionT? currentSelection,
    required PositionT? position,
    required SelectionT Function(
      SelectionT currentSelection,
      PositionT position,
    )
    extendSelection,
    required SelectionT? Function(int anchorRow, PositionT position)
    extendLineSelection,
  }) {
    if (currentSelection == null || position == null) {
      return null;
    }
    final anchorRow = session.lineSelectionAnchorRow;
    return anchorRow == null
        ? extendSelection(currentSelection, position)
        : extendLineSelection(anchorRow, position);
  }

  SelectionT? selectWord({
    required PositionT? position,
    required SelectionT? Function(PositionT position) resolveWordSelection,
  }) {
    if (position == null) {
      return null;
    }
    final selection = resolveWordSelection(position);
    if (selection != null) {
      session.armIgnoreNextTapClear();
    }
    return selection;
  }

  SelectionT? beginLineSelection({
    required PositionT? position,
    required int Function(PositionT position) rowOfPosition,
    required SelectionT? Function(PositionT position) resolveLineSelection,
  }) {
    if (position == null) {
      return null;
    }
    final selection = resolveLineSelection(position);
    if (selection == null) {
      return null;
    }
    session.setLineSelectionAnchorRow(rowOfPosition(position));
    return selection;
  }

  SelectionT? completeWordSelection({
    required PositionT? position,
    required SelectionT? Function(PositionT position) resolveWordSelection,
  }) {
    session.resetIgnoreNextTapClear();
    if (position == null) {
      return null;
    }
    return resolveWordSelection(position);
  }
}
