import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

import 'keyboard_input.dart';
import 'terminal_auto_scroll_session.dart';
import 'terminal_controller.dart';
import 'terminal_gesture_coordinator.dart';
import 'terminal_interactions.dart';
import 'terminal_pointer_flow.dart';
import 'terminal_render_model.dart';
import 'terminal_snapshot.dart';
import 'terminal_selection_session.dart';

/// Paint backend used by [GhosttyTerminalView].
enum GhosttyTerminalRendererMode {
  /// Formatter/snapshot-driven painting. This remains the default because it
  /// currently gives the best fidelity for dense TUIs and scrollback content.
  formatter,

  /// Native Ghostty render-state painting for the live viewport.
  ///
  /// This is useful for exercising the newer screen/render APIs without making
  /// it the default path until feature parity is tighter.
  renderState,
}

/// Resolves conflicts between text selection and terminal mouse reporting.
enum GhosttyTerminalInteractionPolicy {
  /// Prefer normal terminal text interactions unless Ghostty mouse reporting is
  /// enabled by the running application.
  auto,

  /// Always prefer Flutter-side text selection, hover, and local viewport
  /// scrolling even if the terminal enables mouse reporting.
  selectionFirst,

  /// Always prefer terminal mouse reporting and suppress Flutter-side
  /// selection, hyperlink activation, and local wheel scrolling.
  terminalMouseFirst,
}

/// Controls how finger drags behave on touch screens.
enum GhosttyTerminalTouchDragBehavior {
  /// Finger drags scroll the terminal transcript; long-press selects text.
  scroll,

  /// Finger drags select text, matching mouse drag behavior.
  selection,
}

/// Builds context-menu buttons for an active terminal text selection.
typedef GhosttyTerminalSelectionContextMenuButtonItemsBuilder =
    List<ContextMenuButtonItem> Function(
      GhosttyTerminalSelectionContextMenuDetails details,
    );

/// Context passed to [GhosttyTerminalSelectionContextMenuButtonItemsBuilder].
final class GhosttyTerminalSelectionContextMenuDetails {
  const GhosttyTerminalSelectionContextMenuDetails({
    required this.selection,
    required this.selectedText,
    required this.defaultButtonItems,
    required this.copySelection,
    required this.selectAll,
    required this.hideToolbar,
  });

  /// Active terminal cell selection.
  final GhosttyTerminalSelection selection;

  /// Plain text resolved from [selection] using the view's copy options.
  final String selectedText;

  /// Default Copy and Select All buttons used by [GhosttyTerminalView].
  final List<ContextMenuButtonItem> defaultButtonItems;

  /// Copies [selectedText] using the view's configured copy behavior.
  final VoidCallback copySelection;

  /// Replaces the current selection with the full terminal transcript.
  final VoidCallback selectAll;

  /// Hides the currently visible selection toolbar.
  final VoidCallback hideToolbar;
}

const double _terminalHeaderHeight = 28.0;
const Set<PointerDeviceKind> _mouseLikePointerDevices = <PointerDeviceKind>{
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.unknown,
};
const Set<PointerDeviceKind> _touchPointerDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
};
const double _selectionHandleTouchExtent = 44.0;
const double _selectionHandleVisualRadius = 5.5;
const double _selectionHandleStemHeight = 10.0;
const Key _selectionStartHandleKey = ValueKey<String>(
  'ghostty-terminal-selection-start-handle',
);
const Key _selectionEndHandleKey = ValueKey<String>(
  'ghostty-terminal-selection-end-handle',
);

enum _TerminalSelectionHandleEdge { start, end }

/// Painter-based terminal widget that renders lines from [GhosttyTerminalController].
///
/// The controller now keeps a real [VtTerminal] alive, and this widget sizes
/// that VT grid to the available layout while rendering styled VT formatter
/// snapshots with lightweight Flutter painting.
class GhosttyTerminalView extends StatefulWidget {
  const GhosttyTerminalView({
    required this.controller,
    super.key,
    this.autofocus = false,
    this.showHeader = true,
    this.showVerticalScrollbar = false,
    this.scrollController,
    this.scrollPhysics,
    this.autoFollowOnActivity = false,
    this.focusOnInteraction = true,
    this.onTapTerminal,
    this.focusNode,
    this.backgroundColor = const Color(0xFF0A0F14),
    this.foregroundColor = const Color(0xFFE6EDF3),
    this.chromeColor = const Color(0xFF121A24),
    this.fontSize = 14,
    this.lineHeight = 1.35,
    this.fontFamily,
    this.fontFamilyFallback,
    this.fontPackage,
    this.letterSpacing = 0,
    this.cellWidthScale = 1,
    this.renderer = GhosttyTerminalRendererMode.formatter,
    this.padding = const EdgeInsets.all(12),
    this.palette = GhosttyTerminalPalette.xterm,
    this.cursorColor = const Color(0xFF9AD1C0),
    this.selectionColor = const Color(0x665DA9FF),
    this.hyperlinkColor = const Color(0xFF61AFEF),
    this.copyOptions = const GhosttyTerminalCopyOptions(),
    this.wordBoundaryPolicy = const GhosttyTerminalWordBoundaryPolicy(),
    this.selectionAutoScrollEdgeInset = 28,
    this.showSelectionContextMenu = true,
    this.selectionContextMenuButtonItemsBuilder,
    this.scrollbarThickness = 10,
    this.scrollbarMinThumbExtent = 24,
    this.scrollbarThumbColor = const Color(0x66FFFFFF),
    this.scrollbarTrackColor = const Color(0x22000000),
    this.interactionPolicy = GhosttyTerminalInteractionPolicy.auto,
    this.touchDragBehavior = GhosttyTerminalTouchDragBehavior.scroll,
    this.onSelectionChanged,
    this.onSelectionContentChanged,
    this.onCopySelection,
    this.onPasteRequest,
    this.onOpenHyperlink,
  });

  /// Session controller that owns the live VT terminal and process transport.
  final GhosttyTerminalController controller;

  /// Whether the view should request focus automatically when inserted.
  final bool autofocus;

  /// Whether to paint the terminal header/chrome row above the grid.
  final bool showHeader;

  /// Whether to show a local vertical scrollbar for transcript scrolling.
  final bool showVerticalScrollbar;

  /// Optional Flutter scroll controller for transcript scrolling.
  final ScrollController? scrollController;

  /// Optional Flutter scroll physics used by the internal scrollable.
  final ScrollPhysics? scrollPhysics;

  /// Whether new terminal activity should snap the viewport back to the live bottom.
  final bool autoFollowOnActivity;

  /// Whether terminal gestures should request focus for keyboard input.
  final bool focusOnInteraction;

  /// Optional callback invoked when the terminal receives a tap interaction.
  final VoidCallback? onTapTerminal;

  /// Optional externally-managed focus node for keyboard input.
  final FocusNode? focusNode;

  /// Terminal background color used for unstyled cells.
  final Color backgroundColor;

  /// Default foreground color used for unstyled text.
  final Color foregroundColor;

  /// Accent color used for terminal chrome such as headers and borders.
  final Color chromeColor;

  /// Base font size in logical pixels for each terminal cell.
  final double fontSize;

  /// Line height multiplier applied to terminal rows.
  final double lineHeight;

  /// Preferred monospace font family for terminal text.
  ///
  /// A bundled monospace font such as `Noto Sans Mono` or `IBM Plex Mono`
  /// gives more consistent terminal text metrics than platform fallback.
  final String? fontFamily;

  /// Fallback font families used when [fontFamily] lacks required glyphs.
  ///
  /// A symbol-oriented fallback such as `Noto Sans Symbols 2` works well for
  /// general-purpose arrows and markers. Terminal primitives such as
  /// box-drawing and block elements may still be rendered by the widget's
  /// custom glyph path for cell-accurate output.
  final List<String>? fontFamilyFallback;

  /// Optional package that provides [fontFamily].
  final String? fontPackage;

  /// Extra tracking applied to terminal glyph layout.
  final double letterSpacing;

  /// Horizontal cell scaling factor used when measuring character advances.
  final double cellWidthScale;

  /// Paint backend used to render terminal cells.
  final GhosttyTerminalRendererMode renderer;

  /// Inner padding between the widget bounds and the terminal grid.
  final EdgeInsets padding;

  /// ANSI and 256-color palette used to resolve terminal color tokens.
  final GhosttyTerminalPalette palette;

  /// Cursor fill or stroke color, depending on cursor style.
  final Color cursorColor;

  /// Overlay color used for interactive text selection highlights.
  final Color selectionColor;

  /// Fallback color used when hyperlinks do not specify their own style.
  final Color hyperlinkColor;

  /// Controls how selected cells are converted back into plain text.
  final GhosttyTerminalCopyOptions copyOptions;

  /// Controls how double-click and word-based selections expand.
  final GhosttyTerminalWordBoundaryPolicy wordBoundaryPolicy;

  /// Distance from the viewport edge that triggers auto-scroll during drag selection.
  final double selectionAutoScrollEdgeInset;

  /// Whether touch text selections should show Flutter's adaptive context menu.
  final bool showSelectionContextMenu;

  /// Builds the buttons shown in the touch selection context menu.
  final GhosttyTerminalSelectionContextMenuButtonItemsBuilder?
  selectionContextMenuButtonItemsBuilder;

  /// Visual thickness of the optional vertical scrollbar.
  final double scrollbarThickness;

  /// Minimum logical height of the optional vertical scrollbar thumb.
  final double scrollbarMinThumbExtent;

  /// Fill color for the optional vertical scrollbar thumb.
  final Color scrollbarThumbColor;

  /// Fill color for the optional vertical scrollbar track.
  final Color scrollbarTrackColor;

  /// Controls whether Flutter-side selection or terminal mouse reporting wins
  /// when both could handle the same pointer input.
  final GhosttyTerminalInteractionPolicy interactionPolicy;

  /// Controls whether touch drags scroll the transcript or select text.
  final GhosttyTerminalTouchDragBehavior touchDragBehavior;

  /// Called whenever the active terminal selection changes.
  final ValueChanged<GhosttyTerminalSelection?>? onSelectionChanged;

  /// Called whenever selection text is recomputed for the active selection.
  final ValueChanged<
    GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
  >?
  onSelectionContentChanged;

  /// Override for copy behavior. When omitted the view writes to the clipboard directly.
  final Future<void> Function(String text)? onCopySelection;

  /// Optional paste callback used instead of reading from the system clipboard.
  final Future<String?> Function()? onPasteRequest;

  /// Callback used when the user activates a hyperlink inside the terminal.
  final Future<void> Function(String uri)? onOpenHyperlink;

  @override
  State<GhosttyTerminalView> createState() => _GhosttyTerminalViewState();
}

class _GhosttyTerminalViewState extends State<GhosttyTerminalView> {
  late FocusNode _focusNode;
  late bool _ownsFocusNode;
  late ScrollController _scrollController;
  late bool _ownsScrollController;
  int _scrollOffsetLines = 0;
  int _lastReportedCols = -1;
  int _lastReportedRows = -1;
  int _lastVisibleStartLine = 0;
  double _lastMeasuredLinePixels = 1;
  final GhosttyTerminalSelectionSession<GhosttyTerminalSelection>
  _selectionSession =
      GhosttyTerminalSelectionSession<GhosttyTerminalSelection>();
  final GhosttyTerminalAutoScrollSession<_TerminalMetrics> _autoScrollSession =
      GhosttyTerminalAutoScrollSession<_TerminalMetrics>();
  final _TerminalTextPainterCache _nativeRunPainterCache =
      _TerminalTextPainterCache(maxEntries: 512);
  final _TerminalTextIntrinsicWidthCache _nativeRunIntrinsicWidthCache =
      _TerminalTextIntrinsicWidthCache(maxEntries: 1024);
  ContextMenuController? _selectionContextMenuController;
  int _pendingSerialTapCount = 0;
  PointerDeviceKind _lastPointerKind = PointerDeviceKind.mouse;
  int? _touchScrollPointer;
  Offset? _lastTouchScrollPosition;
  double _touchScrollRemainder = 0;
  bool _touchSelectionActive = false;
  bool _touchSelectionHandlesVisible = false;
  _TerminalSelectionHandleEdge? _selectionHandleDragEdge;
  Offset? _lastSelectionHandleDragPosition;
  GhosttyTerminalSelection? _wordSelectionAnchor;
  _TerminalSelectionGranularity _dragSelectionGranularity =
      _TerminalSelectionGranularity.cell;
  late final GhosttyTerminalGestureCoordinator<
    GhosttyTerminalCellPosition,
    GhosttyTerminalSelection
  >
  _gestureCoordinator =
      GhosttyTerminalGestureCoordinator<
        GhosttyTerminalCellPosition,
        GhosttyTerminalSelection
      >(_selectionSession);

  GhosttyTerminalSelection? get _selection => _selectionSession.selection;
  String? get _hoveredHyperlink => _selectionSession.hoveredHyperlink;
  int? get _lineSelectionAnchorRow => _selectionSession.lineSelectionAnchorRow;

  void _recordSerialTapDown(SerialTapDownDetails details) {
    _pendingSerialTapCount = details.count;
  }

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocusNode = widget.focusNode == null;
    _scrollController = widget.scrollController ?? ScrollController();
    _ownsScrollController = widget.scrollController == null;
    _scrollController.addListener(_onScrollControllerChanged);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant GhosttyTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastReportedCols = -1;
      _lastReportedRows = -1;
      _scrollOffsetLines = 0;
      _setSelection(null);
      _removeSelectionContextMenu();
      _touchSelectionHandlesVisible = false;
      _selectionHandleDragEdge = null;
      _lastSelectionHandleDragPosition = null;
      _selectionSession.reset();
      _autoScrollSession.reset();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      if (_ownsFocusNode) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
      _ownsFocusNode = widget.focusNode == null;
    }
    if (oldWidget.scrollController != widget.scrollController) {
      _scrollController.removeListener(_onScrollControllerChanged);
      if (_ownsScrollController) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
      _ownsScrollController = widget.scrollController == null;
      _scrollController.addListener(_onScrollControllerChanged);
    }
    if (oldWidget.copyOptions != widget.copyOptions && _selection != null) {
      ghosttyTerminalNotifySelectionContent<GhosttyTerminalSelection>(
        selection: _selection,
        resolveText: _resolveSelectionText,
        onSelectionContentChanged: widget.onSelectionContentChanged,
      );
    }
    if (oldWidget.showSelectionContextMenu &&
        !widget.showSelectionContextMenu) {
      _removeSelectionContextMenu();
    }
  }

  @override
  void dispose() {
    _removeSelectionContextMenu();
    _stopAutoScroll();
    widget.controller.removeListener(_onControllerChanged);
    _scrollController.removeListener(_onScrollControllerChanged);
    if (_ownsScrollController) {
      _scrollController.dispose();
    }
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    if (_selection != null) {
      ghosttyTerminalNotifySelectionContent<GhosttyTerminalSelection>(
        selection: _selection,
        resolveText: _resolveSelectionText,
        onSelectionContentChanged: widget.onSelectionContentChanged,
      );
    }
    if (widget.autoFollowOnActivity) {
      _jumpToLiveBottom();
    }
    setState(() {});
  }

  void _onScrollControllerChanged() {
    if (!mounted || _lastMeasuredLinePixels <= 0) {
      return;
    }
    final nextOffsetLines = (_scrollController.offset / _lastMeasuredLinePixels)
        .round();
    if (nextOffsetLines == _scrollOffsetLines) {
      return;
    }
    setState(() {
      _scrollOffsetLines = nextOffsetLines;
    });
  }

  bool _jumpToLiveBottom() {
    if (_scrollController.hasClients) {
      if (_scrollController.offset.abs() >= 0.5) {
        _scrollController.jumpTo(0);
        return true;
      }
      if (_scrollOffsetLines != 0) {
        setState(() {
          _scrollOffsetLines = 0;
        });
        return true;
      }
      return false;
    }

    if (_scrollOffsetLines != 0) {
      setState(() {
        _scrollOffsetLines = 0;
      });
      return true;
    }
    return false;
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final modifiers = GhosttyTerminalModifierState.fromHardwareKeyboard();

    if (ghosttyTerminalMatchesCopyShortcut(
      event.logicalKey,
      modifiers: modifiers,
      platform: defaultTargetPlatform,
    )) {
      final text = _selectionText();
      if (text.isNotEmpty) {
        unawaited(_copySelection(text));
        return KeyEventResult.handled;
      }
    }
    if (ghosttyTerminalMatchesClearSelectionShortcut(
          event.logicalKey,
          modifiers: modifiers,
        ) &&
        _selection != null) {
      _setSelection(null);
      return KeyEventResult.handled;
    }
    if (ghosttyTerminalMatchesSelectAllShortcut(
      event.logicalKey,
      modifiers: modifiers,
      platform: defaultTargetPlatform,
    )) {
      final selection = widget.controller.snapshot.selectAllSelection();
      if (selection != null) {
        _setSelection(selection, touchSelectionHandlesVisible: false);
        return KeyEventResult.handled;
      }
    }
    if (ghosttyTerminalMatchesPasteShortcut(
      event.logicalKey,
      modifiers: modifiers,
      platform: defaultTargetPlatform,
    )) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }

    final key = ghosttyTerminalLogicalKey(event.logicalKey);
    final mods = modifiers.ghosttyMask;
    final character = ghosttyTerminalPrintableText(event, modifiers: modifiers);
    final controlText = ghosttyTerminalControlText(event, modifiers: modifiers);

    if (key != null) {
      _jumpToLiveBottom();
      if (_selection != null) {
        _setSelection(null);
      }
      // Special keys are encoded from the key enum/modifier state alone.
      // Forwarding printable text metadata here breaks keys like backspace.
      final sent = widget.controller.sendKey(
        key: key,
        action: event is KeyRepeatEvent
            ? GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT
            : GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
        mods: mods,
        utf8Text: '',
        unshiftedCodepoint: 0,
      );
      return sent ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    if (character.isNotEmpty) {
      _jumpToLiveBottom();
      if (_selection != null) {
        _setSelection(null);
      }
      final sent = widget.controller.write(character);
      return sent ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    if (controlText != null && controlText.isNotEmpty) {
      _jumpToLiveBottom();
      if (_selection != null) {
        _setSelection(null);
      }
      final sent = widget.controller.write(controlText);
      return sent ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _copySelection(String text) async {
    await ghosttyTerminalCopyText(
      text,
      onCopySelection: widget.onCopySelection,
    );
  }

  Future<void> _pasteClipboard() async {
    final text = await ghosttyTerminalReadPasteText(
      onPasteRequest: widget.onPasteRequest,
    );
    if (text == null || text.isEmpty) {
      return;
    }
    widget.controller.write(text, sanitizePaste: true);
  }

  String _selectionText() {
    final selection = _selection;
    if (selection == null) {
      return '';
    }
    return _resolveSelectionText(selection);
  }

  String _resolveSelectionText(GhosttyTerminalSelection selection) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        _scrollOffsetLines == 0 &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      return _renderSnapshotTextForSelection(
        renderSnapshot,
        selection,
        viewportStartLine: _lastVisibleStartLine,
        options: widget.copyOptions,
      );
    }
    return widget.controller.snapshot.textForSelection(
      selection,
      options: widget.copyOptions,
    );
  }

  String? _resolveHyperlinkUriAt(GhosttyTerminalCellPosition position) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        _scrollOffsetLines == 0 &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      final uri = _renderSnapshotHyperlinkAt(
        renderSnapshot,
        position,
        viewportStartLine: _lastVisibleStartLine,
      );
      if (uri != null) {
        return uri;
      }
    }
    return widget.controller.snapshot.hyperlinkAt(position);
  }

  GhosttyTerminalSelection? _resolveWordSelectionAt(
    GhosttyTerminalCellPosition position,
  ) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        _scrollOffsetLines == 0 &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      return _renderSnapshotWordSelectionAt(
        renderSnapshot,
        position,
        viewportStartLine: _lastVisibleStartLine,
        policy: widget.wordBoundaryPolicy,
      );
    }
    return widget.controller.snapshot.wordSelectionAt(
      position,
      policy: widget.wordBoundaryPolicy,
    );
  }

  GhosttyTerminalSelection? _resolveLineSelectionBetweenRows(
    int baseRow,
    int extentRow,
  ) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        _scrollOffsetLines == 0 &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      return _renderSnapshotLineSelectionBetweenRows(
        renderSnapshot,
        baseRow,
        extentRow,
        viewportStartLine: _lastVisibleStartLine,
      );
    }
    return widget.controller.snapshot.lineSelectionBetweenRows(
      baseRow,
      extentRow,
    );
  }

  void _setSelection(
    GhosttyTerminalSelection? selection, {
    bool? touchSelectionHandlesVisible,
  }) {
    final previousSelection = _selection;
    if (!_selectionSession.updateSelection(selection)) {
      return;
    }
    if (selection == null) {
      _removeSelectionContextMenu();
      _touchSelectionHandlesVisible = false;
      _selectionHandleDragEdge = null;
      _lastSelectionHandleDragPosition = null;
    } else if (touchSelectionHandlesVisible != null) {
      _touchSelectionHandlesVisible = touchSelectionHandlesVisible;
    }
    setState(() {});
    ghosttyTerminalNotifySelectionChange<GhosttyTerminalSelection>(
      previousSelection: previousSelection,
      nextSelection: _selection,
      resolveText: _resolveSelectionText,
      onSelectionChanged: widget.onSelectionChanged,
      onSelectionContentChanged: widget.onSelectionContentChanged,
    );
  }

  void _removeSelectionContextMenu() {
    _selectionContextMenuController?.remove();
    _selectionContextMenuController = null;
  }

  void _showSelectionContextMenu({
    required Size size,
    required _TerminalMetrics metrics,
    Offset? fallbackLocalPosition,
  }) {
    if (!widget.showSelectionContextMenu || !mounted) {
      return;
    }
    final selection = _selection;
    if (selection == null || _resolveSelectionText(selection).isEmpty) {
      _removeSelectionContextMenu();
      return;
    }

    final controller = ContextMenuController();
    _selectionContextMenuController = controller;
    controller.show(
      context: context,
      contextMenuBuilder: (context) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: _selectionContextMenuAnchors(
          size,
          metrics,
          fallbackLocalPosition: fallbackLocalPosition,
        ),
        buttonItems: _selectionContextMenuButtonItems(),
      ),
    );
  }

  void _scheduleSelectionContextMenu({
    required Size size,
    required _TerminalMetrics metrics,
    Offset? fallbackLocalPosition,
  }) {
    if (!widget.showSelectionContextMenu) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selection == null) {
        return;
      }
      _showSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: fallbackLocalPosition,
      );
    });
  }

  List<ContextMenuButtonItem> _selectionContextMenuButtonItems() {
    final selection = _selection;
    if (selection == null) {
      return const <ContextMenuButtonItem>[];
    }
    final selectedText = _resolveSelectionText(selection);
    final defaultButtonItems = List<ContextMenuButtonItem>.unmodifiable(
      _defaultSelectionContextMenuButtonItems(),
    );
    final builder = widget.selectionContextMenuButtonItemsBuilder;
    if (builder == null) {
      return defaultButtonItems;
    }
    return builder(
      GhosttyTerminalSelectionContextMenuDetails(
        selection: selection,
        selectedText: selectedText,
        defaultButtonItems: defaultButtonItems,
        copySelection: _copySelectionFromContextMenu,
        selectAll: _selectAllFromContextMenu,
        hideToolbar: _removeSelectionContextMenu,
      ),
    );
  }

  List<ContextMenuButtonItem> _defaultSelectionContextMenuButtonItems() {
    return <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: _copySelectionFromContextMenu,
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: _selectAllFromContextMenu,
      ),
    ];
  }

  void _copySelectionFromContextMenu() {
    final text = _selectionText();
    _removeSelectionContextMenu();
    if (text.isNotEmpty) {
      unawaited(_copySelection(text));
    }
  }

  void _selectAllFromContextMenu() {
    _removeSelectionContextMenu();
    final selection = widget.controller.snapshot.selectAllSelection();
    if (selection != null) {
      _setSelection(selection);
    }
  }

  TextSelectionToolbarAnchors _selectionContextMenuAnchors(
    Size size,
    _TerminalMetrics metrics, {
    Offset? fallbackLocalPosition,
  }) {
    final renderObject = context.findRenderObject();
    final renderBox = renderObject is RenderBox ? renderObject : null;
    final fallback = fallbackLocalPosition ?? Offset(size.width / 2, 0);
    if (renderBox == null || !renderBox.hasSize) {
      return TextSelectionToolbarAnchors(primaryAnchor: fallback);
    }

    final selectionRect =
        _selectionRectForContextMenu(size, metrics) ??
        Rect.fromCenter(
          center: fallback,
          width: metrics.charWidth,
          height: metrics.linePixels,
        );
    return TextSelectionToolbarAnchors(
      primaryAnchor: renderBox.localToGlobal(selectionRect.topCenter),
      secondaryAnchor: renderBox.localToGlobal(selectionRect.bottomCenter),
    );
  }

  Rect? _selectionRectForContextMenu(Size size, _TerminalMetrics metrics) {
    final selection = _selection;
    if (selection == null) {
      return null;
    }
    final viewport = _viewportFor(size, metrics);
    final visibleStart = viewport.startLine;
    final visibleEnd = viewport.startLine + viewport.maxVisible - 1;
    final normalized = selection.normalized;
    final startRow = normalized.start.row.clamp(visibleStart, visibleEnd);
    final endRow = normalized.end.row.clamp(visibleStart, visibleEnd);
    if (endRow < visibleStart || startRow > visibleEnd || startRow > endRow) {
      return null;
    }

    final isMultiLine = normalized.start.row != normalized.end.row;
    final contentLeft = widget.padding.left;
    final contentRight = size.width - widget.padding.right;
    final left = isMultiLine
        ? contentLeft
        : contentLeft + normalized.start.col * metrics.charWidth;
    final right = isMultiLine
        ? contentRight
        : contentLeft + (normalized.end.col + 1) * metrics.charWidth;
    final top =
        viewport.contentTop +
        (startRow - viewport.startLine) * metrics.linePixels;
    final bottom =
        viewport.contentTop +
        (endRow - viewport.startLine + 1) * metrics.linePixels;

    return Rect.fromLTRB(
      left.clamp(contentLeft, contentRight),
      top.clamp(
        viewport.contentTop,
        viewport.contentTop + viewport.contentHeight,
      ),
      right.clamp(contentLeft, contentRight),
      bottom.clamp(
        viewport.contentTop,
        viewport.contentTop + viewport.contentHeight,
      ),
    );
  }

  Widget _buildSelectionHandleOverlay(
    Size size,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    if (!_touchSelectionHandlesVisible || _selection == null) {
      return const SizedBox.shrink();
    }

    final start = _selectionEndpointOffset(
      _TerminalSelectionHandleEdge.start,
      metrics,
      viewport,
    );
    final end = _selectionEndpointOffset(
      _TerminalSelectionHandleEdge.end,
      metrics,
      viewport,
    );
    if (start == null && end == null) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (start != null)
            _buildSelectionHandle(
              edge: _TerminalSelectionHandleEdge.start,
              center: start,
              size: size,
              metrics: metrics,
            ),
          if (end != null)
            _buildSelectionHandle(
              edge: _TerminalSelectionHandleEdge.end,
              center: end,
              size: size,
              metrics: metrics,
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionHandle({
    required _TerminalSelectionHandleEdge edge,
    required Offset center,
    required Size size,
    required _TerminalMetrics metrics,
  }) {
    return Positioned(
      left: center.dx - _selectionHandleTouchExtent / 2,
      top: center.dy - _selectionHandleVisualRadius,
      width: _selectionHandleTouchExtent,
      height: _selectionHandleTouchExtent,
      child: GestureDetector(
        key: edge == _TerminalSelectionHandleEdge.start
            ? _selectionStartHandleKey
            : _selectionEndHandleKey,
        supportedDevices: _touchPointerDevices,
        behavior: HitTestBehavior.translucent,
        onPanStart: (details) {
          final localPosition = _terminalLocalFromGlobal(
            details.globalPosition,
          );
          if (localPosition != null) {
            _beginSelectionHandleDrag(edge, localPosition, size, metrics);
          }
        },
        onPanUpdate: (details) {
          final localPosition = _terminalLocalFromGlobal(
            details.globalPosition,
          );
          if (localPosition != null) {
            _updateSelectionHandleDrag(localPosition, size, metrics);
          }
        },
        onPanEnd: (_) => _endSelectionHandleDrag(size, metrics),
        onPanCancel: () => _endSelectionHandleDrag(size, metrics),
        child: CustomPaint(
          painter: _TerminalSelectionHandlePainter(color: widget.cursorColor),
        ),
      ),
    );
  }

  Offset? _terminalLocalFromGlobal(Offset globalPosition) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    return renderObject.globalToLocal(globalPosition);
  }

  Offset? _selectionEndpointOffset(
    _TerminalSelectionHandleEdge edge,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    final selection = _selection?.normalized;
    if (selection == null) {
      return null;
    }
    final position = edge == _TerminalSelectionHandleEdge.start
        ? selection.start
        : selection.end;
    if (position.row < viewport.startLine ||
        position.row >= viewport.startLine + viewport.maxVisible) {
      return null;
    }

    final rawX = edge == _TerminalSelectionHandleEdge.start
        ? widget.padding.left + position.col * metrics.charWidth
        : widget.padding.left + (position.col + 1) * metrics.charWidth;
    final minX = widget.padding.left;
    final maxX = math.max(minX, _lastReportedCols * metrics.charWidth + minX);
    final y =
        viewport.contentTop +
        (position.row - viewport.startLine + 1) * metrics.linePixels;
    return Offset(rawX.clamp(minX, maxX), y);
  }

  void _beginSelectionHandleDrag(
    _TerminalSelectionHandleEdge edge,
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (_selection == null || _currentPointerUsesTerminalMouse) {
      return;
    }
    _removeSelectionContextMenu();
    _selectionHandleDragEdge = edge;
    _lastSelectionHandleDragPosition = localPosition;
    _touchSelectionActive = true;
    _touchSelectionHandlesVisible = true;
    _dragSelectionGranularity = _TerminalSelectionGranularity.cell;
    _updateSelectionHandleDrag(localPosition, size, metrics);
  }

  void _updateSelectionHandleDrag(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final position = _positionForOffset(
      localPosition,
      size,
      metrics,
      clampToViewport: true,
    );
    final selection = _selectionForHandleDragPosition(position);
    if (selection == null) {
      return;
    }
    _lastSelectionHandleDragPosition = localPosition;
    _setSelection(selection, touchSelectionHandlesVisible: true);
    _syncAutoScroll(localPosition, size, metrics);
  }

  GhosttyTerminalSelection? _selectionForHandleDragPosition(
    GhosttyTerminalCellPosition? position,
  ) {
    final edge = _selectionHandleDragEdge;
    final current = _selection?.normalized;
    if (edge == null || current == null || position == null) {
      return null;
    }
    return switch (edge) {
      _TerminalSelectionHandleEdge.start => GhosttyTerminalSelection(
        base: position,
        extent: current.end,
      ),
      _TerminalSelectionHandleEdge.end => GhosttyTerminalSelection(
        base: current.start,
        extent: position,
      ),
    };
  }

  void _endSelectionHandleDrag(Size size, _TerminalMetrics metrics) {
    final localPosition = _lastSelectionHandleDragPosition;
    _selectionHandleDragEdge = null;
    _lastSelectionHandleDragPosition = null;
    _touchSelectionActive = false;
    _stopAutoScroll();
    if (_selection != null) {
      _touchSelectionHandlesVisible = true;
      _scheduleSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: localPosition,
      );
    }
  }

  _TerminalMetrics _measureMetrics() {
    final painter = TextPainter(
      text: TextSpan(
        text: 'W',
        style: _terminalTextStyle(
          fontSize: widget.fontSize,
          lineHeight: widget.lineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return _TerminalMetrics(
      charWidth: math.max(1, painter.width * widget.cellWidthScale),
      linePixels: math.max(1, widget.fontSize * widget.lineHeight),
    );
  }

  TextStyle _terminalTextStyle({
    required double fontSize,
    required double lineHeight,
    Color? color,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    TextDecoration? decoration,
    TextDecorationStyle? decorationStyle,
    Color? decorationColor,
  }) {
    return TextStyle(
      color: color,
      fontFamily: widget.fontFamily ?? 'monospace',
      fontFamilyFallback: widget.fontFamilyFallback,
      package: widget.fontPackage,
      fontSize: fontSize,
      height: lineHeight,
      letterSpacing: widget.letterSpacing,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      decoration: decoration,
      decorationStyle: decorationStyle,
      decorationColor: decorationColor,
    );
  }

  double get _headerHeight => widget.showHeader ? _terminalHeaderHeight : 0;

  void _syncGrid(Size size, _TerminalMetrics metrics) {
    final contentWidth = size.width - widget.padding.horizontal;
    final contentHeight = size.height - _headerHeight - widget.padding.vertical;
    if (contentWidth <= 0 || contentHeight <= 0) {
      return;
    }

    final cols = math.max(1, (contentWidth / metrics.charWidth).floor());
    final rows = math.max(1, (contentHeight / metrics.linePixels).floor());
    if (cols == _lastReportedCols && rows == _lastReportedRows) {
      return;
    }

    _lastReportedCols = cols;
    _lastReportedRows = rows;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.controller.resize(
        cols: cols,
        rows: rows,
        cellWidthPx: metrics.charWidth.round(),
        cellHeightPx: metrics.linePixels.round(),
      );
    });
  }

  void _handlePointerSignal(
    PointerSignalEvent event,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (event is! PointerScrollEvent) {
      return;
    }

    if (_terminalMouseReportingEnabled) {
      final scrollUp = event.scrollDelta.dy < 0;
      if (!scrollUp && event.scrollDelta.dy <= 0) {
        return;
      }
      final button = scrollUp
          ? GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FOUR
          : GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FIVE;
      _sendMouseEvent(
        GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
        event,
        size,
        metrics,
        button: button,
      );
      _sendMouseEvent(
        GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
        event,
        size,
        metrics,
        button: button,
      );
      return;
    }

    final deltaLines = (event.scrollDelta.dy / metrics.linePixels).round();
    if (deltaLines == 0) {
      return;
    }

    _setScrollOffsetLines(_scrollOffsetLines - deltaLines, size, metrics);
  }

  VtMouseEncoderSize _mouseEncoderSize(Size size, _TerminalMetrics metrics) {
    return VtMouseEncoderSize(
      screenWidth: math.max(1, size.width.round()),
      screenHeight: math.max(1, (size.height - _headerHeight).round()),
      cellWidth: math.max(1, metrics.charWidth.round()),
      cellHeight: math.max(1, metrics.linePixels.round()),
      paddingTop: widget.padding.top.round(),
      paddingBottom: widget.padding.bottom.round(),
      paddingRight: widget.padding.right.round(),
      paddingLeft: widget.padding.left.round(),
    );
  }

  GhosttyMouseButton? _mouseButtonFromButtons(int buttons) {
    if ((buttons & kPrimaryMouseButton) != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT;
    }
    if ((buttons & kSecondaryMouseButton) != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_RIGHT;
    }
    if ((buttons & kMiddleMouseButton) != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_MIDDLE;
    }
    return null;
  }

  GhosttyMouseButton? _mouseButtonForEvent(
    GhosttyMouseAction action,
    PointerEvent event,
    GhosttyMouseButton? explicitButton,
  ) {
    if (explicitButton != null) {
      return explicitButton;
    }
    final button = _mouseButtonFromButtons(event.buttons);
    if (button != null) {
      return button;
    }
    if (event.kind == PointerDeviceKind.touch &&
        action != GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT;
    }
    return null;
  }

  bool _eventHasPressedButton(GhosttyMouseAction action, PointerEvent event) {
    return event.buttons != 0 ||
        action == GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS;
  }

  bool get _terminalMouseReportingEnabled => switch (widget.interactionPolicy) {
    GhosttyTerminalInteractionPolicy.selectionFirst => false,
    GhosttyTerminalInteractionPolicy.terminalMouseFirst => true,
    GhosttyTerminalInteractionPolicy.auto =>
      _safeTerminalMode(VtModes.x10Mouse) ||
          _safeTerminalMode(VtModes.normalMouse) ||
          _safeTerminalMode(VtModes.buttonMouse) ||
          _safeTerminalMode(VtModes.anyMouse),
  };

  bool _safeTerminalMode(VtMode mode) {
    try {
      return widget.controller.terminal.getMode(mode);
    } catch (_) {
      return false;
    }
  }

  GhosttyMouseTrackingMode? get _terminalMouseTrackingMode {
    if (_safeTerminalMode(VtModes.anyMouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY;
    }
    if (_safeTerminalMode(VtModes.buttonMouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_BUTTON;
    }
    if (_safeTerminalMode(VtModes.normalMouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL;
    }
    if (_safeTerminalMode(VtModes.x10Mouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_X10;
    }
    return null;
  }

  GhosttyMouseFormat? get _terminalMouseFormat {
    if (!_terminalMouseReportingEnabled) {
      return null;
    }
    if (_safeTerminalMode(VtModes.sgrPixelsMouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR_PIXELS;
    }
    if (_safeTerminalMode(VtModes.sgrMouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR;
    }
    if (_safeTerminalMode(VtModes.urxvtMouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_URXVT;
    }
    if (_safeTerminalMode(VtModes.utf8Mouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_UTF8;
    }
    return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_X10;
  }

  bool _terminalMouseReportingCapturesPointerKind(PointerDeviceKind kind) {
    if (!_terminalMouseReportingEnabled) {
      return false;
    }
    return kind != PointerDeviceKind.touch ||
        widget.interactionPolicy ==
            GhosttyTerminalInteractionPolicy.terminalMouseFirst;
  }

  bool get _currentPointerUsesTerminalMouse =>
      _terminalMouseReportingCapturesPointerKind(_lastPointerKind);

  Set<PointerDeviceKind> get _selectionDragDevices {
    if (widget.touchDragBehavior ==
        GhosttyTerminalTouchDragBehavior.selection) {
      return const <PointerDeviceKind>{
        ..._mouseLikePointerDevices,
        ..._touchPointerDevices,
      };
    }
    return _mouseLikePointerDevices;
  }

  void _sendMouseEvent(
    GhosttyMouseAction action,
    PointerEvent event,
    Size size,
    _TerminalMetrics metrics, {
    GhosttyMouseButton? button,
  }) {
    if (!_terminalMouseReportingCapturesPointerKind(event.kind)) {
      return;
    }

    final terminalLocalY = math.max<double>(
      0,
      event.localPosition.dy - _headerHeight,
    );
    widget.controller.sendMouse(
      action: action,
      button: _mouseButtonForEvent(action, event, button),
      mods: GhosttyTerminalModifierState.fromHardwareKeyboard().ghosttyMask,
      position: VtMousePosition(x: event.localPosition.dx, y: terminalLocalY),
      size: _mouseEncoderSize(size, metrics),
      trackingMode: _terminalMouseTrackingMode,
      format: _terminalMouseFormat,
      anyButtonPressed: _eventHasPressedButton(action, event),
      trackLastCell: true,
    );
  }

  int _maxScrollOffset(Size size, _TerminalMetrics metrics) {
    final viewport = _viewportFor(size, metrics);
    return math.max(
      0,
      widget.controller.snapshot.lines.length - viewport.maxVisible,
    );
  }

  _TerminalViewport _viewportFor(Size size, _TerminalMetrics metrics) {
    final contentTop = _headerHeight + widget.padding.top;
    final contentHeight = size.height - contentTop - widget.padding.bottom;
    final maxVisible = contentHeight <= 0
        ? 1
        : math.max(1, (contentHeight / metrics.linePixels).floor());
    final lineCount = widget.controller.snapshot.lines.length;
    final maxOffset = math.max(0, lineCount - maxVisible);
    final offset = _scrollOffsetLines.clamp(0, maxOffset);
    final end = math.max(0, lineCount - offset);
    final start = math.max(0, end - maxVisible);
    return _TerminalViewport(
      startLine: start,
      contentTop: contentTop,
      contentHeight: math.max(0, contentHeight),
      maxVisible: maxVisible,
    );
  }

  void _setScrollOffsetLines(int offset, Size size, _TerminalMetrics metrics) {
    final clamped = offset.clamp(0, _maxScrollOffset(size, metrics));
    if (clamped == _scrollOffsetLines && !_scrollController.hasClients) {
      return;
    }
    final targetPixels = clamped * metrics.linePixels;
    if (_scrollController.hasClients) {
      final maxPixels = _scrollController.position.maxScrollExtent;
      final clampedPixels = targetPixels.clamp(0.0, maxPixels);
      if ((_scrollController.offset - clampedPixels).abs() < 0.5) {
        if (clamped != _scrollOffsetLines) {
          setState(() {
            _scrollOffsetLines = clamped;
          });
        }
        return;
      }
      _scrollController.jumpTo(clampedPixels);
      return;
    }
    setState(() {
      _scrollOffsetLines = clamped;
    });
  }

  Widget _buildScrollLayer(
    Size size,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    final maxOffset = _maxScrollOffset(size, metrics);
    if (viewport.contentHeight <= 0) {
      return const SizedBox.shrink();
    }

    final maxScrollPixels = maxOffset * metrics.linePixels;
    final scrollExtentHeight = viewport.contentHeight + maxScrollPixels;
    return Positioned(
      left: 0,
      right: 0,
      top: viewport.contentTop,
      height: viewport.contentHeight,
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: widget.scrollPhysics ?? const ClampingScrollPhysics(),
        child: SizedBox(width: size.width, height: scrollExtentHeight),
      ),
    );
  }

  Widget _buildScrollbarOverlay(
    Size size,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    final lineCount = widget.controller.snapshot.lines.length;
    final maxOffset = _maxScrollOffset(size, metrics);
    if (!widget.showVerticalScrollbar ||
        viewport.contentHeight <= 0 ||
        lineCount <= viewport.maxVisible ||
        maxOffset <= 0) {
      return const SizedBox.shrink();
    }

    final trackTop = viewport.contentTop;
    final trackHeight = viewport.contentHeight;
    final visibleFraction = (viewport.maxVisible / lineCount).clamp(0.0, 1.0);
    final thumbExtent = math.max(
      widget.scrollbarMinThumbExtent,
      trackHeight * visibleFraction,
    );
    final thumbTravel = math.max(0.0, trackHeight - thumbExtent);
    final thumbTop =
        trackTop +
        (maxOffset == 0
            ? thumbTravel
            : ((maxOffset - _scrollOffsetLines) / maxOffset) * thumbTravel);

    double fractionForDy(double dy, {bool centerThumb = false}) {
      final localY = dy - trackTop;
      final thumbAnchor = centerThumb ? thumbExtent / 2 : 0.0;
      final travelY = (localY - thumbAnchor).clamp(0.0, thumbTravel);
      if (thumbTravel <= 0) {
        return 0;
      }
      return travelY / thumbTravel;
    }

    void updateFraction(double fraction) {
      final nextOffset = ((1 - fraction.clamp(0.0, 1.0)) * maxOffset).round();
      _setScrollOffsetLines(nextOffset, size, metrics);
    }

    return Positioned(
      top: trackTop,
      right: 2,
      width: widget.scrollbarThickness,
      height: trackHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => updateFraction(
          fractionForDy(details.localPosition.dy + trackTop, centerThumb: true),
        ),
        onVerticalDragDown: (details) => updateFraction(
          fractionForDy(details.localPosition.dy + trackTop, centerThumb: true),
        ),
        onVerticalDragUpdate: (details) => updateFraction(
          fractionForDy(details.localPosition.dy + trackTop, centerThumb: true),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.scrollbarTrackColor,
            borderRadius: BorderRadius.circular(widget.scrollbarThickness / 2),
          ),
          child: Stack(
            children: [
              Positioned(
                top: thumbTop - trackTop,
                left: 0,
                right: 0,
                height: thumbExtent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.scrollbarThumbColor,
                    borderRadius: BorderRadius.circular(
                      widget.scrollbarThickness / 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  GhosttyTerminalCellPosition? _positionForOffset(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics, {
    bool clampToViewport = false,
  }) {
    final viewport = _viewportFor(size, metrics);
    if (widget.controller.snapshot.lines.isEmpty) {
      return null;
    }

    final minX = widget.padding.left;
    final maxX = size.width - widget.padding.right;
    final minY = viewport.contentTop;
    final maxY = viewport.contentTop + viewport.contentHeight;
    if (!clampToViewport &&
        (localPosition.dx < minX ||
            localPosition.dx > maxX ||
            localPosition.dy < minY ||
            localPosition.dy > maxY)) {
      return null;
    }

    final resolvedX = clampToViewport
        ? localPosition.dx.clamp(minX, maxX)
        : localPosition.dx;
    final resolvedY = clampToViewport
        ? localPosition.dy.clamp(minY, maxY)
        : localPosition.dy;
    final lineIndex = ((resolvedY - viewport.contentTop) / metrics.linePixels)
        .floor();
    final row = (viewport.startLine + lineIndex).clamp(
      0,
      widget.controller.snapshot.lines.length - 1,
    );
    final col = ((resolvedX - widget.padding.left) / metrics.charWidth).floor();
    final maxCol = math.max(0, widget.controller.cols - 1);
    return GhosttyTerminalCellPosition(row: row, col: col.clamp(0, maxCol));
  }

  void _stopAutoScroll({
    bool clearLineSelectionAnchor = true,
    bool resetSelectionGestureState = true,
  }) {
    _autoScrollSession.stop();
    if (clearLineSelectionAnchor) {
      _selectionSession.clearLineSelectionAnchorRow();
    }
    if (resetSelectionGestureState) {
      _dragSelectionGranularity = _TerminalSelectionGranularity.cell;
      _wordSelectionAnchor = null;
      _selectionHandleDragEdge = null;
      _lastSelectionHandleDragPosition = null;
      _pendingSerialTapCount = 0;
    }
  }

  void _syncAutoScroll(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    _autoScrollSession
      ..updateDragPosition(localPosition)
      ..updateLayout(layoutSize: size, metrics: metrics);

    final viewport = _viewportFor(size, metrics);
    final edgeThreshold = widget.selectionAutoScrollEdgeInset;
    final topEdge = viewport.contentTop + edgeThreshold;
    final bottomEdge =
        viewport.contentTop + viewport.contentHeight - edgeThreshold;
    final shouldScrollUp = localPosition.dy < topEdge;
    final shouldScrollDown = localPosition.dy > bottomEdge;
    if (!shouldScrollUp && !shouldScrollDown) {
      _stopAutoScroll(
        clearLineSelectionAnchor: false,
        resetSelectionGestureState: false,
      );
      return;
    }

    _autoScrollSession.ensureTimer(
      const Duration(milliseconds: 50),
      _performAutoScrollTick,
    );
  }

  void _performAutoScrollTick() {
    final size = _autoScrollSession.layoutSize;
    final metrics = _autoScrollSession.metrics;
    final localPosition = _autoScrollSession.dragPosition;
    if (!mounted || size == null || metrics == null || localPosition == null) {
      _stopAutoScroll();
      return;
    }

    final viewport = _viewportFor(size, metrics);
    final edgeThreshold = widget.selectionAutoScrollEdgeInset;
    final topEdge = viewport.contentTop + edgeThreshold;
    final bottomEdge =
        viewport.contentTop + viewport.contentHeight - edgeThreshold;
    final direction = localPosition.dy < topEdge
        ? 1
        : (localPosition.dy > bottomEdge ? -1 : 0);
    if (direction == 0) {
      _stopAutoScroll(
        clearLineSelectionAnchor: false,
        resetSelectionGestureState: false,
      );
      return;
    }

    final nextOffset = (_scrollOffsetLines + direction).clamp(
      0,
      _maxScrollOffset(size, metrics),
    );
    if (nextOffset == _scrollOffsetLines) {
      _stopAutoScroll(
        clearLineSelectionAnchor: false,
        resetSelectionGestureState: false,
      );
      return;
    }
    final position = _positionForOffset(
      Offset(
        localPosition.dx,
        direction > 0
            ? viewport.contentTop + 1
            : viewport.contentTop + viewport.contentHeight - 1,
      ),
      size,
      metrics,
      clampToViewport: true,
    );
    if (position == null) {
      _stopAutoScroll();
      return;
    }

    final current = _selection;
    if (current == null) {
      _stopAutoScroll();
      return;
    }

    final lineSelectionAnchorRow = _lineSelectionAnchorRow;
    final nextSelection = _selectionHandleDragEdge == null
        ? switch (_dragSelectionGranularity) {
            _TerminalSelectionGranularity.word => _extendWordSelection(
              position,
            ),
            _TerminalSelectionGranularity.line =>
              lineSelectionAnchorRow == null
                  ? GhosttyTerminalSelection(
                      base: current.base,
                      extent: position,
                    )
                  : _resolveLineSelectionBetweenRows(
                      lineSelectionAnchorRow,
                      position.row,
                    ),
            _TerminalSelectionGranularity.cell =>
              lineSelectionAnchorRow == null
                  ? GhosttyTerminalSelection(
                      base: current.base,
                      extent: position,
                    )
                  : _resolveLineSelectionBetweenRows(
                      lineSelectionAnchorRow,
                      position.row,
                    ),
          }
        : _selectionForHandleDragPosition(position);
    if (nextSelection == null) {
      _stopAutoScroll();
      return;
    }
    final previousSelection = _selection;
    setState(() {
      _scrollOffsetLines = nextOffset;
    });
    _selectionSession.updateSelection(nextSelection);
    ghosttyTerminalNotifySelectionChange<GhosttyTerminalSelection>(
      previousSelection: previousSelection,
      nextSelection: _selection,
      resolveText: _resolveSelectionText,
      onSelectionChanged: widget.onSelectionChanged,
      onSelectionContentChanged: widget.onSelectionContentChanged,
    );
  }

  void _updateHoveredHyperlink(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final position = _positionForOffset(localPosition, size, metrics);
    if (!ghosttyTerminalUpdateHoveredLink<
      GhosttyTerminalCellPosition,
      GhosttyTerminalSelection
    >(
      session: _selectionSession,
      position: position,
      resolveUri: _resolveHyperlinkUriAt,
    )) {
      return;
    }
    setState(() {});
  }

  Future<void> _openHyperlink(String uri) async {
    await ghosttyTerminalOpenHyperlink(
      uri,
      onOpenHyperlink: widget.onOpenHyperlink,
    );
  }

  void _requestTerminalFocus() {
    if (widget.focusOnInteraction && !_focusNode.hasFocus) {
      FocusScope.of(context).requestFocus(_focusNode);
    }
  }

  bool _touchPointerShouldScroll(PointerEvent event) {
    return event.kind == PointerDeviceKind.touch &&
        widget.touchDragBehavior == GhosttyTerminalTouchDragBehavior.scroll &&
        !_terminalMouseReportingCapturesPointerKind(event.kind);
  }

  void _startTouchScroll(PointerDownEvent event) {
    if (!_touchPointerShouldScroll(event)) {
      return;
    }
    _touchScrollPointer = event.pointer;
    _lastTouchScrollPosition = event.localPosition;
    _touchScrollRemainder = 0;
    _touchSelectionActive = false;
  }

  void _updateTouchScroll(
    PointerMoveEvent event,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (event.pointer != _touchScrollPointer || _touchSelectionActive) {
      return;
    }

    final previous = _lastTouchScrollPosition;
    _lastTouchScrollPosition = event.localPosition;
    if (previous == null) {
      return;
    }

    final delta = event.localPosition.dy - previous.dy + _touchScrollRemainder;
    final deltaLines = (delta / metrics.linePixels).truncate();
    _touchScrollRemainder = delta - deltaLines * metrics.linePixels;
    if (deltaLines == 0) {
      return;
    }

    _setScrollOffsetLines(_scrollOffsetLines - deltaLines, size, metrics);
  }

  void _endTouchScroll(PointerEvent event) {
    if (event.pointer != _touchScrollPointer) {
      return;
    }
    _touchScrollPointer = null;
    _lastTouchScrollPosition = null;
    _touchScrollRemainder = 0;
    _touchSelectionActive = false;
  }

  void _handleSerialTapUp(
    SerialTapUpDetails details,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final tapCount = details.count;
    _pendingSerialTapCount = 0;
    switch (tapCount) {
      case 1:
        _handleTapUp(details.localPosition, size, metrics);
      case 2:
        _selectWord(details.localPosition, size, metrics);
      default:
        _beginLineSelection(details.localPosition, size, metrics);
    }
  }

  void _handleTapUp(Offset localPosition, Size size, _TerminalMetrics metrics) {
    widget.onTapTerminal?.call();
    _requestTerminalFocus();
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    final position = _positionForOffset(localPosition, size, metrics);
    final currentSelection = _selection;
    if ((HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isLogicalKeyPressed(
              LogicalKeyboardKey.shiftLeft,
            ) ||
            HardwareKeyboard.instance.isLogicalKeyPressed(
              LogicalKeyboardKey.shiftRight,
            )) &&
        currentSelection != null &&
        position != null) {
      final nextSelection = _lineSelectionAnchorRow == null
          ? GhosttyTerminalSelection(
              base: currentSelection.base,
              extent: position,
            )
          : _resolveLineSelectionBetweenRows(
              _lineSelectionAnchorRow!,
              position.row,
            );
      if (nextSelection != null) {
        _setSelection(nextSelection);
      }
      return;
    }
    final resolution =
        ghosttyTerminalResolveTap<
          GhosttyTerminalCellPosition,
          GhosttyTerminalSelection
        >(
          session: _selectionSession,
          selection: _selection,
          position: position,
          resolveUri: _resolveHyperlinkUriAt,
        );
    if (resolution.hyperlink case final hyperlink?) {
      unawaited(_openHyperlink(hyperlink));
      return;
    }
    if (resolution.clearSelection) {
      _setSelection(null);
    }
  }

  void _beginSelection(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    if (_pendingSerialTapCount >= 3) {
      _beginLineSelection(localPosition, size, metrics);
      return;
    }
    if (_pendingSerialTapCount == 2) {
      _beginWordSelectionDrag(localPosition, size, metrics);
      return;
    }
    if (_selection != null) {
      _selectionSession.resetIgnoreNextTapClear();
    }
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.beginSelection(
      position: position,
      collapsedSelection: (position) =>
          GhosttyTerminalSelection(base: position, extent: position),
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = null;
    _dragSelectionGranularity = _TerminalSelectionGranularity.cell;
    _requestTerminalFocus();
    _setSelection(selection, touchSelectionHandlesVisible: false);
  }

  void _beginWordSelectionDrag(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.selectWord(
      position: position,
      resolveWordSelection: _resolveWordSelectionAt,
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = selection.normalized;
    _dragSelectionGranularity = _TerminalSelectionGranularity.word;
    _requestTerminalFocus();
    _setSelection(
      selection,
      touchSelectionHandlesVisible: _lastPointerKind == PointerDeviceKind.touch,
    );
    if (_lastPointerKind == PointerDeviceKind.touch) {
      _scheduleSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: localPosition,
      );
    }
  }

  void _updateSelection(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    final position = _positionForOffset(
      localPosition,
      size,
      metrics,
      clampToViewport: true,
    );
    final nextSelection = switch (_dragSelectionGranularity) {
      _TerminalSelectionGranularity.word => _extendWordSelection(position),
      _TerminalSelectionGranularity.line => _gestureCoordinator.updateSelection(
        currentSelection: _selection,
        position: position,
        extendSelection: (currentSelection, position) =>
            GhosttyTerminalSelection(
              base: currentSelection.base,
              extent: position,
            ),
        extendLineSelection: (anchorRow, position) =>
            _resolveLineSelectionBetweenRows(anchorRow, position.row),
      ),
      _TerminalSelectionGranularity.cell => _gestureCoordinator.updateSelection(
        currentSelection: _selection,
        position: position,
        extendSelection: (currentSelection, position) =>
            GhosttyTerminalSelection(
              base: currentSelection.base,
              extent: position,
            ),
        extendLineSelection: (anchorRow, position) =>
            _resolveLineSelectionBetweenRows(anchorRow, position.row),
      ),
    };
    if (nextSelection == null) {
      return;
    }
    _setSelection(nextSelection);
    _syncAutoScroll(localPosition, size, metrics);
  }

  GhosttyTerminalSelection? _extendWordSelection(
    GhosttyTerminalCellPosition? position,
  ) {
    final anchor = _wordSelectionAnchor;
    if (anchor == null || position == null) {
      return null;
    }
    final current = _resolveWordSelectionAt(position);
    if (current == null) {
      return null;
    }
    final anchorNormalized = anchor.normalized;
    final currentNormalized = current.normalized;
    final start = anchorNormalized.start.compareTo(currentNormalized.start) <= 0
        ? anchorNormalized.start
        : currentNormalized.start;
    final end = anchorNormalized.end.compareTo(currentNormalized.end) >= 0
        ? anchorNormalized.end
        : currentNormalized.end;
    return GhosttyTerminalSelection(base: start, extent: end);
  }

  void _selectWord(Offset localPosition, Size size, _TerminalMetrics metrics) {
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.completeWordSelection(
      position: position,
      resolveWordSelection: _resolveWordSelectionAt,
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = selection.normalized;
    _dragSelectionGranularity = _TerminalSelectionGranularity.word;
    _requestTerminalFocus();
    _setSelection(
      selection,
      touchSelectionHandlesVisible: _lastPointerKind == PointerDeviceKind.touch,
    );
  }

  void _beginLineSelection(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.beginLineSelection(
      position: position,
      rowOfPosition: (position) => position.row,
      resolveLineSelection: (position) =>
          _resolveLineSelectionBetweenRows(position.row, position.row),
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = null;
    _dragSelectionGranularity = _TerminalSelectionGranularity.line;
    if (_lastPointerKind == PointerDeviceKind.touch) {
      _touchSelectionActive = true;
    }
    _requestTerminalFocus();
    _setSelection(
      selection,
      touchSelectionHandlesVisible: _lastPointerKind == PointerDeviceKind.touch,
    );
    if (_lastPointerKind == PointerDeviceKind.touch) {
      _scheduleSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: localPosition,
      );
    }
    _syncAutoScroll(localPosition, size, metrics);
  }

  Widget _buildPointerGestureLayer({
    required Size size,
    required _TerminalMetrics metrics,
    required Widget child,
  }) {
    Widget result = child;

    if (widget.touchDragBehavior == GhosttyTerminalTouchDragBehavior.scroll) {
      result = GestureDetector(
        supportedDevices: _touchPointerDevices,
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (details) =>
            _beginLineSelection(details.localPosition, size, metrics),
        onLongPressMoveUpdate: (details) =>
            _updateSelection(details.localPosition, size, metrics),
        onLongPressEnd: (_) => _stopAutoScroll(),
        child: result,
      );
    }

    return GestureDetector(
      supportedDevices: _selectionDragDevices,
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (details) =>
          _beginLineSelection(details.localPosition, size, metrics),
      onLongPressMoveUpdate: (details) =>
          _updateSelection(details.localPosition, size, metrics),
      onLongPressEnd: (_) => _stopAutoScroll(),
      onPanDown: (details) =>
          _beginSelection(details.localPosition, size, metrics),
      onPanUpdate: (details) =>
          _updateSelection(details.localPosition, size, metrics),
      onPanEnd: (_) => _stopAutoScroll(),
      onPanCancel: _stopAutoScroll,
      child: result,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _measureMetrics();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _lastMeasuredLinePixels = metrics.linePixels;
        _autoScrollSession.updateLayout(layoutSize: size, metrics: metrics);
        _syncGrid(size, metrics);
        final viewport = _viewportFor(size, metrics);
        _lastVisibleStartLine = viewport.startLine;

        return Focus(
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: _handleKey,
          child: MouseRegion(
            cursor: _hoveredHyperlink == null
                ? SystemMouseCursors.text
                : SystemMouseCursors.click,
            onExit: (_) {
              if (ghosttyTerminalClearHoveredLink<GhosttyTerminalSelection>(
                session: _selectionSession,
              )) {
                setState(() {});
              }
            },
            onHover: (event) {
              if (!_terminalMouseReportingEnabled) {
                _updateHoveredHyperlink(event.localPosition, size, metrics);
              }
              _sendMouseEvent(
                GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
                event,
                size,
                metrics,
              );
            },
            child: Listener(
              onPointerDown: (event) {
                _lastPointerKind = event.kind;
                _startTouchScroll(event);
                _requestTerminalFocus();
                _sendMouseEvent(
                  GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
                  event,
                  size,
                  metrics,
                );
              },
              onPointerMove: (event) {
                _updateTouchScroll(event, size, metrics);
                _sendMouseEvent(
                  GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
                  event,
                  size,
                  metrics,
                );
              },
              onPointerUp: (event) {
                _endTouchScroll(event);
                _sendMouseEvent(
                  GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
                  event,
                  size,
                  metrics,
                );
              },
              onPointerCancel: (event) {
                _endTouchScroll(event);
                _sendMouseEvent(
                  GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
                  event,
                  size,
                  metrics,
                );
              },
              onPointerSignal: (event) =>
                  _handlePointerSignal(event, size, metrics),
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: <Type, GestureRecognizerFactory>{
                  SerialTapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        SerialTapGestureRecognizer
                      >(SerialTapGestureRecognizer.new, (recognizer) {
                        recognizer.onSerialTapDown = _recordSerialTapDown;
                        recognizer.onSerialTapUp = (details) =>
                            _handleSerialTapUp(details, size, metrics);
                      }),
                },
                child: _buildPointerGestureLayer(
                  size: size,
                  metrics: metrics,
                  child: Stack(
                    children: [
                      if (widget.showHeader)
                        SizedBox(
                          key: const ValueKey('terminalHeader'),
                          height: _terminalHeaderHeight,
                        ),
                      _buildScrollLayer(size, metrics, viewport),
                      RepaintBoundary(
                        child: CustomPaint(
                          key: const ValueKey('terminalPainter'),
                          painter: _GhosttyTerminalPainter(
                            revision: widget.controller.revision,
                            title: widget.controller.title,
                            snapshot: widget.controller.snapshot,
                            renderSnapshot: widget.controller.renderSnapshot,
                            renderer: widget.renderer,
                            running: widget.controller.isRunning,
                            focused: _focusNode.hasFocus,
                            cols: widget.controller.cols,
                            rows: widget.controller.rows,
                            scrollOffsetLines: _scrollOffsetLines,
                            visibleStartLine: viewport.startLine,
                            charWidth: metrics.charWidth,
                            linePixels: metrics.linePixels,
                            backgroundColor: widget.backgroundColor,
                            foregroundColor: widget.foregroundColor,
                            chromeColor: widget.chromeColor,
                            cursorColor: widget.cursorColor,
                            selectionColor: widget.selectionColor,
                            hyperlinkColor: widget.hyperlinkColor,
                            palette: widget.palette,
                            fontSize: widget.fontSize,
                            fontFamily: widget.fontFamily ?? 'monospace',
                            fontFamilyFallback: widget.fontFamilyFallback,
                            fontPackage: widget.fontPackage,
                            letterSpacing: widget.letterSpacing,
                            padding: widget.padding,
                            headerHeight: _headerHeight,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(
                              context,
                            ),
                            selection: _selection,
                            nativeRunPainterCache: _nativeRunPainterCache,
                            nativeRunIntrinsicWidthCache:
                                _nativeRunIntrinsicWidthCache,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      _buildSelectionHandleOverlay(size, metrics, viewport),
                      _buildScrollbarOverlay(size, metrics, viewport),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _renderSnapshotTextForSelection(
  GhosttyTerminalRenderSnapshot snapshot,
  GhosttyTerminalSelection selection, {
  required int viewportStartLine,
  required GhosttyTerminalCopyOptions options,
}) {
  if (!snapshot.hasViewportData) {
    return '';
  }

  final normalized = selection.normalized;
  final startRow = math.max(normalized.start.row, viewportStartLine);
  final endRow = math.min(
    normalized.end.row,
    viewportStartLine + snapshot.rowsData.length - 1,
  );
  if (endRow < startRow) {
    return '';
  }

  final buffer = StringBuffer();
  for (var row = startRow; row <= endRow; row++) {
    final localRow = row - viewportStartLine;
    final renderRow = snapshot.rowsData[localRow];
    final rowCellCount = renderRow.cells.fold<int>(
      0,
      (sum, cell) => sum + cell.width,
    );
    final startCol = row == startRow ? normalized.start.col : 0;
    final endCol = row == endRow ? normalized.end.col : rowCellCount - 1;
    if (rowCellCount > 0 && endCol >= startCol) {
      final text = _renderRowTextForCellRange(renderRow, startCol, endCol);
      buffer.write(options.trimTrailingSpaces ? text.trimRight() : text);
    }
    if (row != endRow) {
      final nextRow = snapshot.rowsData[localRow + 1];
      final joinsWrappedLine =
          options.joinWrappedLines &&
          renderRow.wrap &&
          nextRow.wrapContinuation;
      buffer.write(joinsWrappedLine ? options.wrappedLineJoiner : '\n');
    }
  }
  return buffer.toString();
}

String _renderRowTextForCellRange(
  GhosttyTerminalRenderRow row,
  int startCol,
  int endColInclusive,
) {
  if (endColInclusive < startCol) {
    return '';
  }

  final buffer = StringBuffer();
  var col = 0;
  for (final cell in row.cells) {
    final cellStart = col;
    final cellEnd = col + cell.width - 1;
    col += cell.width;
    if (cellEnd < startCol) {
      continue;
    }
    if (cellStart > endColInclusive) {
      break;
    }

    if (cell.text.isNotEmpty) {
      buffer.write(cell.text);
      continue;
    }

    final overlapStart = math.max(startCol, cellStart);
    final overlapEnd = math.min(endColInclusive, cellEnd);
    final overlapWidth = overlapEnd - overlapStart + 1;
    if (overlapWidth > 0) {
      buffer.write(' ' * overlapWidth);
    }
  }
  return buffer.toString();
}

String? _renderSnapshotHyperlinkAt(
  GhosttyTerminalRenderSnapshot snapshot,
  GhosttyTerminalCellPosition position, {
  required int viewportStartLine,
}) {
  if (!snapshot.hasViewportData) {
    return null;
  }

  final localRow = position.row - viewportStartLine;
  if (localRow < 0 || localRow >= snapshot.rowsData.length) {
    return null;
  }

  final segment = _renderSnapshotLogicalSegment(
    snapshot,
    localRow: localRow,
    viewportStartLine: viewportStartLine,
  );
  final targetSegmentCol = segment.rowCellOffsets[localRow]! + position.col;
  for (final match in _renderStateUrlPattern.allMatches(segment.text)) {
    final raw = match.group(0);
    if (raw == null || raw.isEmpty) {
      continue;
    }

    final trimmed = raw.replaceFirst(RegExp(r'[),.;:!?]+$'), '');
    if (trimmed.isEmpty) {
      continue;
    }

    final prefixCellCount = match.start;
    final linkCellCount = trimmed.length;
    final startCol = prefixCellCount;
    final endCol = startCol + linkCellCount - 1;
    if (targetSegmentCol >= startCol && targetSegmentCol <= endCol) {
      return trimmed;
    }
  }

  return null;
}

GhosttyTerminalSelection? _renderSnapshotWordSelectionAt(
  GhosttyTerminalRenderSnapshot snapshot,
  GhosttyTerminalCellPosition position, {
  required int viewportStartLine,
  required GhosttyTerminalWordBoundaryPolicy policy,
}) {
  if (!snapshot.hasViewportData) {
    return null;
  }

  final localRow = position.row - viewportStartLine;
  if (localRow < 0 || localRow >= snapshot.rowsData.length) {
    return null;
  }

  final segment = _renderSnapshotLogicalSegment(
    snapshot,
    localRow: localRow,
    viewportStartLine: viewportStartLine,
  );
  if (segment.cells.isEmpty) {
    return null;
  }

  final targetSegmentCol =
      (segment.rowCellOffsets[localRow] ?? 0) + position.col;
  final normalizedCol = targetSegmentCol.clamp(0, segment.cells.length - 1);
  final classification = _classifyRenderStateCharacter(
    segment.cells[normalizedCol],
    policy: policy,
  );
  var start = normalizedCol;
  var end = normalizedCol;
  while (start > 0 &&
      _classifyRenderStateCharacter(segment.cells[start - 1], policy: policy) ==
          classification) {
    start--;
  }
  while (end + 1 < segment.cells.length &&
      _classifyRenderStateCharacter(segment.cells[end + 1], policy: policy) ==
          classification) {
    end++;
  }

  final startPosition = _renderSnapshotSegmentPositionAtColumn(
    segment,
    segmentColumn: start,
    viewportStartLine: viewportStartLine,
  );
  final endPosition = _renderSnapshotSegmentPositionAtColumn(
    segment,
    segmentColumn: end,
    viewportStartLine: viewportStartLine,
  );
  if (startPosition == null || endPosition == null) {
    return null;
  }

  return GhosttyTerminalSelection(base: startPosition, extent: endPosition);
}

GhosttyTerminalSelection? _renderSnapshotLineSelectionBetweenRows(
  GhosttyTerminalRenderSnapshot snapshot,
  int baseRow,
  int extentRow, {
  required int viewportStartLine,
}) {
  if (!snapshot.hasViewportData || snapshot.rowsData.isEmpty) {
    return null;
  }

  final minRow = viewportStartLine;
  final maxRow = viewportStartLine + snapshot.rowsData.length - 1;
  final startRow = baseRow.clamp(minRow, maxRow);
  final endRow = extentRow.clamp(minRow, maxRow);
  var normalizedStart = math.min(startRow, endRow) - viewportStartLine;
  var normalizedEnd = math.max(startRow, endRow) - viewportStartLine;
  while (normalizedStart > 0 &&
      snapshot.rowsData[normalizedStart].wrapContinuation) {
    normalizedStart--;
  }
  while (normalizedEnd + 1 < snapshot.rowsData.length &&
      snapshot.rowsData[normalizedEnd].wrap) {
    normalizedEnd++;
  }
  final endCol = math.max(
    0,
    snapshot.rowsData[normalizedEnd].cells.fold<int>(
          0,
          (sum, cell) => sum + cell.width,
        ) -
        1,
  );
  return GhosttyTerminalSelection(
    base: GhosttyTerminalCellPosition(
      row: viewportStartLine + normalizedStart,
      col: 0,
    ),
    extent: GhosttyTerminalCellPosition(
      row: viewportStartLine + normalizedEnd,
      col: endCol,
    ),
  );
}

List<String> _renderRowWordCells(GhosttyTerminalRenderRow row) {
  final cells = <String>[];
  for (final cell in row.cells) {
    final text = cell.text.isNotEmpty ? cell.text : ' ';
    for (var i = 0; i < cell.width; i++) {
      cells.add(text);
    }
  }
  return cells;
}

_RenderSnapshotLogicalSegment _renderSnapshotLogicalSegment(
  GhosttyTerminalRenderSnapshot snapshot, {
  required int localRow,
  required int viewportStartLine,
}) {
  var start = localRow;
  while (start > 0 && snapshot.rowsData[start].wrapContinuation) {
    start--;
  }

  var end = localRow;
  while (end + 1 < snapshot.rowsData.length && snapshot.rowsData[end].wrap) {
    end++;
  }

  final buffer = StringBuffer();
  final cells = <String>[];
  final rowCellOffsets = <int, int>{};
  final rowCellCounts = <int, int>{};
  var runningOffset = 0;
  for (var row = start; row <= end; row++) {
    rowCellOffsets[row] = runningOffset;
    final rowCells = _renderRowWordCells(snapshot.rowsData[row]);
    rowCellCounts[row] = rowCells.length;
    for (final cell in rowCells) {
      buffer.write(cell);
      cells.add(cell);
    }
    runningOffset += rowCells.length;
  }

  return _RenderSnapshotLogicalSegment(
    text: buffer.toString(),
    cells: cells,
    rowCellOffsets: rowCellOffsets,
    rowCellCounts: rowCellCounts,
  );
}

GhosttyTerminalCellPosition? _renderSnapshotSegmentPositionAtColumn(
  _RenderSnapshotLogicalSegment segment, {
  required int segmentColumn,
  required int viewportStartLine,
}) {
  final orderedRows = segment.rowCellOffsets.keys.toList()..sort();
  for (final localRow in orderedRows) {
    final rowOffset = segment.rowCellOffsets[localRow] ?? 0;
    final rowCellCount = segment.rowCellCounts[localRow] ?? 0;
    if (rowCellCount <= 0) {
      continue;
    }
    if (segmentColumn >= rowOffset &&
        segmentColumn < rowOffset + rowCellCount) {
      return GhosttyTerminalCellPosition(
        row: viewportStartLine + localRow,
        col: segmentColumn - rowOffset,
      );
    }
  }
  return null;
}

_RenderStateCellClass _classifyRenderStateCharacter(
  String text, {
  required GhosttyTerminalWordBoundaryPolicy policy,
}) {
  if (text.trim().isEmpty) {
    return _RenderStateCellClass.whitespace;
  }
  if (_isRenderStateWordLikeCharacter(text, policy: policy)) {
    return _RenderStateCellClass.word;
  }
  return _RenderStateCellClass.other;
}

bool _isRenderStateWordLikeCharacter(
  String text, {
  required GhosttyTerminalWordBoundaryPolicy policy,
}) {
  final extra = policy.extraWordCharacters;
  for (final rune in text.runes) {
    if ((rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        extra.contains(String.fromCharCode(rune)) ||
        (policy.treatNonAsciiAsWord && rune > 0x7F)) {
      continue;
    }
    return false;
  }
  return true;
}

enum _RenderStateCellClass { whitespace, word, other }

final RegExp _renderStateUrlPattern = RegExp(
  r'''(https?:\/\/[^\s<>"']+|mailto:[^\s<>"']+)''',
);

final class _RenderSnapshotLogicalSegment {
  const _RenderSnapshotLogicalSegment({
    required this.text,
    required this.cells,
    required this.rowCellOffsets,
    required this.rowCellCounts,
  });

  final String text;
  final List<String> cells;
  final Map<int, int> rowCellOffsets;
  final Map<int, int> rowCellCounts;
}

class _TerminalSelectionHandlePainter extends CustomPainter {
  const _TerminalSelectionHandlePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;
    final stemTop = _selectionHandleVisualRadius;
    final stemBottom = stemTop + _selectionHandleStemHeight;
    canvas.drawLine(
      Offset(centerX, stemTop),
      Offset(centerX, stemBottom),
      strokePaint,
    );
    canvas.drawCircle(
      Offset(centerX, stemBottom + _selectionHandleVisualRadius),
      _selectionHandleVisualRadius,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _TerminalSelectionHandlePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _GhosttyTerminalPainter extends CustomPainter {
  _GhosttyTerminalPainter({
    required this.revision,
    required this.title,
    required this.snapshot,
    required this.renderSnapshot,
    required this.renderer,
    required this.running,
    required this.focused,
    required this.cols,
    required this.rows,
    required this.scrollOffsetLines,
    required this.visibleStartLine,
    required this.charWidth,
    required this.linePixels,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.chromeColor,
    required this.cursorColor,
    required this.selectionColor,
    required this.hyperlinkColor,
    required this.palette,
    required this.fontSize,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontPackage,
    required this.letterSpacing,
    required this.padding,
    required this.headerHeight,
    required this.devicePixelRatio,
    required this.selection,
    required this.nativeRunPainterCache,
    required this.nativeRunIntrinsicWidthCache,
  });

  final int revision;
  final String title;
  final GhosttyTerminalSnapshot snapshot;
  final GhosttyTerminalRenderSnapshot? renderSnapshot;
  final GhosttyTerminalRendererMode renderer;
  final bool running;
  final bool focused;
  final int cols;
  final int rows;
  final int scrollOffsetLines;
  final int visibleStartLine;
  final double charWidth;
  final double linePixels;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color chromeColor;
  final Color cursorColor;
  final Color selectionColor;
  final Color hyperlinkColor;
  final GhosttyTerminalPalette palette;
  final double fontSize;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final String? fontPackage;
  final double letterSpacing;
  final EdgeInsets padding;
  final double headerHeight;
  final double devicePixelRatio;
  final GhosttyTerminalSelection? selection;
  final _TerminalTextPainterCache nativeRunPainterCache;
  final _TerminalTextIntrinsicWidthCache nativeRunIntrinsicWidthCache;

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Offset.zero & size;
    canvas.drawRect(fullRect, Paint()..color = backgroundColor);

    if (headerHeight > 0) {
      final headerRect = Rect.fromLTWH(0, 0, size.width, headerHeight);
      canvas.drawRect(headerRect, Paint()..color = chromeColor);

      final dotColor = running
          ? const Color(0xFF2BD576)
          : const Color(0xFFD65C5C);
      canvas.drawCircle(
        Offset(12, headerHeight / 2),
        4,
        Paint()..color = dotColor,
      );

      final titlePainter = TextPainter(
        text: TextSpan(
          text: title,
          style: TextStyle(
            color: foregroundColor.withValues(alpha: 0.95),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: size.width - 140);
      titlePainter.paint(canvas, Offset(22, (headerHeight - 14) / 2));

      final status = [
        '${cols}x$rows${scrollOffsetLines > 0 ? '  +$scrollOffsetLines' : ''}',
        _widgetModeLabel(renderer, renderSnapshot, scrollOffsetLines),
      ].join('  •  ');
      final statusPainter = TextPainter(
        text: TextSpan(
          text: status,
          style: TextStyle(
            color: foregroundColor.withValues(alpha: 0.68),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width - 24);
      statusPainter.paint(
        canvas,
        Offset(size.width - statusPainter.width - 12, (headerHeight - 13) / 2),
      );
    }

    final contentTop = headerHeight + padding.top;
    final contentHeight = size.height - contentTop - padding.bottom;
    if (contentHeight <= 0) {
      return;
    }

    final maxVisible = math.max(1, (contentHeight / linePixels).floor());
    final maxOffset = math.max(0, snapshot.lines.length - maxVisible);
    final offset = scrollOffsetLines.clamp(0, maxOffset);
    final end = math.max(0, snapshot.lines.length - offset);
    final start = math.max(0, end - maxVisible);
    final visible = snapshot.lines.sublist(start, end);
    final contentRect = Rect.fromLTWH(
      padding.left,
      contentTop,
      size.width - padding.horizontal,
      contentHeight,
    );

    canvas.save();
    canvas.clipRect(contentRect);
    final nativeRender = renderSnapshot;
    if (renderer == GhosttyTerminalRendererMode.renderState &&
        nativeRender != null &&
        scrollOffsetLines == 0 &&
        nativeRender.hasViewportData) {
      // Respect widget defaults for the viewport baseline while still mapping
      // native explicit colors against Ghostty's original defaults.
      canvas.drawRect(contentRect, Paint()..color = backgroundColor);
      _paintNativeRenderState(
        canvas,
        contentTop: contentTop,
        visibleStartLine: start,
        defaultForeground: foregroundColor,
        defaultBackground: backgroundColor,
        nativeDefaultForeground: nativeRender.foregroundColor,
        nativeDefaultBackground: nativeRender.backgroundColor,
        linePixels: linePixels,
        rowsData: nativeRender.rowsData,
      );
      _paintNativeCursor(
        canvas,
        contentTop: contentTop,
        linePixels: linePixels,
        visibleRows: nativeRender.rowsData.length,
        cursor: nativeRender.cursor,
        color: cursorColor,
      );
      canvas.restore();
      if (focused) {
        final focusPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF2A83FF);
        canvas.drawRect(fullRect.deflate(0.5), focusPaint);
      }
      return;
    }

    for (var visibleIndex = 0; visibleIndex < visible.length; visibleIndex++) {
      final rowBand = _rowBand(
        contentTop: contentTop,
        rowIndex: visibleIndex,
        linePixels: linePixels,
        devicePixelRatio: devicePixelRatio,
      );
      final y = rowBand.top;
      final line = visible[visibleIndex];
      if (rowBand.top >= size.height) {
        break;
      }

      final row = start + visibleIndex;
      final resolvedStyles = line.runs
          .map(
            (run) => _ResolvedTerminalStyle.fromRun(
              run.style,
              palette: palette,
              defaultForeground: foregroundColor,
              defaultBackground: backgroundColor,
              hyperlinkColor: hyperlinkColor,
            ),
          )
          .toList(growable: false);
      var x = padding.left;
      for (var runIndex = 0; runIndex < line.runs.length; runIndex++) {
        final run = line.runs[runIndex];
        final style = resolvedStyles[runIndex];
        final width = run.cells * charWidth;
        if (style.background.a > 0) {
          canvas.drawRect(
            Rect.fromLTRB(x, rowBand.top, x + width, rowBand.bottom),
            Paint()..color = style.background,
          );
        }
        x += width;
      }

      _paintSelection(
        canvas,
        line: line,
        row: row,
        y: rowBand.top,
        rowHeight: rowBand.height,
      );

      x = padding.left;
      for (var runIndex = 0; runIndex < line.runs.length; runIndex++) {
        final run = line.runs[runIndex];
        final style = resolvedStyles[runIndex];
        final textStyle = style.toTextStyle(
          fontSize: fontSize,
          lineHeight: linePixels / fontSize,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          fontPackage: fontPackage,
          letterSpacing: letterSpacing,
        );
        var textX = x;
        final graphemes = _splitTerminalCells(run.text).toList(growable: false);
        final cellWidths = _measureTerminalCellWidths(run.text, run.cells);
        final canPaintAsSingleRun =
            graphemes.length == run.cells &&
            cellWidths.every((widthCells) => widthCells == 1) &&
            _isSafeSingleRunText(run.text) &&
            _shouldPaintTerminalRunAsSingleRun(
              text: run.text,
              width: run.cells * charWidth,
              fontWeight: style.fontWeight,
              fontStyle: style.fontStyle,
            );
        if (canPaintAsSingleRun) {
          final rect = Rect.fromLTWH(x, y, run.cells * charWidth, linePixels);
          final rowRect = Rect.fromLTRB(
            rect.left,
            rowBand.top,
            rect.right,
            rowBand.bottom,
          );
          final painter = nativeRunPainterCache.resolve(
            _TerminalTextPainterKey(
              text: run.text,
              width: rect.width,
              fontSize: fontSize,
              lineHeight: linePixels / fontSize,
              fontFamily: fontFamily,
              fontFamilyFallback: fontFamilyFallback,
              fontPackage: fontPackage,
              letterSpacing: letterSpacing,
              color: style.foreground,
              fontWeight: style.fontWeight,
              fontStyle: style.fontStyle,
              decoration: style.decoration,
              decorationStyle: style.decorationStyle,
              decorationColor: style.decorationColor,
            ),
          );
          canvas.save();
          canvas.clipRect(rowRect);
          painter.paint(canvas, Offset(rowRect.left, rowBand.top));
          canvas.restore();
        } else {
          for (var index = 0; index < graphemes.length; index++) {
            final character = graphemes[index];
            final widthCells = cellWidths[index];
            final width = widthCells * charWidth;
            final rect = Rect.fromLTRB(
              textX,
              rowBand.top,
              textX + width,
              rowBand.bottom,
            );
            if (widthCells == 1 &&
                _paintTerminalSpecialGlyph(
                  canvas,
                  character,
                  rect: rect,
                  color: style.foreground,
                )) {
              textX += width;
              continue;
            }
            _debugLogUnsupportedGlyph(character);
            final painter = TextPainter(
              text: TextSpan(text: character, style: textStyle),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout();
            painter.paint(
              canvas,
              _centerGlyphInCell(
                painter,
                character,
                cellRect: rect,
                fallbackHeight: rowBand.height,
              ),
            );
            textX += width;
          }
        }
        x += run.cells * charWidth;
      }
    }

    final shouldPaintNativeCursor =
        scrollOffsetLines == 0 &&
        nativeRender != null &&
        nativeRender.hasViewportData;
    if (shouldPaintNativeCursor) {
      _paintNativeCursor(
        canvas,
        contentTop: contentTop,
        linePixels: linePixels,
        visibleRows: nativeRender.rowsData.length,
        cursor: nativeRender.cursor,
        color: cursorColor,
      );
    } else {
      final shouldPaintSnapshotCursor =
          snapshot.cursor != null && scrollOffsetLines == 0;
      final cursor = shouldPaintSnapshotCursor ? snapshot.cursor : null;
      if (cursor != null) {
        final cursorLine = cursor.row - start;
        if (cursorLine >= 0 && cursorLine < visible.length) {
          final cursorRowBand = _rowBand(
            contentTop: contentTop,
            rowIndex: cursorLine,
            linePixels: linePixels,
            devicePixelRatio: devicePixelRatio,
          );
          final cursorRect = Rect.fromLTWH(
            padding.left + (cursor.col * charWidth),
            cursorRowBand.top,
            charWidth,
            cursorRowBand.height,
          );
          if (focused) {
            canvas.drawRect(
              cursorRect,
              Paint()..color = cursorColor.withValues(alpha: 0.78),
            );
          }
          canvas.drawRect(
            cursorRect.deflate(0.5),
            Paint()
              ..color = cursorColor.withValues(alpha: focused ? 1 : 0.88)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
      }
    }
    canvas.restore();

    if (focused) {
      final focusPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF2A83FF);
      canvas.drawRect(fullRect.deflate(0.5), focusPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GhosttyTerminalPainter oldDelegate) {
    return revision != oldDelegate.revision ||
        title != oldDelegate.title ||
        running != oldDelegate.running ||
        focused != oldDelegate.focused ||
        cols != oldDelegate.cols ||
        rows != oldDelegate.rows ||
        scrollOffsetLines != oldDelegate.scrollOffsetLines ||
        visibleStartLine != oldDelegate.visibleStartLine ||
        charWidth != oldDelegate.charWidth ||
        linePixels != oldDelegate.linePixels ||
        fontSize != oldDelegate.fontSize ||
        fontFamily != oldDelegate.fontFamily ||
        !listEquals(fontFamilyFallback, oldDelegate.fontFamilyFallback) ||
        fontPackage != oldDelegate.fontPackage ||
        letterSpacing != oldDelegate.letterSpacing ||
        padding != oldDelegate.padding ||
        headerHeight != oldDelegate.headerHeight ||
        devicePixelRatio != oldDelegate.devicePixelRatio ||
        backgroundColor != oldDelegate.backgroundColor ||
        foregroundColor != oldDelegate.foregroundColor ||
        chromeColor != oldDelegate.chromeColor ||
        cursorColor != oldDelegate.cursorColor ||
        selectionColor != oldDelegate.selectionColor ||
        hyperlinkColor != oldDelegate.hyperlinkColor ||
        palette != oldDelegate.palette ||
        selection != oldDelegate.selection ||
        renderer != oldDelegate.renderer ||
        !_renderSnapshotEquals(renderSnapshot, oldDelegate.renderSnapshot) ||
        !listEquals(snapshot.lines, oldDelegate.snapshot.lines) ||
        snapshot.cursor != oldDelegate.snapshot.cursor;
  }

  void _paintNativeRenderState(
    Canvas canvas, {
    required double contentTop,
    required int visibleStartLine,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
    required double linePixels,
    required List<GhosttyTerminalRenderRow> rowsData,
  }) {
    for (var rowIndex = 0; rowIndex < rowsData.length; rowIndex++) {
      final row = rowsData[rowIndex];
      final rowBand = _rowBand(
        contentTop: contentTop,
        rowIndex: rowIndex,
        linePixels: linePixels,
        devicePixelRatio: devicePixelRatio,
      );
      final y = rowBand.top;
      final logicalRow = visibleStartLine + rowIndex;
      final runs = _collectNativeRuns(
        row.cells,
        defaultForeground: defaultForeground,
        defaultBackground: defaultBackground,
        nativeDefaultForeground: nativeDefaultForeground,
        nativeDefaultBackground: nativeDefaultBackground,
      );
      for (final run in runs) {
        if (run.width <= 0) {
          continue;
        }
        final width = run.width * charWidth;
        final rect = Rect.fromLTWH(
          padding.left + (run.startCol * charWidth),
          rowBand.top,
          width,
          rowBand.height,
        );
        if (run.background.a > 0) {
          canvas.drawRect(rect, Paint()..color = run.background);
        }
      }
      _paintNativeSelection(
        canvas,
        row: logicalRow,
        cellCount: row.cells.fold<int>(0, (sum, cell) => sum + cell.width),
        y: rowBand.top,
        rowHeight: rowBand.height,
      );
      for (final run in runs) {
        if (run.width <= 0) {
          continue;
        }
        final width = run.width * charWidth;
        final startCol = run.startCol;
        final rect = Rect.fromLTWH(
          padding.left + (startCol * charWidth),
          rowBand.top,
          width,
          rowBand.height,
        );
        if (run.hasRenderableText) {
          final foreground = _resolveNativeForeground(
            style: run.style,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            nativeDefaultForeground: nativeDefaultForeground,
            nativeDefaultBackground: nativeDefaultBackground,
            metadataColor: _resolveMetadataBackgroundColor(
              metadata: run.metadata,
              fallback: run.metadataBackground,
            ),
            hasHyperlink: run.hasHyperlink,
          );
          final textForeground =
              !run.style.hasExplicitForeground && run.hasHyperlink
              ? hyperlinkColor
              : foreground;
          final decorationColor = run.style.hasExplicitUnderlineColor
              ? run.style.underlineColor
              : textForeground;
          final textStyle = TextStyle(
            color: textForeground,
            fontFamily: fontFamily,
            fontFamilyFallback: fontFamilyFallback,
            package: fontPackage,
            fontSize: fontSize,
            height: linePixels / fontSize,
            letterSpacing: letterSpacing,
            fontWeight: run.style.bold ? FontWeight.w700 : FontWeight.w400,
            fontStyle: run.style.italic ? FontStyle.italic : FontStyle.normal,
            decoration: _nativeTextDecoration(
              style: run.style,
              hasHyperlink: run.hasHyperlink,
            ),
            decorationStyle: _nativeDecorationStyle(
              underline: run.style.underline,
              hasHyperlink: run.hasHyperlink,
            ),
            decorationColor: decorationColor,
          );
          final graphemes = _splitTerminalCells(
            run.text,
          ).toList(growable: false);
          if (graphemes.isNotEmpty) {
            final graphemeWidths =
                run.graphemeCellWidths.length == graphemes.length
                ? run.graphemeCellWidths
                : _measureTerminalCellWidths(run.text, run.width);
            final canPaintAsSingleRun =
                graphemes.length == run.width &&
                graphemeWidths.every((widthCells) => widthCells == 1) &&
                _isSafeSingleRunText(run.text) &&
                _shouldPaintTerminalRunAsSingleRun(
                  text: run.text,
                  width: run.width * charWidth,
                  fontWeight: run.style.bold
                      ? FontWeight.w700
                      : FontWeight.w400,
                  fontStyle: run.style.italic
                      ? FontStyle.italic
                      : FontStyle.normal,
                );
            if (canPaintAsSingleRun) {
              final painter = nativeRunPainterCache.resolve(
                _TerminalTextPainterKey(
                  text: run.text,
                  width: rect.width,
                  fontSize: fontSize,
                  lineHeight: linePixels / fontSize,
                  fontFamily: fontFamily,
                  fontFamilyFallback: fontFamilyFallback,
                  fontPackage: fontPackage,
                  letterSpacing: letterSpacing,
                  color: textForeground,
                  fontWeight: run.style.bold
                      ? FontWeight.w700
                      : FontWeight.w400,
                  fontStyle: run.style.italic
                      ? FontStyle.italic
                      : FontStyle.normal,
                  decoration: _nativeTextDecoration(
                    style: run.style,
                    hasHyperlink: run.hasHyperlink,
                  ),
                  decorationStyle: _nativeDecorationStyle(
                    underline: run.style.underline,
                    hasHyperlink: run.hasHyperlink,
                  ),
                  decorationColor: decorationColor,
                ),
              );
              canvas.save();
              canvas.clipRect(rect);
              painter.paint(canvas, Offset(rect.left, y));
              canvas.restore();
            } else {
              var textX = rect.left;
              for (var index = 0; index < graphemes.length; index++) {
                final character = graphemes[index];
                final widthCells = index < graphemeWidths.length
                    ? graphemeWidths[index]
                    : 1;
                final cellWidth = widthCells * charWidth;
                final rect = Rect.fromLTRB(
                  textX,
                  rowBand.top,
                  textX + cellWidth,
                  rowBand.bottom,
                );
                if (widthCells == 1 &&
                    _paintTerminalSpecialGlyph(
                      canvas,
                      character,
                      rect: rect,
                      color: textForeground,
                    )) {
                  textX += cellWidth;
                  continue;
                }
                _debugLogUnsupportedGlyph(character);
                final painter = TextPainter(
                  text: TextSpan(text: character, style: textStyle),
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                )..layout();
                painter.paint(
                  canvas,
                  _centerGlyphInCell(
                    painter,
                    character,
                    cellRect: rect,
                    fallbackHeight: rowBand.height,
                  ),
                );
                textX += cellWidth;
              }
            }
          }
        }
      }
    }
  }

  void _paintNativeCursor(
    Canvas canvas, {
    required double contentTop,
    required double linePixels,
    required int visibleRows,
    required GhosttyTerminalRenderCursor cursor,
    required Color color,
  }) {
    if (!cursor.visible ||
        !cursor.hasViewportPosition ||
        cursor.row == null ||
        cursor.col == null) {
      return;
    }
    if (cursor.row! < 0 || cursor.row! >= visibleRows) {
      return;
    }
    if (cursor.col! < 0 || cursor.col! >= cols) {
      return;
    }
    final widthCells = cursor.onWideTail ? 2 : 1;
    final startCol = cursor.onWideTail
        ? math.max(0, cursor.col! - 1)
        : cursor.col!;
    final rowBand = _rowBand(
      contentTop: contentTop,
      rowIndex: cursor.row!,
      linePixels: linePixels,
      devicePixelRatio: devicePixelRatio,
    );
    final cursorRect = Rect.fromLTWH(
      padding.left + (startCol * charWidth),
      rowBand.top,
      charWidth * widthCells,
      rowBand.height,
    );
    final snappedCursorLeft = _snapLogicalToPhysical(
      cursorRect.left,
      devicePixelRatio,
    );
    final snappedCursorWidth = _snapLogicalExtentToPhysical(
      cursorRect.width,
      devicePixelRatio,
    );
    final shouldShowCursorFill = focused || !cursor.blinking;
    final drawColor = color.withValues(
      alpha: cursor.passwordInput ? 0.95 : (focused ? 0.95 : 0.8),
    );
    final strokeColor = drawColor.withValues(alpha: 0.85);
    final fillPaint = Paint()..color = drawColor;
    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, linePixels * 0.08);

    final barWidth = _snapLogicalExtentToPhysical(
      math.max(2.0, charWidth * 0.2),
      devicePixelRatio,
    );
    final underlineHeight = _snapLogicalExtentToPhysical(
      math.max(1.5, linePixels * 0.12),
      devicePixelRatio,
    );
    final shapeRect = switch (cursor.visualStyle) {
      GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR =>
        Rect.fromLTWH(snappedCursorLeft, rowBand.top, barWidth, rowBand.height),
      GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE =>
        Rect.fromLTWH(
          snappedCursorLeft,
          _snapLogicalToPhysical(
            cursorRect.bottom - underlineHeight,
            devicePixelRatio,
          ),
          snappedCursorWidth,
          underlineHeight,
        ),
      GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW =>
        cursorRect,
      _ => cursorRect,
    };

    switch (cursor.visualStyle) {
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
        canvas.drawRect(
          shapeRect,
          Paint()
            ..color = drawColor.withValues(alpha: 0.22)
            ..style = PaintingStyle.fill,
        );
        if (shouldShowCursorFill) {
          canvas.drawRect(shapeRect.deflate(0.5), strokePaint);
        }
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
        if (shouldShowCursorFill) {
          canvas.drawRect(shapeRect, fillPaint);
        }
        canvas.drawRect(shapeRect, strokePaint);
    }
  }

  List<_NativeRenderRun> _collectNativeRuns(
    List<GhosttyTerminalRenderCell> cells, {
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
  }) {
    if (cells.isEmpty) {
      return const <_NativeRenderRun>[];
    }
    final runs = <_NativeRenderRun>[];
    var runStart = 0;
    var runStartCol = 0;
    var runWidth = 0;
    final runText = StringBuffer();
    final runGraphemeCellWidths = <int>[];
    void flushCurrentRun() {
      final firstCell = cells[runStart];
      final firstStyleColors = _resolveNativeStyleColors(
        style: firstCell.style,
        defaultForeground: defaultForeground,
        defaultBackground: defaultBackground,
        nativeDefaultForeground: nativeDefaultForeground,
        nativeDefaultBackground: nativeDefaultBackground,
        metadataColor: _resolveMetadataBackgroundColor(
          metadata: firstCell.metadata,
          fallback: firstCell.metadata.backgroundColor,
        ),
      );
      final firstBackground = firstStyleColors.background;
      final text = runText.toString();
      runs.add(
        _NativeRenderRun(
          style: firstCell.style,
          background: firstBackground,
          metadata: firstCell.metadata,
          metadataBackground: firstCell.metadata.backgroundColor,
          startCol: runStartCol,
          width: runWidth,
          text: text,
          graphemeCellWidths: List<int>.unmodifiable(runGraphemeCellWidths),
          hasHyperlink: firstCell.hasHyperlink,
          hasRenderableText: text.isNotEmpty,
        ),
      );
      runStartCol += runWidth;
      runWidth = 0;
      runText.clear();
      runGraphemeCellWidths.clear();
    }

    for (var index = 0; index < cells.length; index++) {
      final currentCell = cells[index];
      final shouldStartNewRun =
          index > runStart &&
          !_nativeRenderRunCanMerge(
            cells[index - 1],
            currentCell,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            nativeDefaultForeground: nativeDefaultForeground,
            nativeDefaultBackground: nativeDefaultBackground,
          );
      if (shouldStartNewRun) {
        flushCurrentRun();
        runStart = index;
      }

      runWidth += currentCell.width;
      if (currentCell.text.isNotEmpty) {
        runText.write(currentCell.text);
        runGraphemeCellWidths.add(currentCell.width);
      }

      if (index == cells.length - 1) {
        flushCurrentRun();
        break;
      }
    }
    return runs;
  }

  bool _nativeRenderRunCanMerge(
    GhosttyTerminalRenderCell previous,
    GhosttyTerminalRenderCell next, {
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
  }) {
    final previousHasRenderableText = previous.text.isNotEmpty;
    final nextHasRenderableText = next.text.isNotEmpty;
    if (previousHasRenderableText != nextHasRenderableText) {
      return false;
    }

    return _nativeRenderStyleEquals(previous.style, next.style) &&
        _resolvedNativeBackground(
              metadataColor: _resolveMetadataBackgroundColor(
                metadata: previous.metadata,
                fallback: previous.metadata.backgroundColor,
              ),
              style: previous.style,
              defaultForeground: defaultForeground,
              defaultBackground: defaultBackground,
              nativeDefaultForeground: nativeDefaultForeground,
              nativeDefaultBackground: nativeDefaultBackground,
            ) ==
            _resolvedNativeBackground(
              metadataColor: _resolveMetadataBackgroundColor(
                metadata: next.metadata,
                fallback: next.metadata.backgroundColor,
              ),
              style: next.style,
              defaultForeground: defaultForeground,
              defaultBackground: defaultBackground,
              nativeDefaultForeground: nativeDefaultForeground,
              nativeDefaultBackground: nativeDefaultBackground,
            ) &&
        previous.hasHyperlink == next.hasHyperlink;
  }

  Color _resolveNativeForeground({
    required GhosttyTerminalResolvedStyle style,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
    Color? metadataColor,
    required bool hasHyperlink,
  }) {
    final resolved = _resolveNativeStyleColors(
      style: style,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      nativeDefaultForeground: nativeDefaultForeground,
      nativeDefaultBackground: nativeDefaultBackground,
      metadataColor: metadataColor,
    );
    if (hasHyperlink && !style.hasExplicitForeground) {
      return hyperlinkColor;
    }
    return resolved.foreground;
  }

  ({Color foreground, Color background}) _resolveNativeStyleColors({
    required GhosttyTerminalResolvedStyle style,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
    Color? metadataColor,
  }) {
    final resolved = GhosttyTerminalResolvedStyle.resolveNativeStyleColors(
      style: style,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      metadataColor: metadataColor,
    );
    final foreground =
        !style.hasExplicitForeground &&
            style.foreground == nativeDefaultForeground
        ? defaultForeground
        : resolved.foreground;
    final background =
        metadataColor == null &&
            !style.hasExplicitBackground &&
            style.background == nativeDefaultBackground
        ? Colors.transparent
        : resolved.background;
    return (foreground: foreground, background: background);
  }

  Color _resolvedNativeBackground({
    Color? metadataColor,
    required GhosttyTerminalResolvedStyle style,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
  }) {
    return _resolveNativeStyleColors(
      style: style,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      nativeDefaultForeground: nativeDefaultForeground,
      nativeDefaultBackground: nativeDefaultBackground,
      metadataColor: metadataColor,
    ).background;
  }

  Color? _resolveMetadataBackgroundColor({
    required GhosttyTerminalRenderCellMetadata metadata,
    Color? fallback,
  }) {
    return metadata.backgroundColor ?? fallback;
  }

  bool _nativeRenderStyleEquals(
    GhosttyTerminalResolvedStyle a,
    GhosttyTerminalResolvedStyle b,
  ) {
    return a.foreground == b.foreground &&
        a.background == b.background &&
        a.underlineColor == b.underlineColor &&
        a.hasExplicitUnderlineColor == b.hasExplicitUnderlineColor &&
        a.hasExplicitForeground == b.hasExplicitForeground &&
        a.hasExplicitBackground == b.hasExplicitBackground &&
        a.bold == b.bold &&
        a.italic == b.italic &&
        a.inverse == b.inverse &&
        a.invisible == b.invisible &&
        a.faint == b.faint &&
        a.blink == b.blink &&
        a.overline == b.overline &&
        a.strikethrough == b.strikethrough &&
        a.underline == b.underline;
  }

  TextDecoration _nativeTextDecoration({
    required GhosttyTerminalResolvedStyle style,
    required bool hasHyperlink,
  }) {
    final decorations = <TextDecoration>[];
    if (style.underline != GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE) {
      decorations.add(TextDecoration.underline);
    }
    if (hasHyperlink &&
        (style.underline == GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE)) {
      decorations.add(TextDecoration.underline);
    }
    if (style.overline) {
      decorations.add(TextDecoration.overline);
    }
    if (style.strikethrough) {
      decorations.add(TextDecoration.lineThrough);
    }
    return decorations.isEmpty
        ? TextDecoration.none
        : TextDecoration.combine(decorations);
  }

  TextDecorationStyle _nativeDecorationStyle({
    required GhosttySgrUnderline underline,
    required bool hasHyperlink,
  }) {
    if (hasHyperlink &&
        underline == GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE) {
      return TextDecorationStyle.solid;
    }
    return switch (underline) {
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOUBLE =>
        TextDecorationStyle.double,
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_CURLY =>
        TextDecorationStyle.wavy,
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOTTED =>
        TextDecorationStyle.dotted,
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DASHED =>
        TextDecorationStyle.dashed,
      _ => TextDecorationStyle.solid,
    };
  }

  void _paintSelection(
    Canvas canvas, {
    required GhosttyTerminalLine line,
    required int row,
    required double y,
    required double rowHeight,
  }) {
    final selection = this.selection;
    if (selection == null || line.cellCount == 0) {
      return;
    }
    final normalized = selection.normalized;
    if (row < normalized.start.row || row > normalized.end.row) {
      return;
    }

    final startCol = row == normalized.start.row ? normalized.start.col : 0;
    final endCol = row == normalized.end.row
        ? normalized.end.col
        : line.cellCount - 1;
    if (endCol < startCol) {
      return;
    }
    final left = padding.left + (startCol * charWidth);
    final width = (endCol - startCol + 1) * charWidth;
    canvas.drawRect(
      Rect.fromLTWH(left, y, width, rowHeight),
      Paint()..color = selectionColor,
    );
  }

  void _paintNativeSelection(
    Canvas canvas, {
    required int row,
    required int cellCount,
    required double y,
    required double rowHeight,
  }) {
    final selection = this.selection;
    if (selection == null || cellCount <= 0) {
      return;
    }
    final normalized = selection.normalized;
    if (row < normalized.start.row || row > normalized.end.row) {
      return;
    }

    final startCol = row == normalized.start.row ? normalized.start.col : 0;
    final endCol = row == normalized.end.row
        ? normalized.end.col
        : cellCount - 1;
    if (endCol < startCol) {
      return;
    }
    final left = padding.left + (startCol * charWidth);
    final width = (endCol - startCol + 1) * charWidth;
    canvas.drawRect(
      Rect.fromLTWH(left, y, width, rowHeight),
      Paint()..color = selectionColor,
    );
  }

  bool _shouldPaintTerminalRunAsSingleRun({
    required String text,
    required double width,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
  }) {
    if (text.isEmpty) {
      return false;
    }

    final measuredWidth = nativeRunIntrinsicWidthCache.resolve(
      _TerminalIntrinsicWidthKey(
        text: text,
        fontSize: fontSize,
        lineHeight: linePixels / fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontPackage: fontPackage,
        letterSpacing: letterSpacing,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
      ),
    );

    return (measuredWidth - width).abs() <= 0.75;
  }

  bool _paintTerminalSpecialGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    return _paintTerminalBoxDrawingGlyph(
          canvas,
          text,
          rect: rect,
          color: color,
        ) ||
        _paintTerminalBlockGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalBrailleGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalGeometricGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalRaisedTextGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalSymbolGlyph(canvas, text, rect: rect, color: color);
  }

  bool _paintTerminalBoxDrawingGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalBoxDrawingSpec(rune);
    if (spec == null) {
      return false;
    }

    final horizontalStroke = _boxDrawingStrokeWidth(
      rect,
      heavy: spec.heavyHorizontal,
      devicePixelRatio: devicePixelRatio,
    );
    final verticalStroke = _boxDrawingStrokeWidth(
      rect,
      heavy: spec.heavyVertical,
      devicePixelRatio: devicePixelRatio,
    );
    final centerX = _pixelSnapAxis(
      rect.left + (rect.width / 2),
      verticalStroke,
      devicePixelRatio: devicePixelRatio,
    );
    final centerY = _pixelSnapAxis(
      rect.top + _boxDrawingCenterYOffset(rect, spec),
      horizontalStroke,
      devicePixelRatio: devicePixelRatio,
    );
    final left = _snapLogicalToPhysical(rect.left, devicePixelRatio);
    final right = _snapLogicalToPhysical(rect.right, devicePixelRatio);
    final top = _snapLogicalToPhysical(rect.top, devicePixelRatio);
    final bottom = _snapLogicalToPhysical(rect.bottom, devicePixelRatio);

    final horizontalPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = horizontalStroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;
    final verticalPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = verticalStroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;

    if (spec.rounded && ((spec.left || spec.right) && (spec.up || spec.down))) {
      final radius = math.min(rect.width, rect.height) * 0.45;
      final path = Path();
      if (spec.right && spec.down) {
        path
          ..moveTo(right, centerY)
          ..lineTo(centerX + radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY + radius)
          ..lineTo(centerX, bottom);
      } else if (spec.left && spec.down) {
        path
          ..moveTo(left, centerY)
          ..lineTo(centerX - radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY + radius)
          ..lineTo(centerX, bottom);
      } else if (spec.right && spec.up) {
        path
          ..moveTo(right, centerY)
          ..lineTo(centerX + radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY - radius)
          ..lineTo(centerX, top);
      } else if (spec.left && spec.up) {
        path
          ..moveTo(left, centerY)
          ..lineTo(centerX - radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY - radius)
          ..lineTo(centerX, top);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(horizontalStroke, verticalStroke)
          ..strokeCap = StrokeCap.butt
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
      return true;
    }

    if ((spec.left || spec.right) && !(spec.up || spec.down)) {
      canvas.drawLine(
        Offset(spec.left ? left : centerX, centerY),
        Offset(spec.right ? right : centerX, centerY),
        horizontalPaint,
      );
      return true;
    }

    if ((spec.up || spec.down) && !(spec.left || spec.right)) {
      canvas.drawLine(
        Offset(centerX, spec.up ? top : centerY),
        Offset(centerX, spec.down ? bottom : centerY),
        verticalPaint,
      );
      return true;
    }

    if ((spec.left || spec.right) && (spec.up || spec.down)) {
      if (spec.left && !spec.right && spec.down && !spec.up) {
        canvas.drawLine(
          Offset(left, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, bottom),
          verticalPaint,
        );
        return true;
      }
      if (spec.right && !spec.left && spec.down && !spec.up) {
        canvas.drawLine(
          Offset(right, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, bottom),
          verticalPaint,
        );
        return true;
      }
      if (spec.left && !spec.right && spec.up && !spec.down) {
        canvas.drawLine(
          Offset(left, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, top),
          verticalPaint,
        );
        return true;
      }
      if (spec.right && !spec.left && spec.up && !spec.down) {
        canvas.drawLine(
          Offset(right, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, top),
          verticalPaint,
        );
        return true;
      }
    }

    if (spec.left || spec.right) {
      canvas.drawLine(
        Offset(spec.left ? left : centerX, centerY),
        Offset(spec.right ? right : centerX, centerY),
        horizontalPaint,
      );
    }
    if (spec.up || spec.down) {
      canvas.drawLine(
        Offset(centerX, spec.up ? top : centerY),
        Offset(centerX, spec.down ? bottom : centerY),
        verticalPaint,
      );
    }

    return true;
  }

  bool _paintTerminalGeometricGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalGeometricGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final diameter = math.min(rect.width, rect.height) * spec.diameterScale;
    final glyphRect = Rect.fromCenter(
      center: Offset(
        rect.left + (rect.width / 2),
        rect.top + (rect.height / 2),
      ),
      width: diameter,
      height: diameter,
    );
    final paint = Paint()
      ..color = color
      ..style = spec.filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = spec.filled
          ? 0
          : math.max(1.0, diameter * spec.strokeScale)
      ..isAntiAlias = true;
    canvas.drawOval(glyphRect, paint);
    return true;
  }

  bool _paintTerminalRaisedTextGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalRaisedTextGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final painter = TextPainter(
      text: TextSpan(
        text: spec.text,
        style: TextStyle(
          color: color,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          package: fontPackage,
          fontSize: fontSize * spec.fontScale,
          height: 1,
          letterSpacing: letterSpacing,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final dx = rect.left + _centeredGlyphOffset(rect.width, painter.width);
    final dy =
        rect.top +
        (rect.height * spec.topOffsetScale) +
        _centeredGlyphOffset(
          rect.height * spec.verticalSpaceScale,
          painter.height,
        );
    painter.paint(canvas, Offset(dx, dy));
    return true;
  }

  bool _paintTerminalSymbolGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalSymbolGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final left = _snapLogicalToPhysical(rect.left, devicePixelRatio);
    final right = _snapLogicalToPhysical(rect.right, devicePixelRatio);
    final top = _snapLogicalToPhysical(rect.top, devicePixelRatio);
    final bottom = _snapLogicalToPhysical(rect.bottom, devicePixelRatio);
    final width = right - left;
    final height = bottom - top;
    final strokeWidth = math.max(
      1.0 / math.max(devicePixelRatio, 1.0),
      math.min(width, height) * spec.strokeScale,
    );
    final centerX = _pixelSnapAxis(
      rect.left + (rect.width / 2),
      strokeWidth,
      devicePixelRatio: devicePixelRatio,
    );
    final centerY = _pixelSnapAxis(
      rect.top + (rect.height / 2),
      strokeWidth,
      devicePixelRatio: devicePixelRatio,
    );
    final paint = Paint()
      ..color = color
      ..style = spec.filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (spec.kind) {
      case _TerminalSymbolGlyphKind.downTriangle:
        final path = Path()
          ..moveTo(centerX, top + (height * 0.8))
          ..lineTo(left + (width * 0.22), top + (height * 0.28))
          ..lineTo(right - (width * 0.22), top + (height * 0.28))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.upTriangle:
        final path = Path()
          ..moveTo(centerX, top + (height * 0.2))
          ..lineTo(left + (width * 0.22), bottom - (height * 0.28))
          ..lineTo(right - (width * 0.22), bottom - (height * 0.28))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.leftTriangle:
        final path = Path()
          ..moveTo(left + (width * 0.2), centerY)
          ..lineTo(right - (width * 0.28), top + (height * 0.22))
          ..lineTo(right - (width * 0.28), bottom - (height * 0.22))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.rightTriangle:
        final path = Path()
          ..moveTo(right - (width * 0.2), centerY)
          ..lineTo(left + (width * 0.28), top + (height * 0.22))
          ..lineTo(left + (width * 0.28), bottom - (height * 0.22))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.square:
        final insetX = width * 0.2;
        final insetY = height * 0.2;
        canvas.drawRect(
          Rect.fromLTRB(
            left + insetX,
            top + insetY,
            right - insetX,
            bottom - insetY,
          ),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.rightArrow:
        final startX = left + (width * 0.18);
        final endX = right - (width * 0.22);
        final arrowTopY = centerY - (height * 0.18);
        final arrowBottomY = centerY + (height * 0.18);
        canvas.drawLine(Offset(startX, centerY), Offset(endX, centerY), paint);
        canvas.drawLine(
          Offset(endX - (width * 0.18), arrowTopY),
          Offset(endX, centerY),
          paint,
        );
        canvas.drawLine(
          Offset(endX - (width * 0.18), arrowBottomY),
          Offset(endX, centerY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.leftArrow:
        final startX = right - (width * 0.18);
        final endX = left + (width * 0.22);
        final arrowTopY = centerY - (height * 0.18);
        final arrowBottomY = centerY + (height * 0.18);
        canvas.drawLine(Offset(startX, centerY), Offset(endX, centerY), paint);
        canvas.drawLine(
          Offset(endX + (width * 0.18), arrowTopY),
          Offset(endX, centerY),
          paint,
        );
        canvas.drawLine(
          Offset(endX + (width * 0.18), arrowBottomY),
          Offset(endX, centerY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.upArrow:
        final startY = bottom - (height * 0.18);
        final endY = top + (height * 0.22);
        final arrowLeftX = centerX - (width * 0.18);
        final arrowRightX = centerX + (width * 0.18);
        canvas.drawLine(Offset(centerX, startY), Offset(centerX, endY), paint);
        canvas.drawLine(
          Offset(arrowLeftX, endY + (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        canvas.drawLine(
          Offset(arrowRightX, endY + (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.downArrow:
        final startY = top + (height * 0.18);
        final endY = bottom - (height * 0.22);
        final arrowLeftX = centerX - (width * 0.18);
        final arrowRightX = centerX + (width * 0.18);
        canvas.drawLine(Offset(centerX, startY), Offset(centerX, endY), paint);
        canvas.drawLine(
          Offset(arrowLeftX, endY - (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        canvas.drawLine(
          Offset(arrowRightX, endY - (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.checkmark:
        final path = Path()
          ..moveTo(left + (width * 0.18), top + (height * 0.56))
          ..lineTo(left + (width * 0.42), top + (height * 0.78))
          ..lineTo(right - (width * 0.16), top + (height * 0.24));
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.enterArrow:
        final midX = right - (width * 0.26);
        final hookY = centerY + (height * 0.18);
        canvas.drawLine(
          Offset(left + (width * 0.16), centerY),
          Offset(midX, centerY),
          paint,
        );
        canvas.drawLine(
          Offset(midX, top + (height * 0.22)),
          Offset(midX, hookY),
          paint,
        );
        canvas.drawLine(
          Offset(midX, hookY),
          Offset(midX - (width * 0.18), hookY - (height * 0.16)),
          paint,
        );
        canvas.drawLine(
          Offset(midX, hookY),
          Offset(midX - (width * 0.18), hookY + (height * 0.16)),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.emDash:
        canvas.drawLine(
          Offset(left + (width * 0.12), centerY),
          Offset(right - (width * 0.12), centerY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.heavyRightArrow:
        // Heavy round-tipped rightwards arrow (➜ U+279C).
        // Drawn as a solid filled chevron: a left-indented pentagon centred
        // vertically in the cell — no stem, just the broad arrowhead.
        final path = Path()
          ..moveTo(right - (width * 0.18), centerY) // rightmost tip
          ..lineTo(left + (width * 0.28), top + (height * 0.18)) // top-left
          ..lineTo(left + (width * 0.48), centerY) // centre indent
          ..lineTo(
            left + (width * 0.28),
            bottom - (height * 0.18),
          ) // bottom-left
          ..close();
        canvas.drawPath(path, paint);
        return true;
    }
  }

  bool _paintTerminalBrailleGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null || rune < 0x2800 || rune > 0x28FF) {
      return false;
    }

    final dots = rune - 0x2800;
    if (dots == 0) {
      return true;
    }

    final left = rect.left;
    final top = rect.top;
    final width = rect.width;
    final height = rect.height;
    final dotRadius = math.max(
      0.8 / math.max(devicePixelRatio, 1.0),
      math.min(width * 0.12, height * 0.09),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final xPositions = <double>[left + (width * 0.32), left + (width * 0.68)];
    final yPositions = <double>[
      top + (height * 0.16),
      top + (height * 0.38),
      top + (height * 0.60),
      top + (height * 0.82),
    ];
    const bitToDot = <({int bit, int col, int row})>[
      (bit: 0x01, col: 0, row: 0),
      (bit: 0x02, col: 0, row: 1),
      (bit: 0x04, col: 0, row: 2),
      (bit: 0x08, col: 1, row: 0),
      (bit: 0x10, col: 1, row: 1),
      (bit: 0x20, col: 1, row: 2),
      (bit: 0x40, col: 0, row: 3),
      (bit: 0x80, col: 1, row: 3),
    ];

    for (final dot in bitToDot) {
      if ((dots & dot.bit) == 0) {
        continue;
      }
      canvas.drawCircle(
        Offset(xPositions[dot.col], yPositions[dot.row]),
        dotRadius,
        paint,
      );
    }
    return true;
  }

  bool _paintTerminalBlockGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalBlockGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final left = _snapLogicalToPhysical(rect.left, devicePixelRatio);
    final right = _snapLogicalToPhysical(rect.right, devicePixelRatio);
    final top = _snapLogicalToPhysical(rect.top, devicePixelRatio);
    final bottom = _snapLogicalToPhysical(rect.bottom, devicePixelRatio);
    final width = right - left;
    final height = bottom - top;

    if (spec.shadeAlpha case final shadeAlpha?) {
      final shadePaint = Paint()
        ..color = color.withValues(alpha: color.a * shadeAlpha)
        ..style = PaintingStyle.fill
        ..isAntiAlias = false;
      canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), shadePaint);
      return true;
    }

    final fillLeft = left + (width * spec.leftFraction);
    final fillTop = top + (height * spec.topFraction);
    final fillRight = left + (width * spec.rightFraction);
    final fillBottom = top + (height * spec.bottomFraction);
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    canvas.drawRect(
      Rect.fromLTRB(
        _snapLogicalToPhysical(fillLeft, devicePixelRatio),
        _snapLogicalToPhysical(fillTop, devicePixelRatio),
        _snapLogicalToPhysical(fillRight, devicePixelRatio),
        _snapLogicalToPhysical(fillBottom, devicePixelRatio),
      ),
      fillPaint,
    );
    return true;
  }
}

double _centeredGlyphOffset(double availableExtent, double glyphExtent) {
  if (availableExtent <= glyphExtent) {
    return 0;
  }
  return (availableExtent - glyphExtent) / 2;
}

final Set<int> _loggedUnsupportedTerminalRunes = <int>{};

void _debugLogUnsupportedGlyph(String text) {
  assert(() {
    final runes = text.runes.toList(growable: false);
    if (runes.isEmpty) {
      return true;
    }
    if (runes.length == 1) {
      final rune = runes.first;
      if (rune <= 0x7E ||
          _terminalBoxDrawingSpec(rune) != null ||
          _terminalBlockGlyphSpec(rune) != null ||
          _terminalGeometricGlyphSpec(rune) != null ||
          _terminalRaisedTextGlyphSpec(rune) != null ||
          _terminalSymbolGlyphSpec(rune) != null ||
          (rune >= 0x2800 && rune <= 0x28FF)) {
        return true;
      }
      if (_loggedUnsupportedTerminalRunes.add(rune)) {
        debugPrint(
          'GhosttyTerminalView unsupported glyph fallback: '
          '"$text" U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        );
      }
      return true;
    }

    for (final rune in runes) {
      if (rune <= 0x7E) {
        continue;
      }
      if (_loggedUnsupportedTerminalRunes.add(rune)) {
        debugPrint(
          'GhosttyTerminalView unsupported grapheme fallback: '
          '"$text" contains U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        );
      }
    }
    return true;
  }());
}

_TerminalRowBand _rowBand({
  required double contentTop,
  required int rowIndex,
  required double linePixels,
  required double devicePixelRatio,
}) {
  final top = _snapLogicalToPhysical(
    contentTop + (rowIndex * linePixels),
    devicePixelRatio,
  );
  final bottom = _snapLogicalToPhysical(
    contentTop + ((rowIndex + 1) * linePixels),
    devicePixelRatio,
  );
  final minHeight = devicePixelRatio <= 0 ? 1.0 : (1 / devicePixelRatio);
  return _TerminalRowBand(top: top, bottom: math.max(top + minHeight, bottom));
}

double _snapLogicalToPhysical(double value, double devicePixelRatio) {
  if (devicePixelRatio <= 0) {
    return value;
  }
  return (value * devicePixelRatio).roundToDouble() / devicePixelRatio;
}

double _snapLogicalExtentToPhysical(double value, double devicePixelRatio) {
  if (devicePixelRatio <= 0) {
    return value;
  }
  return math.max(
    1 / devicePixelRatio,
    (value * devicePixelRatio).roundToDouble() / devicePixelRatio,
  );
}

Offset _centerGlyphInCell(
  TextPainter painter,
  String text, {
  required Rect cellRect,
  required double fallbackHeight,
}) {
  final bounds = _glyphBounds(painter, text);
  if (bounds == null) {
    return Offset(
      cellRect.left + _centeredGlyphOffset(cellRect.width, painter.width),
      cellRect.top + _centeredGlyphOffset(fallbackHeight, painter.height),
    );
  }

  return Offset(
    cellRect.left +
        _centeredGlyphOffset(cellRect.width, bounds.width) -
        bounds.left,
    cellRect.top +
        _centeredGlyphOffset(cellRect.height, bounds.height) -
        bounds.top,
  );
}

Rect? _glyphBounds(TextPainter painter, String text) {
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  if (boxes.isEmpty) {
    return null;
  }

  var left = boxes.first.left;
  var top = boxes.first.top;
  var right = boxes.first.right;
  var bottom = boxes.first.bottom;
  for (final box in boxes.skip(1)) {
    left = math.min(left, box.left);
    top = math.min(top, box.top);
    right = math.max(right, box.right);
    bottom = math.max(bottom, box.bottom);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

double _boxDrawingStrokeWidth(
  Rect rect, {
  required bool heavy,
  required double devicePixelRatio,
}) {
  final onePhysicalPixel = devicePixelRatio <= 0 ? 1.0 : 1.0 / devicePixelRatio;
  if (!heavy) {
    return onePhysicalPixel;
  }

  final heavyStroke = rect.width * 0.2;
  return math.max(onePhysicalPixel, heavyStroke);
}

double _pixelSnapAxis(
  double center,
  double strokeWidth, {
  required double devicePixelRatio,
}) {
  if (devicePixelRatio <= 0) {
    final rounded = center.roundToDouble();
    if (strokeWidth <= 1.0) {
      return rounded + 0.5;
    }
    return rounded;
  }

  final physicalCenter = center * devicePixelRatio;
  final onePhysicalPixel = 1.0 / devicePixelRatio;
  if (strokeWidth <= onePhysicalPixel) {
    return ((physicalCenter - 0.5).roundToDouble() + 0.5) / devicePixelRatio;
  }
  return physicalCenter.roundToDouble() / devicePixelRatio;
}

double _boxDrawingCenterYOffset(Rect rect, _TerminalBoxDrawingSpec spec) {
  final opticalOffset = spec.up && !spec.down
      ? -0.5
      : spec.down && !spec.up
      ? 0.5
      : 0.0;
  return (rect.height / 2) + opticalOffset;
}

bool _renderSnapshotEquals(
  GhosttyTerminalRenderSnapshot? a,
  GhosttyTerminalRenderSnapshot? b,
) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  return a.cols == b.cols &&
      a.rows == b.rows &&
      a.backgroundColor == b.backgroundColor &&
      a.foregroundColor == b.foregroundColor &&
      a.cursor == b.cursor &&
      listEquals(a.rowsData, b.rowsData);
}

String _widgetModeLabel(
  GhosttyTerminalRendererMode mode,
  GhosttyTerminalRenderSnapshot? renderSnapshot,
  int scrollOffsetLines,
) {
  if (mode == GhosttyTerminalRendererMode.renderState) {
    if (scrollOffsetLines > 0) {
      return 'renderState (scrollback fallback)';
    }
    if (renderSnapshot == null || !renderSnapshot.hasViewportData) {
      return 'renderState (fmt fallback)';
    }
  }
  return mode == GhosttyTerminalRendererMode.formatter
      ? 'formatter'
      : 'renderState';
}

class _TerminalMetrics {
  const _TerminalMetrics({required this.charWidth, required this.linePixels});

  final double charWidth;
  final double linePixels;
}

enum _TerminalSelectionGranularity { cell, word, line }

class _TerminalViewport {
  const _TerminalViewport({
    required this.startLine,
    required this.contentTop,
    required this.contentHeight,
    required this.maxVisible,
  });

  final int startLine;
  final double contentTop;
  final double contentHeight;
  final int maxVisible;
}

final class _TerminalRowBand {
  const _TerminalRowBand({required this.top, required this.bottom});

  final double top;
  final double bottom;

  double get height => bottom - top;
}

final class _NativeRenderRun {
  const _NativeRenderRun({
    required this.style,
    required this.background,
    required this.metadata,
    required this.metadataBackground,
    required this.startCol,
    required this.width,
    required this.text,
    required this.graphemeCellWidths,
    required this.hasRenderableText,
    required this.hasHyperlink,
  });

  final GhosttyTerminalResolvedStyle style;
  final Color background;
  final GhosttyTerminalRenderCellMetadata metadata;
  final Color? metadataBackground;
  final int startCol;
  final int width;
  final String text;
  final List<int> graphemeCellWidths;
  final bool hasRenderableText;
  final bool hasHyperlink;
}

final class _ResolvedTerminalStyle {
  const _ResolvedTerminalStyle({
    required this.foreground,
    required this.background,
    required this.decoration,
    required this.decorationStyle,
    required this.decorationColor,
    required this.fontWeight,
    required this.fontStyle,
  });

  factory _ResolvedTerminalStyle.fromRun(
    GhosttyTerminalStyle style, {
    required GhosttyTerminalPalette palette,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color hyperlinkColor,
  }) {
    final resolved = GhosttyTerminalResolvedStyle.fromFormattedStyle(
      style: style,
      palette: palette.ansi,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
    );
    final hasHyperlink = style.hyperlink != null;
    final textForeground = hasHyperlink && !resolved.hasExplicitForeground
        ? hyperlinkColor
        : resolved.foreground;
    final decorationColor = resolved.hasExplicitUnderlineColor
        ? resolved.underlineColor
        : textForeground;

    final decoration = <TextDecoration>[
      if (resolved.underline != GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE)
        TextDecoration.underline,
      if (hasHyperlink &&
          (resolved.underline ==
              GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE))
        TextDecoration.underline,
      if (resolved.overline) TextDecoration.overline,
      if (resolved.strikethrough) TextDecoration.lineThrough,
    ];

    return _ResolvedTerminalStyle(
      foreground: textForeground,
      background: resolved.background,
      decoration: decoration.isEmpty
          ? TextDecoration.none
          : TextDecoration.combine(decoration),
      decorationStyle: switch (resolved.underline) {
        GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOUBLE =>
          TextDecorationStyle.double,
        GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_CURLY =>
          TextDecorationStyle.wavy,
        GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOTTED =>
          TextDecorationStyle.dotted,
        GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DASHED =>
          TextDecorationStyle.dashed,
        _ => TextDecorationStyle.solid,
      },
      decorationColor: decorationColor,
      fontWeight: resolved.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: resolved.italic ? FontStyle.italic : FontStyle.normal,
    );
  }

  final Color foreground;
  final Color background;
  final TextDecoration decoration;
  final TextDecorationStyle decorationStyle;
  final Color decorationColor;
  final FontWeight fontWeight;
  final FontStyle fontStyle;

  TextStyle toTextStyle({
    required double fontSize,
    required double lineHeight,
    required String fontFamily,
    required List<String>? fontFamilyFallback,
    required String? fontPackage,
    required double letterSpacing,
  }) {
    return TextStyle(
      color: foreground,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      package: fontPackage,
      fontSize: fontSize,
      height: lineHeight,
      letterSpacing: letterSpacing,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      decoration: decoration,
      decorationStyle: decorationStyle,
      decorationColor: decorationColor,
    );
  }
}

final class _TerminalTextPainterKey {
  const _TerminalTextPainterKey({
    required this.text,
    required this.width,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontPackage,
    required this.letterSpacing,
    required this.color,
    required this.fontWeight,
    required this.fontStyle,
    required this.decoration,
    required this.decorationStyle,
    required this.decorationColor,
  });

  final String text;
  final double width;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final String? fontPackage;
  final double letterSpacing;
  final Color color;
  final FontWeight fontWeight;
  final FontStyle fontStyle;
  final TextDecoration decoration;
  final TextDecorationStyle decorationStyle;
  final Color decorationColor;

  @override
  bool operator ==(Object other) {
    return other is _TerminalTextPainterKey &&
        text == other.text &&
        width == other.width &&
        fontSize == other.fontSize &&
        lineHeight == other.lineHeight &&
        fontFamily == other.fontFamily &&
        listEquals(fontFamilyFallback, other.fontFamilyFallback) &&
        fontPackage == other.fontPackage &&
        letterSpacing == other.letterSpacing &&
        color == other.color &&
        fontWeight == other.fontWeight &&
        fontStyle == other.fontStyle &&
        decoration == other.decoration &&
        decorationStyle == other.decorationStyle &&
        decorationColor == other.decorationColor;
  }

  @override
  int get hashCode => Object.hash(
    text,
    width,
    fontSize,
    lineHeight,
    fontFamily,
    Object.hashAll(fontFamilyFallback ?? const <String>[]),
    fontPackage,
    letterSpacing,
    color,
    fontWeight,
    fontStyle,
    decoration,
    decorationStyle,
    decorationColor,
  );
}

final class _TerminalTextPainterCache {
  _TerminalTextPainterCache({required this.maxEntries});

  final int maxEntries;
  final Map<_TerminalTextPainterKey, TextPainter> _painters =
      <_TerminalTextPainterKey, TextPainter>{};

  TextPainter resolve(_TerminalTextPainterKey key) {
    final cached = _painters.remove(key);
    if (cached != null) {
      _painters[key] = cached;
      return cached;
    }

    final painter = TextPainter(
      text: TextSpan(
        text: key.text,
        style: TextStyle(
          color: key.color,
          fontFamily: key.fontFamily,
          fontFamilyFallback: key.fontFamilyFallback,
          package: key.fontPackage,
          fontSize: key.fontSize,
          height: key.lineHeight,
          letterSpacing: key.letterSpacing,
          fontWeight: key.fontWeight,
          fontStyle: key.fontStyle,
          decoration: key.decoration,
          decorationStyle: key.decorationStyle,
          decorationColor: key.decorationColor,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: key.width);

    _painters[key] = painter;
    if (_painters.length > maxEntries) {
      _painters.remove(_painters.keys.first);
    }
    return painter;
  }
}

final class _TerminalIntrinsicWidthKey {
  const _TerminalIntrinsicWidthKey({
    required this.text,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontPackage,
    required this.letterSpacing,
    required this.fontWeight,
    required this.fontStyle,
  });

  final String text;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final String? fontPackage;
  final double letterSpacing;
  final FontWeight fontWeight;
  final FontStyle fontStyle;

  @override
  bool operator ==(Object other) {
    return other is _TerminalIntrinsicWidthKey &&
        text == other.text &&
        fontSize == other.fontSize &&
        lineHeight == other.lineHeight &&
        fontFamily == other.fontFamily &&
        listEquals(fontFamilyFallback, other.fontFamilyFallback) &&
        fontPackage == other.fontPackage &&
        letterSpacing == other.letterSpacing &&
        fontWeight == other.fontWeight &&
        fontStyle == other.fontStyle;
  }

  @override
  int get hashCode => Object.hash(
    text,
    fontSize,
    lineHeight,
    fontFamily,
    Object.hashAll(fontFamilyFallback ?? const <String>[]),
    fontPackage,
    letterSpacing,
    fontWeight,
    fontStyle,
  );
}

final class _TerminalTextIntrinsicWidthCache {
  _TerminalTextIntrinsicWidthCache({required this.maxEntries});

  final int maxEntries;
  final Map<_TerminalIntrinsicWidthKey, double> _widths =
      <_TerminalIntrinsicWidthKey, double>{};

  double resolve(_TerminalIntrinsicWidthKey key) {
    final cached = _widths.remove(key);
    if (cached != null) {
      _widths[key] = cached;
      return cached;
    }

    final painter = TextPainter(
      text: TextSpan(
        text: key.text,
        style: TextStyle(
          fontFamily: key.fontFamily,
          fontFamilyFallback: key.fontFamilyFallback,
          package: key.fontPackage,
          fontSize: key.fontSize,
          height: key.lineHeight,
          letterSpacing: key.letterSpacing,
          fontWeight: key.fontWeight,
          fontStyle: key.fontStyle,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final width = painter.width;
    _widths[key] = width;
    if (_widths.length > maxEntries) {
      _widths.remove(_widths.keys.first);
    }
    return width;
  }
}

bool _containsBoxDrawingCharacters(String text) {
  for (final rune in text.runes) {
    if (_terminalBoxDrawingSpec(rune) != null) {
      return true;
    }
  }
  return false;
}

bool _isSafeSingleRunText(String text) {
  if (text.isEmpty || _containsBoxDrawingCharacters(text)) {
    return false;
  }

  for (final rune in text.runes) {
    if (rune < 0x20 || rune > 0x7E) {
      return false;
    }
  }
  return true;
}

_TerminalBoxDrawingSpec? _terminalBoxDrawingSpec(int rune) => switch (rune) {
  0x2574 => const _TerminalBoxDrawingSpec(left: true),
  0x2575 => const _TerminalBoxDrawingSpec(up: true),
  0x2576 => const _TerminalBoxDrawingSpec(right: true),
  0x2577 => const _TerminalBoxDrawingSpec(down: true),
  0x2578 => const _TerminalBoxDrawingSpec(left: true, heavyHorizontal: true),
  0x2579 => const _TerminalBoxDrawingSpec(up: true, heavyVertical: true),
  0x257A => const _TerminalBoxDrawingSpec(right: true, heavyHorizontal: true),
  0x257B => const _TerminalBoxDrawingSpec(down: true, heavyVertical: true),
  0x256D => const _TerminalBoxDrawingSpec(
    right: true,
    down: true,
    rounded: true,
  ),
  0x256E => const _TerminalBoxDrawingSpec(
    left: true,
    down: true,
    rounded: true,
  ),
  0x2570 => const _TerminalBoxDrawingSpec(right: true, up: true, rounded: true),
  0x256F => const _TerminalBoxDrawingSpec(left: true, up: true, rounded: true),
  0x2500 ||
  0x2504 ||
  0x2508 ||
  0x2509 => const _TerminalBoxDrawingSpec(left: true, right: true),
  0x2501 || 0x2505 => const _TerminalBoxDrawingSpec(
    left: true,
    right: true,
    heavyHorizontal: true,
  ),
  0x2502 ||
  0x2506 ||
  0x250A ||
  0x250B => const _TerminalBoxDrawingSpec(up: true, down: true),
  0x2503 || 0x2507 => const _TerminalBoxDrawingSpec(
    up: true,
    down: true,
    heavyVertical: true,
  ),
  0x250C ||
  0x250D ||
  0x250E ||
  0x250F => const _TerminalBoxDrawingSpec(right: true, down: true),
  0x2510 ||
  0x2511 ||
  0x2512 ||
  0x2513 => const _TerminalBoxDrawingSpec(left: true, down: true),
  0x2514 ||
  0x2515 ||
  0x2516 ||
  0x2517 => const _TerminalBoxDrawingSpec(right: true, up: true),
  0x2518 ||
  0x2519 ||
  0x251A ||
  0x251B => const _TerminalBoxDrawingSpec(left: true, up: true),
  0x251C ||
  0x251D ||
  0x251E ||
  0x251F ||
  0x2520 ||
  0x2521 ||
  0x2522 ||
  0x2523 => const _TerminalBoxDrawingSpec(up: true, down: true, right: true),
  0x2524 ||
  0x2525 ||
  0x2526 ||
  0x2527 ||
  0x2528 ||
  0x2529 ||
  0x252A ||
  0x252B => const _TerminalBoxDrawingSpec(up: true, down: true, left: true),
  0x252C ||
  0x252D ||
  0x252E ||
  0x252F ||
  0x2530 ||
  0x2531 ||
  0x2532 ||
  0x2533 => const _TerminalBoxDrawingSpec(left: true, right: true, down: true),
  0x2534 ||
  0x2535 ||
  0x2536 ||
  0x2537 ||
  0x2538 ||
  0x2539 ||
  0x253A ||
  0x253B => const _TerminalBoxDrawingSpec(left: true, right: true, up: true),
  0x253C ||
  0x253D ||
  0x253E ||
  0x253F ||
  0x2540 ||
  0x2541 ||
  0x2542 ||
  0x2543 ||
  0x2544 ||
  0x2545 ||
  0x2546 ||
  0x2547 ||
  0x2548 ||
  0x2549 ||
  0x254A ||
  0x254B => const _TerminalBoxDrawingSpec(
    up: true,
    down: true,
    left: true,
    right: true,
  ),
  _ => null,
};

final class _TerminalBoxDrawingSpec {
  const _TerminalBoxDrawingSpec({
    this.up = false,
    this.down = false,
    this.left = false,
    this.right = false,
    this.heavyHorizontal = false,
    this.heavyVertical = false,
    this.rounded = false,
  });

  final bool up;
  final bool down;
  final bool left;
  final bool right;
  final bool heavyHorizontal;
  final bool heavyVertical;
  final bool rounded;
}

_TerminalGeometricGlyphSpec? _terminalGeometricGlyphSpec(int rune) =>
    switch (rune) {
      0x00B0 => const _TerminalGeometricGlyphSpec(
        diameterScale: 0.42,
        strokeScale: 0.12,
      ),
      0x25CB || 0x25EF => const _TerminalGeometricGlyphSpec(
        diameterScale: 0.88,
        strokeScale: 0.12,
      ),
      0x25E6 => const _TerminalGeometricGlyphSpec(
        diameterScale: 0.4,
        strokeScale: 0.14,
      ),
      0x25CF || 0x25C9 => const _TerminalGeometricGlyphSpec(
        filled: true,
        diameterScale: 0.58,
      ),
      _ => null,
    };

final class _TerminalGeometricGlyphSpec {
  const _TerminalGeometricGlyphSpec({
    this.filled = false,
    required this.diameterScale,
    this.strokeScale = 0.14,
  });

  final bool filled;
  final double diameterScale;
  final double strokeScale;
}

_TerminalRaisedTextGlyphSpec? _terminalRaisedTextGlyphSpec(int rune) =>
    switch (rune) {
      0x2070 => const _TerminalRaisedTextGlyphSpec(text: '0'),
      0x00B9 => const _TerminalRaisedTextGlyphSpec(text: '1'),
      0x00B2 => const _TerminalRaisedTextGlyphSpec(text: '2'),
      0x00B3 => const _TerminalRaisedTextGlyphSpec(text: '3'),
      0x2075 => const _TerminalRaisedTextGlyphSpec(text: '5'),
      0x2076 => const _TerminalRaisedTextGlyphSpec(text: '6'),
      0x2077 => const _TerminalRaisedTextGlyphSpec(text: '7'),
      0x2078 => const _TerminalRaisedTextGlyphSpec(text: '8'),
      0x2079 => const _TerminalRaisedTextGlyphSpec(text: '9'),
      0x207A => const _TerminalRaisedTextGlyphSpec(text: '+'),
      0x207B => const _TerminalRaisedTextGlyphSpec(text: '-'),
      0x2074 => const _TerminalRaisedTextGlyphSpec(text: '4'),
      _ => null,
    };

final class _TerminalRaisedTextGlyphSpec {
  const _TerminalRaisedTextGlyphSpec({required this.text});

  final String text;
  final double fontScale = 0.7;
  final double topOffsetScale = 0.02;
  final double verticalSpaceScale = 0.72;
}

_TerminalSymbolGlyphSpec? _terminalSymbolGlyphSpec(int rune) => switch (rune) {
  0x25C0 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.leftTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25B6 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.rightTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25B2 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.upTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25BC => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.downTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25A0 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.square,
    filled: true,
    strokeScale: 0.1,
  ),
  0x2190 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.leftArrow,
    strokeScale: 0.12,
  ),
  0x2192 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.rightArrow,
    strokeScale: 0.12,
  ),
  0x2191 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.upArrow,
    strokeScale: 0.12,
  ),
  0x2193 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.downArrow,
    strokeScale: 0.12,
  ),
  0x21B5 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.enterArrow,
    strokeScale: 0.12,
  ),
  0x2713 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.checkmark,
    strokeScale: 0.14,
  ),
  0x2014 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.emDash,
    strokeScale: 0.1,
  ),
  // Heavy round-tipped rightwards arrow (U+279C) — common in zsh prompts.
  0x279C => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.heavyRightArrow,
    filled: true,
    strokeScale: 0.1,
  ),
  _ => null,
};

enum _TerminalSymbolGlyphKind {
  upTriangle,
  downTriangle,
  leftTriangle,
  rightTriangle,
  square,
  leftArrow,
  rightArrow,
  upArrow,
  downArrow,
  enterArrow,
  checkmark,
  emDash,
  heavyRightArrow,
}

final class _TerminalSymbolGlyphSpec {
  const _TerminalSymbolGlyphSpec({
    required this.kind,
    required this.strokeScale,
    this.filled = false,
  });

  final _TerminalSymbolGlyphKind kind;
  final double strokeScale;
  final bool filled;
}

_TerminalBlockGlyphSpec? _terminalBlockGlyphSpec(int rune) => switch (rune) {
  0x2580 => const _TerminalBlockGlyphSpec(bottomFraction: 0.5),
  0x2581 => const _TerminalBlockGlyphSpec(topFraction: 7 / 8),
  0x2582 => const _TerminalBlockGlyphSpec(topFraction: 6 / 8),
  0x2583 => const _TerminalBlockGlyphSpec(topFraction: 5 / 8),
  0x2584 => const _TerminalBlockGlyphSpec(topFraction: 0.5),
  0x2585 => const _TerminalBlockGlyphSpec(topFraction: 3 / 8),
  0x2586 => const _TerminalBlockGlyphSpec(topFraction: 2 / 8),
  0x2587 => const _TerminalBlockGlyphSpec(topFraction: 1 / 8),
  0x2588 => const _TerminalBlockGlyphSpec(),
  0x2589 => const _TerminalBlockGlyphSpec(rightFraction: 7 / 8),
  0x258A => const _TerminalBlockGlyphSpec(rightFraction: 6 / 8),
  0x258B => const _TerminalBlockGlyphSpec(rightFraction: 5 / 8),
  0x258C => const _TerminalBlockGlyphSpec(rightFraction: 0.5),
  0x258D => const _TerminalBlockGlyphSpec(rightFraction: 3 / 8),
  0x258E => const _TerminalBlockGlyphSpec(rightFraction: 2 / 8),
  0x258F => const _TerminalBlockGlyphSpec(rightFraction: 1 / 8),
  0x2590 => const _TerminalBlockGlyphSpec(leftFraction: 0.5),
  0x2591 => const _TerminalBlockGlyphSpec(shadeAlpha: 0.25),
  0x2592 => const _TerminalBlockGlyphSpec(shadeAlpha: 0.5),
  0x2593 => const _TerminalBlockGlyphSpec(shadeAlpha: 0.75),
  _ => null,
};

final class _TerminalBlockGlyphSpec {
  const _TerminalBlockGlyphSpec({
    this.leftFraction = 0,
    this.topFraction = 0,
    this.rightFraction = 1,
    this.bottomFraction = 1,
    this.shadeAlpha,
  });

  final double leftFraction;
  final double topFraction;
  final double rightFraction;
  final double bottomFraction;
  final double? shadeAlpha;
}

Iterable<String> _splitTerminalCells(String text) sync* {
  if (text.isEmpty) {
    return;
  }
  yield* text.characters;
}

/// Returns `true` if [rune] is a Unicode "wide" character that occupies two
/// terminal columns (East Asian Wide / Fullwidth, wide emoji, etc.).
bool _isWideRune(int rune) {
  // Zero-width joiner — always narrow (combines preceding/following characters).
  if (rune == 0x200D) return false;
  // Variation selectors (U+FE00–U+FE0F) — narrow combining characters that
  // select a presentation variant; must not be counted as wide.
  if (rune >= 0xFE00 && rune <= 0xFE0F) return false;
  // Regional Indicator Symbols (U+1F1E6–U+1F1FF) — pairs form flag emoji and
  // each symbol occupies two terminal columns.
  if (rune >= 0x1F1E6 && rune <= 0x1F1FF) return true;
  // Hangul Jamo
  if (rune >= 0x1100 && rune <= 0x115F) return true;
  // CJK Radicals Supplement … CJK Unified Ideographs Extension A
  if (rune >= 0x2E80 && rune <= 0x303E) return true;
  // Hiragana … Yi Radicals (covers Katakana, Bopomofo, CJK Unified Ideographs…)
  if (rune >= 0x3040 && rune <= 0xA4CF) return true;
  // Hangul Syllables
  if (rune >= 0xAC00 && rune <= 0xD7A3) return true;
  // CJK Compatibility Ideographs
  if (rune >= 0xF900 && rune <= 0xFAFF) return true;
  // Vertical forms
  if (rune >= 0xFE10 && rune <= 0xFE1F) return true;
  // CJK Compatibility Forms … Small Form Variants
  if (rune >= 0xFE30 && rune <= 0xFE6F) return true;
  // Fullwidth Latin / Halfwidth and Fullwidth Forms (fullwidth block)
  if (rune >= 0xFF01 && rune <= 0xFF60) return true;
  // Fullwidth cent / pound / yen / won / fullwidth macron
  if (rune >= 0xFFE0 && rune <= 0xFFE6) return true;
  // Wide emoji / pictographs (plane 1 wide blocks)
  if (rune >= 0x1F004 && rune <= 0x1F9FF) return true;
  // CJK Unified Ideographs Extension B–F and Compatibility Supplement
  if (rune >= 0x20000 && rune <= 0x2FA1F) return true;
  return false;
}

/// Assigns a display-cell width to each grapheme cluster in [text] using
/// Unicode display-width rules, cross-checked against [totalCells].
///
/// Each grapheme cluster is assigned width 2 if its first rune is a "wide"
/// Unicode character (East Asian Wide / Fullwidth), and width 1 otherwise.
/// If the resulting sum disagrees with [totalCells] (e.g. because the terminal
/// uses a different width table), the excess or deficit is distributed across
/// graphemes as a fallback.
List<int> _measureTerminalCellWidths(String text, int totalCells) {
  final graphemes = _splitTerminalCells(text).toList(growable: false);
  if (graphemes.isEmpty) {
    return const <int>[];
  }

  if (totalCells <= 0) {
    return List<int>.filled(graphemes.length, 1, growable: false);
  }

  // Assign widths based on Unicode display-width of the first rune.
  final widths = <int>[
    for (final g in graphemes)
      g.isNotEmpty && _isWideRune(g.runes.first) ? 2 : 1,
  ];

  // Cross-check against totalCells and adjust if they disagree.
  var delta = totalCells - widths.fold<int>(0, (sum, v) => sum + v);
  if (delta > 0) {
    // More cells than we accounted for — distribute extra cells to trailing
    // graphemes first so that ambiguous-width glyphs (e.g. emoji sequences
    // that the terminal counts as wide) absorb the surplus before leading
    // narrow characters do.
    for (var i = widths.length - 1; delta > 0 && i >= 0; i--) {
      widths[i]++;
      delta--;
    }
  } else if (delta < 0) {
    // Fewer cells than we accounted for — shrink wide graphemes first.
    for (var i = 0; delta < 0 && i < widths.length; i++) {
      if (widths[i] > 1) {
        widths[i]--;
        delta++;
      }
    }
  }

  return widths;
}
