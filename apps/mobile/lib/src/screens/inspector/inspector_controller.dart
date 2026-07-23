import 'package:flutter/widgets.dart';

/// Kinds of surfaces that can be hosted in the desktop inspector pane
/// (aka pane 3). At most one surface is active at a time.
///
/// Phase A intentionally ships with just `debug` so the shell layout
/// can be exercised before any real surface is migrated. Real kinds
/// (search, fileBrowser, gitDetails, sessionDetails, ...) are added as
/// surfaces land.
enum InspectorSurfaceKind {
  browserPreview,
  debug,
  search,
  resources,
  fileBrowser,
  pinned,
  terminal,
  browserTabs,
  gitDetails,
  sessionDetails,
  sessionControls,
}

/// A single surface that the inspector pane can host.
///
/// Surfaces declare the shell-owned chrome (title, optional toolbar
/// actions) and their own [body]. The shell draws the pane frame +
/// header so individual surfaces stay focused on their own content.
class InspectorSurface {
  const InspectorSurface({
    required this.kind,
    required this.ownerKey,
    required this.title,
    required this.bodyBuilder,
    this.actionsBuilder,
    this.icon,
  });

  /// Which kind of surface this is (used for [InspectorController.toggle]
  /// de-duplication).
  final InspectorSurfaceKind kind;

  /// Identifies the owner of this surface, e.g. `"${host.id}|${session.id}"`.
  /// Used so that opening the same kind for the *same* owner toggles it
  /// closed, but opening it for a different owner replaces the current
  /// surface with a fresh one.
  final String ownerKey;

  /// Title shown in the pane header.
  final String title;

  /// Optional icon shown to the left of the title in the pane header.
  final IconData? icon;

  /// Builder for the surface body. Called inside the shell's pane frame.
  final WidgetBuilder bodyBuilder;

  /// Builder for optional toolbar actions that live in the pane header
  /// to the left of the close button.
  final List<Widget> Function(BuildContext)? actionsBuilder;

  bool matches(InspectorSurface other) =>
      kind == other.kind && ownerKey == other.ownerKey;
}

/// Owns the currently-active inspector surface, if any. Session screens
/// and other detail views call [toggle] / [show] / [close]; the desktop
/// shell listens and renders the pane accordingly.
class InspectorController extends ChangeNotifier {
  InspectorSurface? _current;
  bool _lastCloseWasUserInitiated = false;

  InspectorSurface? get current => _current;
  bool get isOpen => _current != null;

  /// Whether the last transition to a null [current] was triggered by a
  /// user-initiated [close] / [toggle] call, as opposed to a shell-driven
  /// [closeForOwner] (e.g. session switch). Used by persistence logic to
  /// distinguish "user dismissed the inspector" from "the session that
  /// owned it became inactive."
  bool get lastCloseWasUserInitiated => _lastCloseWasUserInitiated;

  /// Opens [surface], replacing any currently-visible surface.
  void show(InspectorSurface surface) {
    _current = surface;
    _lastCloseWasUserInitiated = false;
    notifyListeners();
  }

  /// Closes the pane if anything is open. User-initiated.
  void close() {
    if (_current == null) return;
    _current = null;
    _lastCloseWasUserInitiated = true;
    notifyListeners();
  }

  /// If the exact same kind+owner is already open, closes the pane.
  /// Otherwise replaces whatever is open with [surface].
  void toggle(InspectorSurface surface) {
    final active = _current;
    if (active != null && active.matches(surface)) {
      close();
      return;
    }
    show(surface);
  }

  /// Closes the pane if the currently-open surface belongs to [ownerKey].
  /// Useful when a session is closed and its inspector should go with it.
  /// Shell-initiated — does not mark as user-closed.
  void closeForOwner(String ownerKey) {
    if (_current?.ownerKey != ownerKey) return;
    _current = null;
    _lastCloseWasUserInitiated = false;
    notifyListeners();
  }
}

/// Inherited scope that exposes the shell's [InspectorController] to
/// descendants. Session screens read the controller from here and call
/// `.toggle(...)` on it to open/close their inspector surfaces.
///
/// On platforms without a desktop shell (mobile), no ancestor provides
/// this scope and [maybeOf] returns null — callers should fall back to
/// their existing bottom-sheet / dialog flows in that case.
class InspectorScope extends InheritedNotifier<InspectorController> {
  const InspectorScope({
    super.key,
    required InspectorController controller,
    required super.child,
  }) : super(notifier: controller);

  static InspectorController? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<InspectorScope>();
    return scope?.notifier;
  }

  static InspectorController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(
      controller != null,
      'InspectorScope.of() called without an InspectorScope ancestor. '
      'Use InspectorScope.maybeOf(context) when a shell may not be present.',
    );
    return controller!;
  }
}
