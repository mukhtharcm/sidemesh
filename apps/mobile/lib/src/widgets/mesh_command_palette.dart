import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// A screen-wide command palette overlay.
///
/// Registered actions are fuzzy-matched against the search query and presented
/// as tappable rows. Think Raycast / Linear command palette.
///
/// ## Triggers
/// - **Long-press on [MeshStatusLine]** — pass [onLongPress] to MeshStatusLine.
/// - **`/` typed into an empty composer** — detect in composer and call
///   [MeshCommandPaletteOverlay.show].
/// - **`⌘K` / `Ctrl+K`** — register via [MeshCommandPaletteScope].
///
/// ## Usage
///
/// 1. Wrap your screen (or the root widget) with [MeshCommandPaletteScope].
/// 2. Register actions with `MeshCommandPaletteScope.of(context).register(...)`.
/// 3. Open with `MeshCommandPaletteScope.of(context).open()` or via the
///    MeshStatusLine long-press.
///
/// ```dart
/// // In your screen's initState or build:
/// MeshCommandPaletteScope.of(context).register([
///   MeshCommandAction(
///     id: 'session.stop',
///     label: 'Stop session',
///     icon: Icons.stop_rounded,
///     onExecute: _stopSession,
///   ),
///   MeshCommandAction(
///     id: 'theme.open',
///     label: 'Change theme',
///     icon: Icons.palette_outlined,
///     onExecute: () => _openAppearanceSheet(context),
///   ),
/// ]);
/// ```
class MeshCommandPaletteScope extends StatefulWidget {
  const MeshCommandPaletteScope({
    super.key,
    required this.child,
  });

  final Widget child;

  /// Access the [MeshCommandPaletteController] from any descendant.
  static MeshCommandPaletteController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_CommandPaletteInherited>();
    assert(scope != null,
        'MeshCommandPaletteScope not found. Wrap your widget tree with MeshCommandPaletteScope.');
    return scope!.controller;
  }

  @override
  State<MeshCommandPaletteScope> createState() =>
      _MeshCommandPaletteScopeState();
}

class _MeshCommandPaletteScopeState extends State<MeshCommandPaletteScope> {
  final _controller = MeshCommandPaletteController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _CommandPaletteInherited(
      controller: _controller,
      child: _CommandPaletteKeyboardHandler(
        controller: _controller,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, child) {
            return Stack(
              children: [
                child!,
                if (_controller.isOpen)
                  _MeshCommandPaletteOverlay(controller: _controller),
              ],
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Exposes [open], [close], and [register] to any descendant widget.
class MeshCommandPaletteController extends ChangeNotifier {
  final List<MeshCommandAction> _actions = [];
  bool _open = false;

  bool get isOpen => _open;
  List<MeshCommandAction> get actions => List.unmodifiable(_actions);

  /// Register a set of actions for the current screen. Typically called in
  /// a screen's [State.initState] or [State.didChangeDependencies].
  /// Pass an empty list to clear screen-specific actions.
  void register(List<MeshCommandAction> actions) {
    _actions
      ..clear()
      ..addAll(actions);
    notifyListeners();
  }

  void open() {
    if (_open) return;
    _open = true;
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    notifyListeners();
  }

  void toggle() => _open ? close() : open();
}

/// A single action registered in the command palette.
class MeshCommandAction {
  const MeshCommandAction({
    required this.id,
    required this.label,
    required this.onExecute,
    this.icon,
    this.sublabel,
    this.section,
    this.shortcut,
  });

  /// Stable identifier (e.g. 'session.stop', 'theme.open').
  final String id;
  final String label;
  final VoidCallback onExecute;
  final IconData? icon;

  /// Optional description shown below the label.
  final String? sublabel;

  /// Logical group (e.g. 'Session', 'Navigate', 'Desktop'). Used to group
  /// results when there is no active search query.
  final String? section;

  /// Human-readable shortcut hint (e.g. '⌘T').
  final String? shortcut;
}

// ---------------------------------------------------------------------------
// Internal widgets
// ---------------------------------------------------------------------------

class _CommandPaletteInherited extends InheritedWidget {
  const _CommandPaletteInherited({
    required this.controller,
    required super.child,
  });

  final MeshCommandPaletteController controller;

  @override
  bool updateShouldNotify(_CommandPaletteInherited old) =>
      controller != old.controller;
}

/// Handles ⌘K / Ctrl+K keyboard shortcut.
class _CommandPaletteKeyboardHandler extends StatelessWidget {
  const _CommandPaletteKeyboardHandler({
    required this.controller,
    required this.child,
  });

  final MeshCommandPaletteController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode(skipTraversal: true),
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        final isCmd = HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed;
        if (isCmd && event.logicalKey == LogicalKeyboardKey.keyK) {
          HapticFeedback.lightImpact();
          controller.toggle();
        }
        if (event.logicalKey == LogicalKeyboardKey.escape &&
            controller.isOpen) {
          controller.close();
        }
      },
      child: child,
    );
  }
}

class _MeshCommandPaletteOverlay extends StatefulWidget {
  const _MeshCommandPaletteOverlay({required this.controller});

  final MeshCommandPaletteController controller;

  @override
  State<_MeshCommandPaletteOverlay> createState() =>
      _MeshCommandPaletteOverlayState();
}

class _MeshCommandPaletteOverlayState
    extends State<_MeshCommandPaletteOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  final _queryController = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..forward();
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));

    _queryController.addListener(() {
      setState(() => _query = _queryController.text);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _queryController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _close() {
    _anim.reverse().then((_) => widget.controller.close());
  }

  void _execute(MeshCommandAction action) {
    HapticFeedback.selectionClick();
    _close();
    // Execute after palette closes so the action's UI has the full stage.
    Future.microtask(action.onExecute);
  }

  List<MeshCommandAction> _filtered() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.controller.actions;
    return widget.controller.actions.where((a) {
      return _fuzzyMatch(q, a.label.toLowerCase()) ||
          (a.sublabel != null && _fuzzyMatch(q, a.sublabel!.toLowerCase())) ||
          (a.section != null && _fuzzyMatch(q, a.section!.toLowerCase()));
    }).toList();
  }

  static bool _fuzzyMatch(String query, String target) {
    if (target.contains(query)) return true;
    var qi = 0;
    for (var i = 0; i < target.length && qi < query.length; i++) {
      if (target[i] == query[qi]) qi++;
    }
    return qi == query.length;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final filtered = _filtered();
    final mq = MediaQuery.of(context);

    return GestureDetector(
      onTap: _close,
      child: Material(
        color: Colors.transparent,
        child: Container(
          color: colors.canvas.withValues(alpha: 0.7),
          child: SafeArea(
            child: Align(
              alignment: const Alignment(0, -0.3),
              child: GestureDetector(
                onTap: () {}, // absorb taps inside palette
                child: FadeTransition(
                  opacity: _fade,
                  child: SlideTransition(
                    position: _slide,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 560,
                        maxHeight: mq.size.height * 0.65,
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surfaceElevated,
                          borderRadius: AppShapes.card,
                          border: Border.all(color: colors.borderStrong),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.32),
                              blurRadius: 32,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _SearchField(
                              controller: _queryController,
                              focusNode: _focusNode,
                              colors: colors,
                              onClose: _close,
                            ),
                            Divider(height: 1, color: colors.border),
                            Flexible(
                              child: _ResultsList(
                                actions: filtered,
                                query: _query,
                                colors: colors,
                                onExecute: _execute,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.colors,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final AppColors colors;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: colors.textTertiary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 15,
                fontWeight: AppWeights.body,
              ),
              decoration: InputDecoration(
                hintText: 'Search commands…',
                hintStyle: TextStyle(
                  color: colors.textTertiary,
                  fontSize: 15,
                  fontWeight: AppWeights.body,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                fillColor: Colors.transparent,
                filled: true,
              ),
              textInputAction: TextInputAction.search,
              autofocus: true,
            ),
          ),
          GestureDetector(
            onTap: onClose,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: colors.border),
              ),
              child: Text(
                'esc',
                style: TextStyle(
                  color: colors.textTertiary,
                  fontSize: 11,
                  fontWeight: AppWeights.emphasis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({
    required this.actions,
    required this.query,
    required this.colors,
    required this.onExecute,
  });

  final List<MeshCommandAction> actions;
  final String query;
  final AppColors colors;
  final void Function(MeshCommandAction) onExecute;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          'No commands matching "$query"',
          style: TextStyle(
            color: colors.textTertiary,
            fontSize: 13,
            fontWeight: AppWeights.body,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    // Group by section when no query is active.
    if (query.trim().isEmpty) {
      final sections = <String, List<MeshCommandAction>>{};
      for (final a in actions) {
        (sections[a.section ?? ''] ??= []).add(a);
      }
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: [
          for (final entry in sections.entries) ...[
            if (entry.key.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  2,
                ),
                child: Text(
                  entry.key.toUpperCase(),
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 10,
                    fontWeight: AppWeights.title,
                    letterSpacing: AppLetterSpacing.caps,
                  ),
                ),
              ),
            ...entry.value.map(
              (a) => _ActionRow(action: a, colors: colors, onTap: onExecute),
            ),
          ],
        ],
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      itemCount: actions.length,
      itemBuilder: (_, i) => _ActionRow(
        action: actions[i],
        colors: colors,
        onTap: onExecute,
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.colors,
    required this.onTap,
  });

  final MeshCommandAction action;
  final AppColors colors;
  final void Function(MeshCommandAction) onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onTap(action),
      hoverColor: colors.surfaceMuted,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border),
              ),
              child: Icon(
                action.icon ?? Icons.play_arrow_rounded,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    action.label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: AppWeights.emphasis,
                        ),
                  ),
                  if (action.sublabel != null)
                    Text(
                      action.sublabel!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colors.textTertiary,
                          ),
                    ),
                ],
              ),
            ),
            if (action.shortcut != null) ...[
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: colors.border),
                ),
                child: Text(
                  action.shortcut!,
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 11,
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
