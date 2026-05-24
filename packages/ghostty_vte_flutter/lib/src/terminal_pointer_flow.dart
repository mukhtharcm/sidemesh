import 'terminal_interactions.dart';
import 'terminal_selection_session.dart';

/// Shared result of resolving a terminal tap against selection and hyperlink
/// state.
typedef GhosttyTerminalTapResolution = ({
  bool clearSelection,
  String? hyperlink,
});

/// Resolves the hyperlink hover state for an optional terminal position.
bool ghosttyTerminalUpdateHoveredLink<PositionT, SelectionT>({
  required GhosttyTerminalSelectionSession<SelectionT> session,
  required PositionT? position,
  required String? Function(PositionT position) resolveUri,
}) {
  final hyperlink = ghosttyTerminalResolveHyperlinkAt<PositionT>(
    position,
    resolveUri: resolveUri,
  );
  return session.updateHoveredHyperlink(hyperlink);
}

/// Clears hovered hyperlink state and reports whether the state changed.
bool ghosttyTerminalClearHoveredLink<SelectionT>({
  required GhosttyTerminalSelectionSession<SelectionT> session,
}) {
  return session.clearHoveredHyperlink();
}

/// Resolves the shared tap behavior for a terminal view.
///
/// This centralizes the common decision tree used by both terminal widgets:
/// a tap may be ignored after word selection, may open a hyperlink, or may
/// clear the current selection.
GhosttyTerminalTapResolution ghosttyTerminalResolveTap<PositionT, SelectionT>({
  required GhosttyTerminalSelectionSession<SelectionT> session,
  required SelectionT? selection,
  required PositionT? position,
  required String? Function(PositionT position) resolveUri,
}) {
  if (session.consumeIgnoreNextTapClear()) {
    return (clearSelection: false, hyperlink: null);
  }
  final hyperlink = ghosttyTerminalResolveHyperlinkAt<PositionT>(
    position,
    resolveUri: resolveUri,
  );
  return (
    clearSelection: hyperlink == null && selection != null,
    hyperlink: hyperlink,
  );
}
