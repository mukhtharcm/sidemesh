import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

final bool _hasNativeTerminal = _hasNativeTerminalSupport();

/// Measured rendering metrics derived at runtime from the same [TextStyle]
/// that [buildView] uses (`fontSize: 14, lineHeight: 1.35, fontFamily:
/// 'monospace'`) plus the default padding of `EdgeInsets.all(12)`.
///
/// Prefer calling [_measureTestMetrics] inside each test after pumping the
/// widget so that the values reflect the actual font metrics reported by the
/// Flutter test engine rather than hand-tuned constants.
typedef _TestMetrics = ({int charWidth, int linePixels, int padding});

/// Measures [_TestMetrics] using the font metrics in effect for the current
/// test environment.
///
/// Must be called after at least one [WidgetTester.pumpWidget] so that the
/// font is loaded.
_TestMetrics _measureTestMetrics() {
  const style = TextStyle(
    fontSize: 14,
    fontFamily: 'monospace',
    letterSpacing: 0,
  );
  final painter = TextPainter(
    text: const TextSpan(text: 'M', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final charWidth = painter.width.round();
  final linePixels = (14 * 1.35).ceil();
  painter.dispose();
  const padding = 12; // matches the EdgeInsets.all(12) default in buildView()
  return (charWidth: charWidth, linePixels: linePixels, padding: padding);
}

bool _hasNativeTerminalSupport() {
  try {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    terminal.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  group('GhosttyTerminalView', () {
    late GhosttyTerminalController controller;

    setUp(() {
      controller = GhosttyTerminalController();
    });

    tearDown(() {
      controller.dispose();
    });

    Widget buildView({
      GhosttyTerminalController? terminalController,
      bool autofocus = false,
      bool showHeader = true,
      bool showVerticalScrollbar = false,
      ScrollController? scrollController,
      bool autoFollowOnActivity = false,
      FocusNode? focusNode,
      Color? backgroundColor,
      Color? foregroundColor,
      Color? cursorColor,
      Color? hyperlinkColor,
      Color? selectionColor,
      double? fontSize,
      double? lineHeight,
      GhosttyTerminalRendererMode renderer =
          GhosttyTerminalRendererMode.formatter,
      GhosttyTerminalCopyOptions copyOptions =
          const GhosttyTerminalCopyOptions(),
      GhosttyTerminalWordBoundaryPolicy wordBoundaryPolicy =
          const GhosttyTerminalWordBoundaryPolicy(),
      GhosttyTerminalInteractionPolicy interactionPolicy =
          GhosttyTerminalInteractionPolicy.auto,
      bool showSelectionContextMenu = true,
      GhosttyTerminalSelectionContextMenuButtonItemsBuilder?
      selectionContextMenuButtonItemsBuilder,
      EdgeInsets? padding,
      ValueChanged<GhosttyTerminalSelection?>? onSelectionChanged,
      ValueChanged<GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?>?
      onSelectionContentChanged,
      Future<void> Function(String text)? onCopySelection,
      Future<void> Function(String uri)? onOpenHyperlink,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: GhosttyTerminalView(
              controller: terminalController ?? controller,
              autofocus: autofocus,
              showHeader: showHeader,
              showVerticalScrollbar: showVerticalScrollbar,
              scrollController: scrollController,
              autoFollowOnActivity: autoFollowOnActivity,
              focusNode: focusNode,
              backgroundColor: backgroundColor ?? const Color(0xFF0A0F14),
              foregroundColor: foregroundColor ?? const Color(0xFFE6EDF3),
              cursorColor: cursorColor ?? const Color(0xFF9AD1C0),
              hyperlinkColor: hyperlinkColor ?? const Color(0xFF61AFEF),
              selectionColor: selectionColor ?? const Color(0x665DA9FF),
              fontSize: fontSize ?? 14,
              lineHeight: lineHeight ?? 1.35,
              renderer: renderer,
              copyOptions: copyOptions,
              wordBoundaryPolicy: wordBoundaryPolicy,
              interactionPolicy: interactionPolicy,
              showSelectionContextMenu: showSelectionContextMenu,
              selectionContextMenuButtonItemsBuilder:
                  selectionContextMenuButtonItemsBuilder,
              padding: padding ?? const EdgeInsets.all(12),
              onSelectionChanged: onSelectionChanged,
              onSelectionContentChanged: onSelectionContentChanged,
              onCopySelection: onCopySelection,
              onOpenHyperlink: onOpenHyperlink,
            ),
          ),
        ),
      );
    }

    testWidgets('renders and reports a terminal grid', (tester) async {
      await tester.pumpWidget(buildView());
      await tester.pump();

      expect(find.byType(GhosttyTerminalView), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(controller.cols, greaterThan(0));
      expect(controller.rows, greaterThan(0));
    });

    testWidgets('can render without the terminal header', (tester) async {
      // Render with header to get the baseline row count.
      await tester.pumpWidget(buildView(showHeader: true));
      await tester.pump();
      final rowsWithHeader = controller.rows;

      // The header sentinel widget should be present when showHeader: true.
      expect(find.byKey(const ValueKey('terminalHeader')), findsOneWidget);

      // Render without header — the extra space should yield more rows.
      await tester.pumpWidget(buildView(showHeader: false));
      await tester.pump();

      // The header sentinel widget must be absent when showHeader: false.
      expect(find.byKey(const ValueKey('terminalHeader')), findsNothing);

      expect(find.byType(GhosttyTerminalView), findsOneWidget);
      expect(controller.cols, greaterThan(0));
      expect(controller.rows, greaterThan(0));
      // Without the header the terminal has more vertical space, so it should
      // expose at least as many rows (strictly more when the header height is
      // large enough to gain a full line).
      expect(controller.rows, greaterThanOrEqualTo(rowsWithHeader));
    });

    testWidgets('renders VT-backed controller output', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('hello\r\nsecond line');
      await tester.pumpWidget(buildView());
      await tester.pump();

      expect(controller.lines, ['hello', 'second line']);
      expect(controller.plainText, 'hello\nsecond line');
    });

    testWidgets('exposes native render-state data while the view renders', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('\u001b[31mhello\u001b[0m\r\nsecond line');
      await tester.pumpWidget(
        buildView(renderer: GhosttyTerminalRendererMode.renderState),
      );
      await tester.pump();

      expect(find.byType(GhosttyTerminalView), findsOneWidget);
      expect(controller.renderSnapshot, isNotNull);
      expect(controller.snapshot.lines, isNotEmpty);
      expect(controller.snapshot.lines.first.text, contains('hello'));
    });

    testWidgets(
      'keeps painted color output consistent across formatter and renderState',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('\x1b[31;1mX\x1b[0m');

        await tester.pumpWidget(buildView());
        await tester.pump();

        final formatterStyle =
            controller.snapshot.lines.first.runs.single.style;
        expect(formatterStyle.foreground, isNotNull);

        await tester.pumpWidget(
          buildView(renderer: GhosttyTerminalRendererMode.renderState),
        );
        await tester.pump();

        final renderSnapshot = controller.renderSnapshot;
        expect(renderSnapshot, isNotNull);
        final row = renderSnapshot!.rowsData.first;
        final cell = row.cells.firstWhere((cell) => cell.hasText);
        final renderStyle = cell.style;

        expect(renderStyle.foreground, isNot(const Color(0x00000000)));
        expect(renderStyle.bold, isTrue);
        expect(cell.hasStyling, isTrue);
      },
    );

    testWidgets(
      'formatter and renderState paint comparable colored pixel coverage',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput(
          '\x1b[31;1mCPU\x1b[0m  '
          '\x1b[32mRAM\x1b[0m\r\n'
          'plain text',
        );

        final formatterKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: formatterKey,
            child: buildView(
              renderer: GhosttyTerminalRendererMode.formatter,
              backgroundColor: const Color(0xFF0A0F14),
              foregroundColor: const Color(0xFFE6EDF3),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final formatterStats = await _captureTerminalPaintStats(formatterKey);

        final renderStateKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: renderStateKey,
            child: buildView(
              renderer: GhosttyTerminalRendererMode.renderState,
              backgroundColor: const Color(0xFF0A0F14),
              foregroundColor: const Color(0xFFE6EDF3),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final renderStateStats = await _captureTerminalPaintStats(
          renderStateKey,
        );

        expect(formatterStats.nonBackgroundPixels, greaterThan(0));
        expect(renderStateStats.nonBackgroundPixels, greaterThan(0));
        expect(formatterStats.redPixels, greaterThan(0));
        expect(renderStateStats.redPixels, greaterThan(0));
        expect(formatterStats.greenPixels, greaterThan(0));
        expect(renderStateStats.greenPixels, greaterThan(0));

        final nonBackgroundRatio =
            renderStateStats.nonBackgroundPixels /
            formatterStats.nonBackgroundPixels;
        final redRatio = renderStateStats.redPixels / formatterStats.redPixels;
        final greenRatio =
            renderStateStats.greenPixels / formatterStats.greenPixels;

        expect(nonBackgroundRatio, inInclusiveRange(0.55, 1.8));
        expect(redRatio, inInclusiveRange(0.4, 2.5));
        expect(greenRatio, inInclusiveRange(0.4, 2.5));
      },
    );

    testWidgets(
      'renderState honors widget default background and foreground colors',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        const widgetBackground = Color(0xFF112233);
        const widgetForeground = Color(0xFF55E0D0);

        controller.appendDebugOutput('MMMM');

        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: buildView(
              showHeader: false,
              renderer: GhosttyTerminalRendererMode.renderState,
              backgroundColor: widgetBackground,
              foregroundColor: widgetForeground,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final image = await _captureTerminalImageData(key);

        expect(
          _pixelMatchesColor(
            image,
            x: image.width - 20,
            y: image.height ~/ 2,
            color: widgetBackground,
          ),
          isTrue,
        );
        expect(
          _countPixelsNearColor(image, color: widgetForeground, tolerance: 32),
          greaterThan(12),
        );
      },
    );

    testWidgets(
      'renderState keeps explicit native default colors distinct from widget defaults',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        const widgetBackground = Color(0xFF112233);
        const widgetForeground = Color(0xFF55E0D0);

        await tester.pumpWidget(
          buildView(
            showHeader: false,
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: widgetBackground,
            foregroundColor: widgetForeground,
          ),
        );
        await tester.pumpAndSettle();

        final nativeRender = controller.renderSnapshot;
        expect(nativeRender, isNotNull);
        final nativeForeground = nativeRender!.foregroundColor;
        final nativeBackground = nativeRender.backgroundColor;

        String rgb(Color color) =>
            '${_colorRed8(color)};${_colorGreen8(color)};${_colorBlue8(color)}';

        controller.appendDebugOutput(
          '\x1b[48;2;${rgb(nativeBackground)}m '
          '\x1b[0m '
          '\x1b[38;2;${rgb(nativeForeground)}m██\x1b[0m',
        );

        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: buildView(
              showHeader: false,
              renderer: GhosttyTerminalRendererMode.renderState,
              backgroundColor: widgetBackground,
              foregroundColor: widgetForeground,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final image = await _captureTerminalImageData(key);
        final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
        final rowCenterY = padding + (linePixels ~/ 2);
        final explicitBackgroundX = padding + (charWidth ~/ 2);

        expect(
          _pixelMatchesColor(
            image,
            x: explicitBackgroundX,
            y: rowCenterY,
            color: nativeBackground,
            tolerance: 8,
          ),
          isTrue,
        );
        expect(
          _pixelMatchesColor(
            image,
            x: explicitBackgroundX,
            y: rowCenterY,
            color: widgetBackground,
            tolerance: 8,
          ),
          isFalse,
        );
        expect(
          _countPixelsNearColor(image, color: nativeForeground, tolerance: 24),
          greaterThan(8),
        );
      },
    );

    testWidgets('renderState honors widget cursor color', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      const widgetCursor = Color(0xFFFF4FD8);

      controller.appendDebugOutput('abc');

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            showHeader: false,
            autofocus: true,
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF112233),
            foregroundColor: const Color(0xFFE6EDF3),
            cursorColor: widgetCursor,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final cursorCenterX = padding + (3 * charWidth) + (charWidth ~/ 2);
      final cursorCenterY = padding + (linePixels ~/ 2);

      expect(
        _pixelMatchesColor(
          image,
          x: cursorCenterX,
          y: cursorCenterY,
          color: widgetCursor,
          tolerance: 24,
        ),
        isTrue,
      );
    });

    testWidgets('formatter prefers the native cursor position when available', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      const widgetCursor = Color(0xFFFF4FD8);

      controller.appendDebugOutput('abc');

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            showHeader: false,
            autofocus: true,
            renderer: GhosttyTerminalRendererMode.formatter,
            backgroundColor: const Color(0xFF112233),
            foregroundColor: const Color(0xFFE6EDF3),
            cursorColor: widgetCursor,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final cursorCenterX = padding + (3 * charWidth) + (charWidth ~/ 2);
      final cursorCenterY = padding + (linePixels ~/ 2);

      expect(
        _pixelMatchesColor(
          image,
          x: cursorCenterX,
          y: cursorCenterY,
          color: widgetCursor,
          tolerance: 24,
        ),
        isTrue,
      );
    });

    testWidgets('renderState wide-tail cursor covers the full wide cell', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      const widgetCursor = Color(0xFFFF44AA);
      controller.appendDebugOutput('界\x1b[D');
      expect(controller.renderSnapshot?.cursor.onWideTail, isTrue);

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            showHeader: false,
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF112233),
            foregroundColor: const Color(0xFFE6EDF3),
            cursorColor: widgetCursor,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final rowCenterY = padding + (linePixels ~/ 2);
      final firstCellCenterX = padding + (charWidth ~/ 2);
      final secondCellCenterX = padding + charWidth + (charWidth ~/ 2);
      final thirdCellCenterX = padding + (2 * charWidth) + (charWidth ~/ 2);

      expect(
        _pixelMatchesColor(
          image,
          x: firstCellCenterX,
          y: rowCenterY,
          color: widgetCursor,
          tolerance: 30,
        ),
        isTrue,
      );
      expect(
        _pixelMatchesColor(
          image,
          x: secondCellCenterX,
          y: rowCenterY,
          color: widgetCursor,
          tolerance: 30,
        ),
        isTrue,
      );
      expect(
        _pixelMatchesColor(
          image,
          x: thirdCellCenterX,
          y: rowCenterY,
          color: widgetCursor,
          tolerance: 30,
        ),
        isFalse,
      );
    });

    testWidgets('renderState underline cursor paints on the bottom row edge', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      const widgetCursor = Color(0xFF44D7FF);
      controller.appendDebugOutput('\x1b[4 qA');
      expect(
        controller.renderSnapshot?.cursor.visualStyle,
        GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE,
      );

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            showHeader: false,
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF112233),
            foregroundColor: const Color(0xFFE6EDF3),
            cursorColor: widgetCursor,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final cursorX = padding + (charWidth ~/ 2);
      final cursorY = padding + linePixels - 2;

      expect(
        _pixelMatchesColor(
          image,
          x: cursorX,
          y: cursorY,
          color: widgetCursor,
          tolerance: 30,
        ),
        isTrue,
      );
    });

    testWidgets('renderState bar cursor stays on the leading cell edge', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      const widgetCursor = Color(0xFF6EE7B7);
      controller.appendDebugOutput('\x1b[6 qA');
      expect(
        controller.renderSnapshot?.cursor.visualStyle,
        GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR,
      );

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            showHeader: false,
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF112233),
            foregroundColor: const Color(0xFFE6EDF3),
            cursorColor: widgetCursor,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final rowCenterY = padding + (linePixels ~/ 2);
      final leadingEdgeX = padding + 1;
      final trailingCellX = padding + charWidth + (charWidth ~/ 2);

      expect(
        _pixelMatchesColor(
          image,
          x: leadingEdgeX,
          y: rowCenterY,
          color: widgetCursor,
          tolerance: 30,
        ),
        isTrue,
      );
      expect(
        _pixelMatchesColor(
          image,
          x: trailingCellX,
          y: rowCenterY,
          color: widgetCursor,
          tolerance: 30,
        ),
        isFalse,
      );
    });

    testWidgets('renderState honors widget hyperlink color', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      const widgetHyperlink = Color(0xFFFFA347);
      controller.appendDebugOutput(
        '\x1b]8;;https://example.com\x1b\\\\link\x1b]8;;\x1b\\\\',
      );

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            showHeader: false,
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF112233),
            foregroundColor: const Color(0xFFE6EDF3),
            hyperlinkColor: widgetHyperlink,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      expect(
        _countPixelsNearColor(image, color: widgetHyperlink, tolerance: 28),
        greaterThan(10),
      );
    });

    testWidgets('scrollback does not paint the snapshot cursor', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      Future<void> expectNoCursorInScrollback(
        GhosttyTerminalRendererMode renderer,
      ) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        const widgetCursor = Color(0xFFFF00FF);
        final key = GlobalKey();

        controller.clear();
        controller.appendDebugOutput(
          List<String>.generate(120, (index) => 'Line $index').join('\r\n'),
        );

        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: buildView(
              showHeader: false,
              renderer: renderer,
              scrollController: scrollController,
              cursorColor: widgetCursor,
            ),
          ),
        );
        await tester.pumpAndSettle();

        scrollController.jumpTo(300);
        await tester.pumpAndSettle();

        final image = await _captureTerminalImageData(key);
        expect(
          _countPixelsNearColor(image, color: widgetCursor, tolerance: 20),
          0,
        );
      }

      await expectNoCursorInScrollback(GhosttyTerminalRendererMode.formatter);
      await expectNoCursorInScrollback(GhosttyTerminalRendererMode.renderState);
    });

    testWidgets('renderState honors widget selection color', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      const widgetSelection = Color(0xCCFF6A3D);
      controller.appendDebugOutput('select me');

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            showHeader: false,
            autofocus: true,
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF112233),
            foregroundColor: const Color(0xFFE6EDF3),
            selectionColor: widgetSelection,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      expect(
        _countPixelsNearColor(image, color: widgetSelection, tolerance: 32),
        greaterThan(20),
      );
    });

    testWidgets(
      'renderState selection remains visible over explicit native backgrounds',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        const widgetSelection = Color(0xCC34D399);
        controller.appendDebugOutput('\x1b[44;97mBLUE\x1b[0m normal');

        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: buildView(
              showHeader: false,
              autofocus: true,
              renderer: GhosttyTerminalRendererMode.renderState,
              backgroundColor: const Color(0xFF112233),
              foregroundColor: const Color(0xFFE6EDF3),
              selectionColor: widgetSelection,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        final image = await _captureTerminalImageData(key);
        expect(
          _countPixelsNearColor(image, color: widgetSelection, tolerance: 32),
          greaterThan(20),
        );
      },
    );

    testWidgets(
      'formatter and renderState paint comparable mixed-width pixel coverage',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('A🙂界e\u0301Z\r\nwide mix');

        final formatterStats = await _captureModePaintStats(
          tester,
          buildView: buildView,
          renderer: GhosttyTerminalRendererMode.formatter,
        );
        final renderStateStats = await _captureModePaintStats(
          tester,
          buildView: buildView,
          renderer: GhosttyTerminalRendererMode.renderState,
        );

        expect(formatterStats.nonBackgroundPixels, greaterThan(0));
        expect(renderStateStats.nonBackgroundPixels, greaterThan(0));

        final ratio =
            renderStateStats.nonBackgroundPixels /
            formatterStats.nonBackgroundPixels;
        expect(ratio, inInclusiveRange(0.55, 1.9));
      },
    );

    testWidgets(
      'formatter and renderState paint comparable inverse and blue background coverage',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput(
          '\x1b[7;31mINV\x1b[0m '
          '\x1b[44;97mBOX\x1b[0m '
          '\x1b[33mWARN\x1b[0m',
        );

        final formatterStats = await _captureModePaintStats(
          tester,
          buildView: buildView,
          renderer: GhosttyTerminalRendererMode.formatter,
        );
        final renderStateStats = await _captureModePaintStats(
          tester,
          buildView: buildView,
          renderer: GhosttyTerminalRendererMode.renderState,
        );

        expect(formatterStats.bluePixels, greaterThan(0));
        expect(renderStateStats.bluePixels, greaterThan(0));
        expect(formatterStats.redPixels, greaterThan(0));
        expect(renderStateStats.redPixels, greaterThan(0));

        final blueRatio =
            renderStateStats.bluePixels / formatterStats.bluePixels;
        final redRatio = renderStateStats.redPixels / formatterStats.redPixels;
        expect(blueRatio, inInclusiveRange(0.35, 2.8));
        expect(redRatio, inInclusiveRange(0.35, 2.8));
      },
    );

    testWidgets('box drawing borders paint as continuous strokes', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('┌────┐\r\n│    │\r\n└────┘');

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF0A0F14),
            foregroundColor: const Color(0xFFE6EDF3),
            fontSize: 14,
            lineHeight: 1.35,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      const headerHeight = 28;
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final topRowY = headerHeight + padding + (linePixels ~/ 2);
      final leftColX = padding + charWidth;
      final firstCellCenterX = padding + charWidth;
      final lastCellCenterX = padding + (5 * charWidth) + charWidth;
      final middleRowY =
          headerHeight + padding + linePixels + (linePixels ~/ 2);
      final bottomRowY =
          headerHeight + padding + (2 * linePixels) + (linePixels ~/ 2);

      expect(
        _countNonBackgroundPixelsInHorizontalSpan(
          image,
          y: topRowY,
          startX: firstCellCenterX,
          endX: lastCellCenterX,
        ),
        greaterThanOrEqualTo(lastCellCenterX - firstCellCenterX - 2),
      );
      expect(
        _countNonBackgroundPixelsInVerticalSpan(
          image,
          x: leftColX,
          startY: topRowY,
          endY: bottomRowY,
        ),
        greaterThanOrEqualTo(bottomRowY - topRowY - 2),
      );
      expect(_pixelIsNonBackground(image, x: leftColX, y: middleRowY), isTrue);
    });

    testWidgets('single-cell circle glyphs keep spacing inside the cell', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('○A');

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF0A0F14),
            foregroundColor: const Color(0xFFE6EDF3),
            fontSize: 14,
            lineHeight: 1.35,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      const headerHeight = 28;
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final cellCenterY = headerHeight + padding + (linePixels ~/ 2);
      final circleCenterX = padding + (charWidth ~/ 2);
      final circleRightEdgeX = padding + charWidth - 1;

      expect(
        _pixelIsNonBackground(image, x: circleCenterX, y: cellCenterY),
        isTrue,
      );
      expect(
        _pixelIsNonBackground(image, x: circleRightEdgeX, y: cellCenterY),
        isFalse,
      );
    });

    testWidgets('rounded box corners paint into the expected quadrants', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('╭─╮\r\n│ │\r\n╰─╯');

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: buildView(
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF0A0F14),
            foregroundColor: const Color(0xFFE6EDF3),
            fontSize: 14,
            lineHeight: 1.35,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _captureTerminalImageData(key);
      const headerHeight = 28;
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();

      final topRowY = headerHeight + padding + (linePixels ~/ 2);
      final bottomRowY =
          headerHeight + padding + (2 * linePixels) + (linePixels ~/ 2);
      final leftCornerX = padding + 2;
      final rightCornerX = padding + (2 * charWidth) + 4;

      expect(
        _pixelIsNonBackground(image, x: leftCornerX, y: topRowY + 3),
        isTrue,
      );
      expect(
        _pixelIsNonBackground(image, x: leftCornerX, y: topRowY - 3),
        isFalse,
      );
      expect(
        _pixelIsNonBackground(image, x: rightCornerX, y: topRowY + 3),
        isTrue,
      );
      expect(
        _pixelIsNonBackground(image, x: rightCornerX, y: topRowY - 3),
        isFalse,
      );
      expect(
        _pixelIsNonBackground(image, x: leftCornerX, y: bottomRowY - 3),
        isTrue,
      );
      expect(
        _pixelIsNonBackground(image, x: leftCornerX, y: bottomRowY + 3),
        isFalse,
      );
      expect(
        _pixelIsNonBackground(image, x: rightCornerX, y: bottomRowY - 3),
        isTrue,
      );
      expect(
        _pixelIsNonBackground(image, x: rightCornerX, y: bottomRowY + 3),
        isFalse,
      );
    });

    testWidgets('renderState paints common tui symbols with visible coverage', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('✓→▼—');

      final formatterStats = await _captureModePaintStats(
        tester,
        buildView: buildView,
        renderer: GhosttyTerminalRendererMode.formatter,
      );
      final renderStateStats = await _captureModePaintStats(
        tester,
        buildView: buildView,
        renderer: GhosttyTerminalRendererMode.renderState,
      );

      expect(formatterStats.nonBackgroundPixels, greaterThan(0));
      expect(renderStateStats.nonBackgroundPixels, greaterThan(0));

      final ratio =
          renderStateStats.nonBackgroundPixels /
          formatterStats.nonBackgroundPixels;
      expect(ratio, inInclusiveRange(0.55, 1.8));
    });

    testWidgets(
      'renderState paints btop braille and symbol glyphs with visible coverage',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('▲■←↑↓↵°¹²³⁴ ⢰⢸⣀⣿');

        final formatterStats = await _captureModePaintStats(
          tester,
          buildView: buildView,
          renderer: GhosttyTerminalRendererMode.formatter,
        );
        final renderStateStats = await _captureModePaintStats(
          tester,
          buildView: buildView,
          renderer: GhosttyTerminalRendererMode.renderState,
        );

        expect(formatterStats.nonBackgroundPixels, greaterThan(0));
        expect(renderStateStats.nonBackgroundPixels, greaterThan(0));

        final ratio =
            renderStateStats.nonBackgroundPixels /
            formatterStats.nonBackgroundPixels;
        expect(ratio, inInclusiveRange(0.45, 2.2));
      },
    );

    testWidgets(
      'renderState preserves explicit blank cells between separated glyphs',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('A\x1b[3CB');

        final formatterKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: formatterKey,
            child: buildView(
              renderer: GhosttyTerminalRendererMode.formatter,
              backgroundColor: const Color(0xFF0A0F14),
              foregroundColor: const Color(0xFFE6EDF3),
              fontSize: 14,
              lineHeight: 1.35,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final formatterImage = await _captureTerminalImageData(formatterKey);

        final renderStateKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: renderStateKey,
            child: buildView(
              renderer: GhosttyTerminalRendererMode.renderState,
              backgroundColor: const Color(0xFF0A0F14),
              foregroundColor: const Color(0xFFE6EDF3),
              fontSize: 14,
              lineHeight: 1.35,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final renderStateImage = await _captureTerminalImageData(
          renderStateKey,
        );

        const headerHeight = 28;
        final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
        final rowCenterY = headerHeight + padding + (linePixels ~/ 2);

        expect(
          _pixelIsNonBackground(
            formatterImage,
            x: padding + (charWidth ~/ 2),
            y: rowCenterY,
          ),
          isTrue,
        );
        expect(
          _pixelIsNonBackground(
            formatterImage,
            x: padding + (4 * charWidth) + (charWidth ~/ 2),
            y: rowCenterY,
          ),
          isTrue,
        );
        expect(
          _pixelIsNonBackground(
            renderStateImage,
            x: padding + (charWidth ~/ 2),
            y: rowCenterY,
          ),
          isTrue,
        );
        expect(
          _pixelIsNonBackground(
            renderStateImage,
            x: padding + (4 * charWidth) + (charWidth ~/ 2),
            y: rowCenterY,
          ),
          isTrue,
        );

        for (final gapCol in <int>[1, 2, 3]) {
          final gapCenterX = padding + (gapCol * charWidth) + (charWidth ~/ 2);
          expect(
            _pixelIsNonBackground(formatterImage, x: gapCenterX, y: rowCenterY),
            isFalse,
          );
          expect(
            _pixelIsNonBackground(
              renderStateImage,
              x: gapCenterX,
              y: rowCenterY,
            ),
            isFalse,
          );
        }
      },
    );

    testWidgets('renderState preserves wide glyph advance before later cells', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('界\x1b[2CX');

      final formatterKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: formatterKey,
          child: buildView(
            renderer: GhosttyTerminalRendererMode.formatter,
            backgroundColor: const Color(0xFF0A0F14),
            foregroundColor: const Color(0xFFE6EDF3),
            fontSize: 14,
            lineHeight: 1.35,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final formatterImage = await _captureTerminalImageData(formatterKey);

      final renderStateKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: renderStateKey,
          child: buildView(
            renderer: GhosttyTerminalRendererMode.renderState,
            backgroundColor: const Color(0xFF0A0F14),
            foregroundColor: const Color(0xFFE6EDF3),
            fontSize: 14,
            lineHeight: 1.35,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final renderStateImage = await _captureTerminalImageData(renderStateKey);

      const headerHeight = 28;
      final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
      final rowCenterY = headerHeight + padding + (linePixels ~/ 2);

      expect(
        _pixelIsNonBackground(
          formatterImage,
          x: padding + (charWidth ~/ 2),
          y: rowCenterY,
        ),
        isTrue,
      );
      expect(
        _pixelIsNonBackground(
          renderStateImage,
          x: padding + (charWidth ~/ 2),
          y: rowCenterY,
        ),
        isTrue,
      );

      for (final gapCol in <int>[2, 3]) {
        final gapCenterX = padding + (gapCol * charWidth) + (charWidth ~/ 2);
        expect(
          _pixelIsNonBackground(formatterImage, x: gapCenterX, y: rowCenterY),
          isFalse,
        );
        expect(
          _pixelIsNonBackground(renderStateImage, x: gapCenterX, y: rowCenterY),
          isFalse,
        );
      }

      final trailingGlyphX = padding + (4 * charWidth) + (charWidth ~/ 2);
      expect(
        _pixelIsNonBackground(formatterImage, x: trailingGlyphX, y: rowCenterY),
        isTrue,
      );
      expect(
        _pixelIsNonBackground(
          renderStateImage,
          x: trailingGlyphX,
          y: rowCenterY,
        ),
        isTrue,
      );
    });

    testWidgets(
      'formatter and renderState paint comparable underline coverage',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('plain \x1b[4;34mblue\x1b[0m');

        final formatterKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: formatterKey,
            child: buildView(
              renderer: GhosttyTerminalRendererMode.formatter,
              backgroundColor: const Color(0xFF0A0F14),
              foregroundColor: const Color(0xFFE6EDF3),
              fontSize: 14,
              lineHeight: 1.35,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final formatterImage = await _captureTerminalImageData(formatterKey);

        final renderStateKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: renderStateKey,
            child: buildView(
              renderer: GhosttyTerminalRendererMode.renderState,
              backgroundColor: const Color(0xFF0A0F14),
              foregroundColor: const Color(0xFFE6EDF3),
              fontSize: 14,
              lineHeight: 1.35,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final renderStateImage = await _captureTerminalImageData(
          renderStateKey,
        );

        const headerHeight = 28;
        final (:charWidth, :linePixels, :padding) = _measureTestMetrics();
        final underlineY = headerHeight + padding + linePixels - 3;
        final underlineStartX = padding + (6 * charWidth);
        final underlineEndX = padding + (10 * charWidth) - 2;

        final formatterUnderlinePixels =
            _countNonBackgroundPixelsInHorizontalSpan(
              formatterImage,
              y: underlineY,
              startX: underlineStartX,
              endX: underlineEndX,
            );
        final renderStateUnderlinePixels =
            _countNonBackgroundPixelsInHorizontalSpan(
              renderStateImage,
              y: underlineY,
              startX: underlineStartX,
              endX: underlineEndX,
            );

        expect(formatterUnderlinePixels, greaterThan(0));
        expect(renderStateUnderlinePixels, greaterThan(0));

        final underlineRatio =
            renderStateUnderlinePixels / formatterUnderlinePixels;
        expect(underlineRatio, inInclusiveRange(0.45, 1.9));
      },
    );

    testWidgets(
      'formatter and renderState paint comparable selection coverage over custom glyphs',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('╭─╮\r\n│✓│\r\n╰─╯');

        Future<_TerminalPaintStats> captureSelectedStats(
          GhosttyTerminalRendererMode renderer,
        ) async {
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: buildView(
                autofocus: true,
                renderer: renderer,
                backgroundColor: const Color(0xFF0A0F14),
                foregroundColor: const Color(0xFFE6EDF3),
                fontSize: 14,
                lineHeight: 1.35,
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();

          return _captureTerminalPaintStats(key);
        }

        final formatterStats = await captureSelectedStats(
          GhosttyTerminalRendererMode.formatter,
        );
        final renderStateStats = await captureSelectedStats(
          GhosttyTerminalRendererMode.renderState,
        );

        expect(formatterStats.bluePixels, greaterThan(0));
        expect(renderStateStats.bluePixels, greaterThan(0));

        final blueRatio =
            renderStateStats.bluePixels / formatterStats.bluePixels;
        final nonBackgroundRatio =
            renderStateStats.nonBackgroundPixels /
            formatterStats.nonBackgroundPixels;

        expect(blueRatio, inInclusiveRange(0.4, 2.5));
        expect(nonBackgroundRatio, inInclusiveRange(0.55, 1.9));
      },
    );

    testWidgets('updates when controller notifies', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          autofocus: true,
          onSelectionContentChanged: (c) => currentContent = c,
        ),
      );

      final initialRevision = controller.revision;
      controller.appendDebugOutput('new output');
      await tester.pump();

      expect(controller.revision, greaterThan(initialRevision));
      expect(controller.lines.single, 'new output');

      // Verify the rendered widget tree reflects the new content by selecting
      // the word at the first visible row via triple-tap.
      const firstRowTarget = Offset(30, 24);
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pumpAndSettle();

      expect(currentContent, isNotNull);
      // The rendered first row contains the newly appended text.
      expect(currentContent?.text, anyOf(equals('new'), equals('output')));
    });

    testWidgets('autofocus requests focus on build', (tester) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(buildView(autofocus: true, focusNode: focusNode));
      await tester.pumpAndSettle();

      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('pointer down claims focus from a sibling text field', (
      tester,
    ) async {
      final terminalFocusNode = FocusNode();
      final editorFocusNode = FocusNode();
      addTearDown(terminalFocusNode.dispose);
      addTearDown(editorFocusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 320,
                  height: 56,
                  child: TextField(focusNode: editorFocusNode),
                ),
                SizedBox(
                  width: 600,
                  height: 320,
                  child: GhosttyTerminalView(
                    controller: controller,
                    focusNode: terminalFocusNode,
                    interactionPolicy:
                        GhosttyTerminalInteractionPolicy.terminalMouseFirst,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      editorFocusNode.requestFocus();
      await tester.pump();
      expect(editorFocusNode.hasFocus, isTrue);

      final gesture = await tester.createGesture(
        kind: ui.PointerDeviceKind.touch,
      );
      await gesture.down(tester.getCenter(find.byType(GhosttyTerminalView)));
      await tester.pump();

      expect(terminalFocusNode.hasFocus, isTrue);
      expect(editorFocusNode.hasFocus, isFalse);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('switches controllers correctly', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller2 = GhosttyTerminalController();
      addTearDown(controller2.dispose);

      controller.appendDebugOutput('from controller 1');
      await tester.pumpWidget(buildView());
      await tester.pump();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(controller: controller2),
            ),
          ),
        ),
      );

      controller2.appendDebugOutput('from controller 2');
      await tester.pump();

      expect(controller2.lines.single, 'from controller 2');
    });

    testWidgets('applies custom styling props', (tester) async {
      await tester.pumpWidget(
        buildView(
          backgroundColor: const Color(0xFF000000),
          foregroundColor: const Color(0xFFFFFFFF),
          fontSize: 18,
          lineHeight: 1.5,
          padding: const EdgeInsets.all(24),
        ),
      );

      expect(find.byType(GhosttyTerminalView), findsOneWidget);
    });

    testWidgets('cell width scale changes the reported grid columns', (
      tester,
    ) async {
      final defaultController = GhosttyTerminalController();
      addTearDown(defaultController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(controller: defaultController),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final defaultCols = defaultController.cols;

      final scaledController = GhosttyTerminalController();
      addTearDown(scaledController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: scaledController,
                fontFamily: 'monospace',
                cellWidthScale: 1.25,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(scaledController.cols, lessThan(defaultCols));
    });

    testWidgets('handles many lines without overflow', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      final manyLines = List.generate(200, (i) => 'Line $i').join('\r\n');
      controller.appendDebugOutput(manyLines);

      await tester.pumpWidget(buildView());
      await tester.pump();

      expect(controller.lineCount, 200);
      expect(controller.lines.first, 'Line 0');
      expect(controller.lines.last, 'Line 199');
    });

    testWidgets('vertical scrollbar drag updates the visible transcript', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;
      controller.appendDebugOutput(
        List<String>.generate(120, (index) => 'Line $index').join('\r\n'),
      );

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          showVerticalScrollbar: true,
          autofocus: true,
          onSelectionContentChanged: (content) => currentContent = content,
        ),
      );
      await tester.pumpAndSettle();

      const firstRowTarget = Offset(30, 24);
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pumpAndSettle();

      expect(currentContent?.text, 'Line 0');

      final scrollbar = await tester.startGesture(const Offset(595, 48));
      await scrollbar.moveTo(const Offset(595, 320));
      await scrollbar.up();
      await tester.pumpAndSettle();

      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pumpAndSettle();

      expect(currentContent, isNotNull);
      expect(currentContent?.text, isNot('Line 0'));
    });

    testWidgets(
      'ancestor NotificationListener receives terminal scroll notifications',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final notifications = <ScrollNotification>[];

        controller.appendDebugOutput(
          List<String>.generate(120, (index) => 'Line $index').join('\r\n'),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  notifications.add(notification);
                  return false;
                },
                child: SizedBox(
                  width: 600,
                  height: 400,
                  child: GhosttyTerminalView(
                    controller: controller,
                    showHeader: false,
                    scrollController: scrollController,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        scrollController.jumpTo(300);
        await tester.pumpAndSettle();

        expect(notifications, isNotEmpty);
      },
    );

    testWidgets('external ScrollController drives transcript scrolling', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;
      controller.appendDebugOutput(
        List<String>.generate(120, (index) => 'Line $index').join('\r\n'),
      );

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          autofocus: true,
          scrollController: scrollController,
          onSelectionContentChanged: (content) => currentContent = content,
        ),
      );
      await tester.pumpAndSettle();

      const firstRowTarget = Offset(30, 24);
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pumpAndSettle();
      expect(currentContent?.text, 'Line 0');

      scrollController.jumpTo(300);
      await tester.pumpAndSettle();

      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(firstRowTarget);
      await tester.pumpAndSettle();

      expect(currentContent, isNotNull);
      expect(currentContent?.text, isNot('Line 0'));
    });

    testWidgets(
      'new terminal activity snaps the viewport back to the live bottom when enabled',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;

        controller.appendDebugOutput(
          List<String>.generate(120, (index) => 'Line $index').join('\r\n'),
        );

        await tester.pumpWidget(
          buildView(
            showHeader: false,
            autofocus: true,
            scrollController: scrollController,
            autoFollowOnActivity: true,
            onSelectionContentChanged: (c) => currentContent = c,
          ),
        );
        await tester.pumpAndSettle();

        // Probe the visible first row before scrolling — should be near the
        // bottom of the transcript (offset is 0, content runs to "Line 119").
        const firstRowTarget = Offset(30, 24);
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pumpAndSettle();
        // The rendered first row at the live bottom must not be "Line 0".
        expect(currentContent?.text, isNot('Line 0'));

        scrollController.jumpTo(300);
        await tester.pumpAndSettle();
        expect(scrollController.offset, greaterThan(0));

        // Triple-tap the first visible row at the scrolled position.
        currentContent = null;
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pumpAndSettle();
        // Scrolled up, so the first visible row should be from earlier lines.
        expect(currentContent?.text, isNot('Tail'));

        controller.appendDebugOutput('\r\nTail');
        await tester.pumpAndSettle();

        // Auto-follow snaps back to offset 0.
        expect(scrollController.offset, 0);

        // Probe the rendered first row after snap — should be near the bottom,
        // not "Line 0" which is far up the transcript.
        currentContent = null;
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pumpAndSettle();
        expect(currentContent, isNotNull);
        expect(currentContent?.text, isNot('Line 0'));
      },
    );

    testWidgets(
      'new terminal activity does not move the viewport when auto follow is disabled',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;

        controller.appendDebugOutput(
          List<String>.generate(120, (index) => 'Line $index').join('\r\n'),
        );

        await tester.pumpWidget(
          buildView(
            showHeader: false,
            autofocus: true,
            scrollController: scrollController,
            autoFollowOnActivity: false,
            onSelectionContentChanged: (c) => currentContent = c,
          ),
        );
        await tester.pumpAndSettle();

        scrollController.jumpTo(300);
        await tester.pumpAndSettle();
        final preservedOffset = scrollController.offset;
        expect(preservedOffset, greaterThan(0));

        // Probe the first visible row at the scrolled position.
        const firstRowTarget = Offset(30, 24);
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pumpAndSettle();
        // Scrolled up — first row is not the live-bottom tail.
        expect(currentContent?.text, isNot('Tail'));
        final scrolledRowText = currentContent?.text;

        controller.appendDebugOutput('\r\nTail');
        await tester.pumpAndSettle();

        // Without auto-follow the viewport stays put.
        expect(scrollController.offset, preservedOffset);

        // The rendered first row must still show the same content as before the
        // new output arrived — the viewport did not move.
        currentContent = null;
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pumpAndSettle();
        expect(currentContent, isNotNull);
        expect(currentContent?.text, scrolledRowText);
      },
    );

    testWidgets(
      'keyboard input jumps back to the live bottom even when auto follow is disabled',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;

        controller.appendDebugOutput(
          List<String>.generate(120, (index) => 'Line $index').join('\r\n'),
        );

        await tester.pumpWidget(
          buildView(
            showHeader: false,
            autofocus: true,
            scrollController: scrollController,
            autoFollowOnActivity: false,
            onSelectionContentChanged: (c) => currentContent = c,
          ),
        );
        await tester.pumpAndSettle();

        scrollController.jumpTo(300);
        await tester.pumpAndSettle();
        expect(scrollController.offset, greaterThan(0));

        // Probe the rendered first row at the scrolled position — should be
        // somewhere in the middle of the transcript (e.g. a mid-range "Line N").
        const firstRowTarget = Offset(30, 24);
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pumpAndSettle();
        expect(currentContent?.text, isNot('Line 119'));

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        // Keyboard input snaps back to the live bottom.
        expect(scrollController.offset, 0);

        // The rendered first row must now show content from near the bottom of
        // the transcript — not from far-up "Line 0".
        currentContent = null;
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(firstRowTarget);
        await tester.pumpAndSettle();
        expect(currentContent, isNotNull);
        expect(currentContent?.text, isNot('Line 0'));
      },
    );

    testWidgets('handles empty lines and explicit line starts', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('line1\r\n\r\n\r\nline4');

      await tester.pumpWidget(buildView());
      await tester.pump();

      expect(controller.lines, ['line1', '', '', 'line4']);
    });

    testWidgets('select-all and escape expose selection callbacks', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelection? currentSelection;
      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;
      controller.appendDebugOutput('hello  \r\nsecond line');

      await tester.pumpWidget(
        buildView(
          autofocus: true,
          onSelectionChanged: (selection) => currentSelection = selection,
          onSelectionContentChanged: (content) => currentContent = content,
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(currentSelection, isNotNull);
      expect(currentContent?.text, 'hello\nsecond line');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(currentSelection, isNull);
      expect(currentContent, isNull);
    });

    testWidgets('double click selects the whole word', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelection? currentSelection;
      controller.appendDebugOutput('hello world');

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          autofocus: true,
          onSelectionChanged: (selection) => currentSelection = selection,
        ),
      );
      await tester.pumpAndSettle();

      const target = Offset(30, 24);
      await tester.tapAt(target);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(target);
      await tester.pumpAndSettle();

      expect(currentSelection, isNotNull);
      expect(controller.snapshot.textForSelection(currentSelection!), 'hello');
    });

    testWidgets(
      'single tap after word selection clears instead of selecting a cell',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        GhosttyTerminalSelection? currentSelection;
        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;
        controller.appendDebugOutput('hello world');

        await tester.pumpWidget(
          buildView(
            showHeader: false,
            autofocus: true,
            onSelectionChanged: (selection) => currentSelection = selection,
            onSelectionContentChanged: (content) => currentContent = content,
          ),
        );
        await tester.pumpAndSettle();

        const wordTarget = Offset(30, 24);
        await tester.tapAt(wordTarget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(wordTarget);
        await tester.pumpAndSettle();

        expect(currentSelection, isNotNull);
        expect(currentContent?.text, 'hello');

        await tester.pump(const Duration(milliseconds: 500));
        await tester.tapAt(const Offset(78, 24));
        await tester.pumpAndSettle();

        expect(currentSelection, isNull);
        expect(currentContent, isNull);
      },
    );

    testWidgets(
      'renderState double click selects words on wrapped visible rows',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 120,
                height: 160,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                  showHeader: false,
                  renderer: GhosttyTerminalRendererMode.renderState,
                  onSelectionContentChanged: (content) =>
                      currentContent = content,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        controller.appendDebugOutput('${'a' * (controller.cols - 1)} target');
        await tester.pumpAndSettle();

        const target = Offset(30, 43);
        await tester.tapAt(target);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(target);
        await tester.pumpAndSettle();

        expect(currentContent, isNotNull);
        expect(currentContent?.text, 'target');
      },
    );

    testWidgets('renderState taps open visible URLs on wrapped rows', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      String? openedUri;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 160,
              child: GhosttyTerminalView(
                controller: controller,
                autofocus: true,
                showHeader: false,
                renderer: GhosttyTerminalRendererMode.renderState,
                onOpenHyperlink: (uri) async {
                  openedUri = uri;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      controller.appendDebugOutput(
        '${'a' * (controller.cols - 1)} https://example.com/docs',
      );
      await tester.pumpAndSettle();

      const target = Offset(30, 43);
      await tester.tapAt(target);
      await tester.pumpAndSettle();

      expect(openedUri, 'https://example.com/docs');
    });

    testWidgets(
      'renderState double click selects wrapped URLs across visible rows',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 120,
                height: 160,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                  showHeader: false,
                  renderer: GhosttyTerminalRendererMode.renderState,
                  onSelectionContentChanged: (content) =>
                      currentContent = content,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        controller.appendDebugOutput(
          '${'a' * (controller.cols - 1)} https://example.com/docs',
        );
        await tester.pumpAndSettle();

        const target = Offset(30, 43);
        await tester.tapAt(target);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(target);
        await tester.pumpAndSettle();

        expect(currentContent, isNotNull);
        expect(currentContent?.text, 'https://example.com/docs');
      },
    );

    testWidgets(
      'renderState triple click selects the full wrapped logical line',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 120,
                height: 160,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                  showHeader: false,
                  renderer: GhosttyTerminalRendererMode.renderState,
                  copyOptions: const GhosttyTerminalCopyOptions(
                    joinWrappedLines: true,
                  ),
                  onSelectionContentChanged: (content) =>
                      currentContent = content,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final wrappedLine = '${'a' * (controller.cols - 1)} target';
        controller.appendDebugOutput(wrappedLine);
        await tester.pumpAndSettle();

        const target = Offset(30, 43);
        await tester.tapAt(target);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(target);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(target);
        await tester.pumpAndSettle();

        expect(currentContent, isNotNull);
        expect(currentContent?.text, wrappedLine);
      },
    );

    testWidgets('triple click selects the whole line', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelection? currentSelection;
      controller.appendDebugOutput('hello world\r\nsecond line');

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          autofocus: true,
          onSelectionChanged: (selection) => currentSelection = selection,
        ),
      );
      await tester.pumpAndSettle();

      const target = Offset(30, 24);
      await tester.tapAt(target);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(target);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(target);
      await tester.pumpAndSettle();

      expect(currentSelection, isNotNull);
      expect(
        controller.snapshot.textForSelection(currentSelection!),
        'hello world',
      );
    });

    testWidgets('double click drag expands selection by words', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelection? currentSelection;
      controller.appendDebugOutput('hello brave world');

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          autofocus: true,
          onSelectionChanged: (selection) => currentSelection = selection,
        ),
      );
      await tester.pumpAndSettle();

      const start = Offset(30, 24);
      const end = Offset(110, 24);

      await tester.tapAt(start);
      await tester.pump(const Duration(milliseconds: 40));

      final gesture = await _startMouseGesture(tester, start);
      await tester.pump(const Duration(milliseconds: 40));
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(currentSelection, isNotNull);
      expect(
        controller.snapshot.textForSelection(currentSelection!),
        'hello brave world',
      );
    });

    testWidgets(
      'double click drag keeps word granularity across multiple moves',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        GhosttyTerminalSelection? currentSelection;
        controller.appendDebugOutput('hello brave new world');

        await tester.pumpWidget(
          buildView(
            showHeader: false,
            autofocus: true,
            onSelectionChanged: (selection) => currentSelection = selection,
          ),
        );
        await tester.pumpAndSettle();

        const start = Offset(30, 24);
        const middle = Offset(84, 24);
        const end = Offset(142, 24);

        await tester.tapAt(start);
        await tester.pump(const Duration(milliseconds: 40));

        final gesture = await _startMouseGesture(tester, start);
        await tester.pump(const Duration(milliseconds: 40));
        await gesture.moveTo(middle);
        await tester.pump();
        await gesture.moveTo(end);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(currentSelection, isNotNull);
        expect(
          controller.snapshot.textForSelection(currentSelection!),
          'hello brave new world',
        );
      },
    );

    testWidgets('triple click drag expands selection by lines', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelection? currentSelection;
      controller.appendDebugOutput('hello world\r\nsecond line\r\nthird line');

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          autofocus: true,
          onSelectionChanged: (selection) => currentSelection = selection,
        ),
      );
      await tester.pumpAndSettle();

      const start = Offset(30, 24);
      const end = Offset(30, 44);

      await tester.tapAt(start);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(start);
      await tester.pump(const Duration(milliseconds: 40));

      final gesture = await _startMouseGesture(tester, start);
      await tester.pump(const Duration(milliseconds: 40));
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(currentSelection, isNotNull);
      expect(
        controller.snapshot.textForSelection(currentSelection!),
        'hello world\nsecond line',
      );
    });

    testWidgets(
      'triple click drag keeps line granularity across multiple moves',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        GhosttyTerminalSelection? currentSelection;
        controller.appendDebugOutput(
          'hello world\r\nsecond line\r\nthird line\r\nfourth line',
        );

        await tester.pumpWidget(
          buildView(
            showHeader: false,
            autofocus: true,
            onSelectionChanged: (selection) => currentSelection = selection,
          ),
        );
        await tester.pumpAndSettle();

        const start = Offset(30, 24);
        const middle = Offset(30, 44);
        const end = Offset(30, 64);

        await tester.tapAt(start);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(start);
        await tester.pump(const Duration(milliseconds: 40));

        final gesture = await _startMouseGesture(tester, start);
        await tester.pump(const Duration(milliseconds: 40));
        await gesture.moveTo(middle);
        await tester.pump();
        await gesture.moveTo(end);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(currentSelection, isNotNull);
        expect(
          controller.snapshot.textForSelection(currentSelection!),
          'hello world\nsecond line\nthird line',
        );
      },
    );

    testWidgets('shift click extends the existing selection', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelection? currentSelection;
      controller.appendDebugOutput('hello world');

      await tester.pumpWidget(
        buildView(
          showHeader: false,
          autofocus: true,
          onSelectionChanged: (selection) => currentSelection = selection,
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await _startMouseGesture(tester, const Offset(30, 24));
      await tester.pump();
      await gesture.moveTo(const Offset(50, 24));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(currentSelection, isNotNull);
      expect(controller.snapshot.textForSelection(currentSelection!), 'hell');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.tapAt(const Offset(78, 24));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(currentSelection, isNotNull);
      expect(
        controller.snapshot.textForSelection(currentSelection!),
        'hello world',
      );
    });
  });

  group('GhosttyTerminalSnapshot', () {
    test('word selection respects custom boundary policy', () {
      const snapshot = GhosttyTerminalSnapshot(
        lines: <GhosttyTerminalLine>[
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'alpha-beta gamma', cells: 16),
          ]),
        ],
        cursor: GhosttyTerminalCursor(row: 0, col: 0),
      );

      final defaultSelection = snapshot.wordSelectionAt(
        const GhosttyTerminalCellPosition(row: 0, col: 5),
      );
      final strictSelection = snapshot.wordSelectionAt(
        const GhosttyTerminalCellPosition(row: 0, col: 5),
        policy: const GhosttyTerminalWordBoundaryPolicy(
          extraWordCharacters: '._/~:@%#?&=+',
        ),
      );

      expect(snapshot.textForSelection(defaultSelection!), 'alpha-beta');
      expect(snapshot.textForSelection(strictSelection!), '-');
    });

    test('line selection and copy options are exposed from the snapshot', () {
      const snapshot = GhosttyTerminalSnapshot(
        lines: <GhosttyTerminalLine>[
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'hello  ', cells: 7),
          ]),
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'second', cells: 6),
          ]),
        ],
        cursor: GhosttyTerminalCursor(row: 1, col: 6),
      );

      final selection = snapshot.lineSelectionBetweenRows(0, 1);
      expect(selection, isNotNull);
      expect(snapshot.textForSelection(selection!), 'hello\nsecond');
      expect(
        snapshot.textForSelection(
          selection,
          options: const GhosttyTerminalCopyOptions(trimTrailingSpaces: false),
        ),
        'hello  \nsecond',
      );
      expect(snapshot.selectAllSelection(), selection);
    });

    test('wrapped line copy options join soft-wrapped rows', () {
      const snapshot = GhosttyTerminalSnapshot(
        lines: <GhosttyTerminalLine>[
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'hello', cells: 5),
          ], wrap: true),
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'world', cells: 5),
          ], wrapContinuation: true),
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'tail', cells: 4),
          ]),
        ],
      );

      final selection = snapshot.lineSelectionBetweenRows(0, 2);
      expect(selection, isNotNull);
      expect(snapshot.textForSelection(selection!), 'hello\nworld\ntail');
      expect(
        snapshot.textForSelection(
          selection,
          options: const GhosttyTerminalCopyOptions(joinWrappedLines: true),
        ),
        'helloworld\ntail',
      );
      expect(
        snapshot.textForSelection(
          selection,
          options: const GhosttyTerminalCopyOptions(
            joinWrappedLines: true,
            wrappedLineJoiner: ' ',
          ),
        ),
        'hello world\ntail',
      );
    });

    test(
      'trailing blank cells do not resolve as the last word or hyperlink',
      () {
        const snapshot = GhosttyTerminalSnapshot(
          lines: <GhosttyTerminalLine>[
            GhosttyTerminalLine(<GhosttyTerminalRun>[
              GhosttyTerminalRun(text: 'see https://example.com', cells: 23),
            ]),
          ],
        );

        const trailingBlank = GhosttyTerminalCellPosition(row: 0, col: 30);
        expect(snapshot.hyperlinkAt(trailingBlank), isNull);
        expect(snapshot.wordSelectionAt(trailingBlank), isNull);
      },
    );

    test('wide-tail columns do not break snapshot word selection', () {
      const snapshot = GhosttyTerminalSnapshot(
        lines: <GhosttyTerminalLine>[
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: '界', cells: 2),
            GhosttyTerminalRun(text: ' next', cells: 5),
          ]),
        ],
      );

      final selection = snapshot.wordSelectionAt(
        const GhosttyTerminalCellPosition(row: 0, col: 1),
      );

      expect(selection, isNotNull);
      expect(snapshot.textForSelection(selection!), '界');
    });

    testWidgets('renderState selection content joins wrapped visible rows', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller = GhosttyTerminalController();
      addTearDown(controller.dispose);
      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 160,
              child: GhosttyTerminalView(
                controller: controller,
                autofocus: true,
                showHeader: false,
                renderer: GhosttyTerminalRendererMode.renderState,
                copyOptions: const GhosttyTerminalCopyOptions(
                  joinWrappedLines: true,
                ),
                onSelectionContentChanged: (content) =>
                    currentContent = content,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      controller.appendDebugOutput('abcdefghijklmnopqrstuvwxyz');
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(currentContent, isNotNull);
      expect(currentContent?.text, 'abcdefghijklmnopqrstuvwxyz');
    });
  });

  group('GhosttyTerminalView keyboard handling', () {
    late GhosttyTerminalController controller;

    setUp(() {
      controller = GhosttyTerminalController();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('ignores key events when process not running', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                autofocus: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(find.byType(GhosttyTerminalView), findsOneWidget);
    });

    testWidgets('key up events are ignored', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                autofocus: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(find.byType(GhosttyTerminalView), findsOneWidget);
    });

    testWidgets('backspace is sent without printable text payload', (
      tester,
    ) async {
      final controller = _RecordingTerminalController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                autofocus: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(controller.lastKey, GhosttyKey.GHOSTTY_KEY_BACKSPACE);
      expect(controller.lastAction, GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS);
      expect(controller.lastUtf8Text, isEmpty);
      expect(controller.lastUnshiftedCodepoint, 0);
    });

    testWidgets(
      'pointer interaction does not forward mouse events by default',
      (tester) async {
        final controller = _RecordingTerminalController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.startGesture(const Offset(100, 100));
        await tester.pump();
        await gesture.moveTo(const Offset(140, 120));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.mouseEvents, isEmpty);
      },
    );

    testWidgets('touch drag scrolls transcript without selecting text', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      GhosttyTerminalSelection? currentSelection;
      controller.appendDebugOutput(
        List<String>.generate(160, (index) => 'Line $index').join('\r\n'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                showHeader: false,
                scrollController: scrollController,
                onSelectionChanged: (selection) => currentSelection = selection,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(
        kind: ui.PointerDeviceKind.touch,
      );
      await gesture.down(const Offset(300, 320));
      await tester.pump();
      await gesture.moveTo(const Offset(300, 80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(scrollController.offset, greaterThan(0));
      expect(currentSelection, isNull);
    });

    testWidgets('touch long press starts terminal selection', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;
      controller.appendDebugOutput('hello world\r\nsecond line');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                showHeader: false,
                onSelectionContentChanged: (content) =>
                    currentContent = content,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPressAt(const Offset(30, 24));
      await tester.pumpAndSettle();

      expect(currentContent?.text, startsWith('hello world'));
    });

    testWidgets('touch selection shows an adaptive context menu', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      String? copiedText;
      controller.appendDebugOutput('hello world\r\nsecond line');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                showHeader: false,
                onCopySelection: (text) async {
                  copiedText = text;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPressAt(const Offset(30, 24));
      await tester.pumpAndSettle();

      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(copiedText, 'hello world');
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    });

    testWidgets('touch selection context menu supports custom actions', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      String? actionText;
      GhosttyTerminalSelection? actionSelection;
      controller.appendDebugOutput('hello world\r\nsecond line');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                showHeader: false,
                selectionContextMenuButtonItemsBuilder: (details) {
                  return <ContextMenuButtonItem>[
                    ...details.defaultButtonItems,
                    ContextMenuButtonItem(
                      label: 'Explain',
                      onPressed: () {
                        actionText = details.selectedText;
                        actionSelection = details.selection;
                        details.hideToolbar();
                      },
                    ),
                  ];
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPressAt(const Offset(30, 24));
      await tester.pumpAndSettle();

      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      expect(find.text('Explain'), findsOneWidget);

      await tester.tap(find.text('Explain'));
      await tester.pumpAndSettle();

      expect(actionText, 'hello world');
      expect(actionSelection, isNotNull);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    });

    testWidgets('controller swap clears touch selection state', (tester) async {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller2 = GhosttyTerminalController();
      addTearDown(controller2.dispose);
      final selectionChanges = <GhosttyTerminalSelection?>[];

      controller.appendDebugOutput('hello world\r\nsecond line');
      controller2.appendDebugOutput('replacement controller');

      Widget buildControllerView(GhosttyTerminalController terminalController) {
        return MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: terminalController,
                showHeader: false,
                onSelectionChanged: selectionChanges.add,
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildControllerView(controller));
      await tester.pumpAndSettle();

      await tester.longPressAt(const Offset(30, 24));
      await tester.pumpAndSettle();

      expect(selectionChanges, isNotEmpty);
      expect(selectionChanges.last, isNotNull);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

      await tester.pumpWidget(buildControllerView(controller2));
      await tester.pumpAndSettle();

      expect(selectionChanges.last, isNull);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    });

    testWidgets('touch selection handles can extend the highlight', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;
      controller.appendDebugOutput('alpha beta\r\nsecond line\r\nthird line');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                showHeader: false,
                onSelectionContentChanged: (content) {
                  currentContent = content;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPressAt(const Offset(30, 44));
      await tester.pumpAndSettle();

      expect(currentContent?.text, 'second line');
      final endHandle = find.byKey(
        const ValueKey<String>('ghostty-terminal-selection-end-handle'),
      );
      expect(endHandle, findsOneWidget);

      final gesture = await tester.createGesture(
        kind: ui.PointerDeviceKind.touch,
      );
      await gesture.down(tester.getCenter(endHandle));
      await tester.pump();
      await gesture.moveTo(const Offset(112, 80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(currentContent?.text, contains('second line'));
      expect(currentContent?.text, contains('third'));
      expect(
        find.byKey(
          const ValueKey<String>('ghostty-terminal-selection-start-handle'),
        ),
        findsOneWidget,
      );
      expect(endHandle, findsOneWidget);
    });

    testWidgets('touch selection handles auto-pan near the viewport edge', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      GhosttyTerminalSelectionContent<GhosttyTerminalSelection>? currentContent;
      controller.appendDebugOutput(
        List<String>.generate(180, (index) => 'Line $index').join('\r\n'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                showHeader: false,
                onSelectionContentChanged: (content) {
                  currentContent = content;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPressAt(const Offset(30, 382));
      await tester.pumpAndSettle();

      expect(currentContent?.text, 'Line 179');
      final startHandle = find.byKey(
        const ValueKey<String>('ghostty-terminal-selection-start-handle'),
      );
      expect(startHandle, findsOneWidget);

      final gesture = await tester.createGesture(
        kind: ui.PointerDeviceKind.touch,
      );
      await gesture.down(tester.getCenter(startHandle));
      await tester.pump();
      await gesture.moveTo(const Offset(40, 14));
      await tester.pump();
      final textBeforeAutoPan = currentContent?.text;

      await tester.pump(const Duration(milliseconds: 300));

      final beforeLines = textBeforeAutoPan?.split('\n') ?? const <String>[];
      final afterLines = currentContent?.text.split('\n') ?? const <String>[];
      expect(currentContent?.text, isNot(textBeforeAutoPan));
      expect(currentContent?.text, contains('Line 179'));
      expect(afterLines.length, greaterThan(beforeLines.length));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets(
      'touch long press at live bottom does not expand to the viewport',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        var selectionChanges = 0;
        GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
        currentContent;

        controller.appendDebugOutput(
          List<String>.generate(160, (index) => 'Line $index').join('\r\n'),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  showHeader: false,
                  scrollController: scrollController,
                  onSelectionChanged: (_) {
                    selectionChanges++;
                  },
                  onSelectionContentChanged: (content) {
                    currentContent = content;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(scrollController.offset, 0);

        final gesture = await tester.createGesture(
          kind: ui.PointerDeviceKind.touch,
        );
        await gesture.down(const Offset(30, 382));
        await tester.pump(const Duration(milliseconds: 650));

        expect(currentContent?.text, 'Line 159');
        final changesAfterLongPress = selectionChanges;

        await tester.pump(const Duration(milliseconds: 300));

        expect(scrollController.offset, 0);
        expect(currentContent?.text, 'Line 159');
        expect(selectionChanges, changesAfterLongPress);

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'touch input in auto mode does not forward terminal mouse events',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final controller = _RecordingTerminalController();
        addTearDown(controller.dispose);
        controller.terminal.setMode(VtModes.normalMouse, true);
        controller.terminal.setMode(VtModes.sgrMouse, true);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.createGesture(
          kind: ui.PointerDeviceKind.touch,
        );
        await gesture.down(const Offset(100, 100));
        await tester.pump();
        await gesture.moveTo(const Offset(140, 120));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.mouseEvents, isEmpty);
      },
    );

    testWidgets(
      'pointer interaction forwards Ghostty mouse events when reporting is enabled',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final controller = _RecordingTerminalController();
        addTearDown(controller.dispose);
        controller.appendDebugOutput('hello world');
        controller.terminal.setMode(VtModes.normalMouse, true);
        controller.terminal.setMode(VtModes.sgrMouse, true);

        GhosttyTerminalSelection? currentSelection;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                  onSelectionChanged: (selection) {
                    currentSelection = selection;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await _startMouseGesture(
          tester,
          const Offset(100, 100),
        );
        await tester.pump();
        await gesture.moveTo(const Offset(140, 120));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.mouseEvents, isNotEmpty);
        expect(
          controller.mouseEvents.map((event) => event.action),
          contains(GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS),
        );
        expect(
          controller.mouseEvents.map((event) => event.action),
          contains(GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION),
        );
        expect(
          controller.mouseEvents.map((event) => event.action),
          contains(GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE),
        );
        expect(controller.mouseEvents.first.size.screenWidth, greaterThan(0));
        expect(
          controller.mouseEvents.first.button,
          GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
        );
        expect(currentSelection, isNull);
      },
    );

    testWidgets(
      'scroll wheel forwards Ghostty mouse buttons four and five when reporting is enabled',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final controller = _RecordingTerminalController();
        addTearDown(controller.dispose);
        controller.terminal.setMode(VtModes.normalMouse, true);
        controller.terminal.setMode(VtModes.sgrMouse, true);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(const Offset(120, 120)));
        await tester.pump();

        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -32)));
        await tester.pump();

        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 32)));
        await tester.pump();

        final pressEvents = controller.mouseEvents
            .where(
              (event) =>
                  event.action == GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
            )
            .toList(growable: false);
        final releaseEvents = controller.mouseEvents
            .where(
              (event) =>
                  event.action ==
                  GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
            )
            .toList(growable: false);

        expect(pressEvents, hasLength(2));
        expect(releaseEvents, hasLength(2));
        expect(pressEvents.map((event) => event.button), <GhosttyMouseButton?>[
          GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FOUR,
          GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FIVE,
        ]);
        expect(
          releaseEvents.map((event) => event.button),
          <GhosttyMouseButton?>[
            GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FOUR,
            GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FIVE,
          ],
        );
      },
    );

    testWidgets(
      'selectionFirst policy keeps selection active even when terminal mouse reporting is enabled',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final controller = _RecordingTerminalController();
        addTearDown(controller.dispose);
        controller.appendDebugOutput('hello world');
        controller.terminal.setMode(VtModes.normalMouse, true);
        controller.terminal.setMode(VtModes.sgrMouse, true);

        GhosttyTerminalSelection? currentSelection;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                  interactionPolicy:
                      GhosttyTerminalInteractionPolicy.selectionFirst,
                  onSelectionChanged: (selection) {
                    currentSelection = selection;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await _startMouseGesture(
          tester,
          const Offset(100, 100),
        );
        await tester.pump();
        await gesture.moveTo(const Offset(180, 100));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.mouseEvents, isEmpty);
        expect(currentSelection, isNotNull);
      },
    );

    testWidgets(
      'terminalMouseFirst policy forwards touch as terminal mouse events',
      (tester) async {
        final controller = _RecordingTerminalController();
        addTearDown(controller.dispose);

        GhosttyTerminalSelection? currentSelection;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                  interactionPolicy:
                      GhosttyTerminalInteractionPolicy.terminalMouseFirst,
                  onSelectionChanged: (selection) {
                    currentSelection = selection;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.startGesture(const Offset(100, 100));
        await tester.pump();
        await gesture.moveTo(const Offset(140, 120));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.mouseEvents, isNotEmpty);
        expect(
          controller.mouseEvents.first.button,
          GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
        );
        expect(currentSelection, isNull);
      },
    );

    testWidgets(
      'terminalMouseFirst policy releases terminal mouse on touch cancel',
      (tester) async {
        final controller = _RecordingTerminalController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                  interactionPolicy:
                      GhosttyTerminalInteractionPolicy.terminalMouseFirst,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.createGesture(
          kind: ui.PointerDeviceKind.touch,
        );
        await gesture.down(const Offset(100, 100));
        await tester.pump();
        await gesture.cancel();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          controller.mouseEvents.map((event) => event.action),
          containsAllInOrder(<GhosttyMouseAction>[
            GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
            GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
          ]),
        );
      },
    );

    testWidgets('shifted underscore and plus are written as printable text', (
      tester,
    ) async {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller = _InteractiveEchoTerminalController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: GhosttyTerminalView(
                controller: controller,
                autofocus: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(
        LogicalKeyboardKey.minus,
        physicalKey: PhysicalKeyboardKey.minus,
      );
      await tester.sendKeyEvent(
        LogicalKeyboardKey.equal,
        physicalKey: PhysicalKeyboardKey.equal,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(controller.snapshot.lines.single.text, 'abc_+');
      expect(
        controller.snapshot.cursor,
        const GhosttyTerminalCursor(row: 0, col: 5),
      );
    });

    testWidgets(
      'backspace in the terminal area erases and the next key overwrites it',
      (tester) async {
        if (!_hasNativeTerminal) {
          return;
        }

        final controller = _InteractiveEchoTerminalController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 400,
                child: GhosttyTerminalView(
                  controller: controller,
                  autofocus: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();

        expect(
          controller.snapshot.cursor,
          const GhosttyTerminalCursor(row: 0, col: 2),
        );
        expect(controller.snapshot.lines.single.text, 'ab ');

        await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
        await tester.pump();

        expect(
          controller.snapshot.cursor,
          const GhosttyTerminalCursor(row: 0, col: 3),
        );
        expect(controller.snapshot.lines.single.text, 'abd');
      },
    );
  });

  group('GhosttyTerminalController', () {
    late GhosttyTerminalController controller;

    setUp(() {
      controller = GhosttyTerminalController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('initial state', () {
      expect(controller.title, 'Terminal');
      expect(controller.isRunning, isFalse);
      expect(controller.lines, ['']);
      expect(controller.lineCount, 1);
      expect(controller.revision, 0);
      expect(controller.cols, 80);
      expect(controller.rows, 24);
    });

    test('appendDebugOutput increments revision and creates VT state', () {
      if (!_hasNativeTerminal) {
        return;
      }

      expect(controller.revision, 0);
      controller.appendDebugOutput('hello');
      expect(controller.revision, 1);
      expect(controller.terminal.cols, 80);
      expect(controller.terminal.rows, 24);
    });

    test('line feed preserves the current column in VT mode', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('a\nb\nc');

      expect(controller.lines, ['a', ' b', '  c']);
      expect(controller.plainText, 'a\n b\n  c');
    });

    test('carriage return overwrites the current line', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('hello\rworld');

      expect(controller.lines, ['world']);
    });

    test('backspace moves the cursor left without truncating the tail', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('abc\b\bd');

      expect(controller.lines, ['adc']);
    });

    test('shell erase echo clears the cell and leaves the cursor there', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('abc\b \b');

      expect(controller.lines, ['ab']);
      expect(
        controller.snapshot.cursor,
        const GhosttyTerminalCursor(row: 0, col: 2),
      );
    });

    test('clear resets lines', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('some\r\ntext');
      expect(controller.lineCount, 2);

      controller.clear();
      expect(controller.lines, ['']);
      expect(controller.lineCount, 1);
    });

    test('resize updates the live terminal grid', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.resize(cols: 132, rows: 40);

      expect(controller.cols, 132);
      expect(controller.rows, 40);
      expect(controller.terminal.cols, 132);
      expect(controller.terminal.rows, 40);
    });

    test('OSC title commands are parsed', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('\x1b]0;My Title\x07');
      expect(controller.title, 'My Title');

      controller.appendDebugOutput('\x1b]2;Another Title\x07');
      expect(controller.title, 'Another Title');

      controller.appendDebugOutput('\x1b]0;ST Title\x1b\\');
      expect(controller.title, 'ST Title');
    });

    test('plain formatting strips CSI while VT formatting preserves it', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('\x1b[31;1mred bold\x1b[0m normal');

      expect(controller.lines.single, 'red bold normal');
      final vtOutput = controller.formatTerminal(
        emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
        trim: false,
      );
      expect(vtOutput, contains('red bold'));
      expect(vtOutput, contains('\x1b['));
    });

    test('styled snapshot keeps ANSI colors, emphasis, and cursor info', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput(
        '\x1b[31;1mred\x1b[0m normal\r\nplain \x1b[4;34mblue\x1b[0m',
      );

      final snapshot = controller.snapshot;
      expect(snapshot.cursor, isNotNull);
      expect(snapshot.lines, hasLength(2));

      final firstLine = snapshot.lines[0].runs;
      expect(firstLine[0].text, 'red');
      expect(firstLine[0].style.bold, isTrue);
      expect(
        firstLine[0].style.foreground,
        const GhosttyTerminalColor.palette(1),
      );
      expect(firstLine[1].text, ' normal');

      final secondLine = snapshot.lines[1].runs;
      expect(secondLine[0].text, 'plain ');
      expect(secondLine[1].text, 'blue');
      expect(secondLine[1].style.underline, isNotNull);
      expect(
        secondLine[1].style.foreground,
        const GhosttyTerminalColor.palette(4),
      );
    });

    test('snapshot selection extracts multi-line text ranges', () {
      if (!_hasNativeTerminal) {
        return;
      }

      controller.appendDebugOutput('alpha\r\nbravo\r\ncharlie');

      final text = controller.snapshot.textForSelection(
        const GhosttyTerminalSelection(
          base: GhosttyTerminalCellPosition(row: 0, col: 2),
          extent: GhosttyTerminalCellPosition(row: 1, col: 2),
        ),
      );

      expect(text, 'pha\nbra');
    });

    test(
      'snapshot hyperlink lookup and word selection detect visible URLs',
      () {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('see https://example.com/docs now');

        final snapshot = controller.snapshot;
        expect(
          snapshot.hyperlinkAt(
            const GhosttyTerminalCellPosition(row: 0, col: 8),
          ),
          'https://example.com/docs',
        );

        final selection = snapshot.wordSelectionAt(
          const GhosttyTerminalCellPosition(row: 0, col: 12),
        );
        expect(selection, isNotNull);
        expect(
          snapshot.textForSelection(selection!),
          'https://example.com/docs',
        );
      },
    );

    test('maxLines truncates old lines from formatted snapshots', () {
      if (!_hasNativeTerminal) {
        return;
      }

      final small = GhosttyTerminalController(maxLines: 5);
      addTearDown(small.dispose);

      small.appendDebugOutput('1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8');
      expect(small.lineCount, 5);
      expect(small.lines.first, '4');
      expect(small.lines.last, '8');
    });

    test('notifyListeners called on appendDebugOutput and clear', () {
      if (!_hasNativeTerminal) {
        return;
      }

      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.appendDebugOutput('test');
      controller.clear();

      expect(notifications, 2);
    });

    test('write, writeBytes, and sendKey return false when not running', () {
      expect(controller.write('hello'), isFalse);
      expect(controller.writeBytes([0x68, 0x69]), isFalse);
      expect(controller.sendKey(key: GhosttyKey.GHOSTTY_KEY_ENTER), isFalse);
    });

    test(
      'carriage return plus line feed starts the next line at column zero',
      () {
        if (!_hasNativeTerminal) {
          return;
        }

        controller.appendDebugOutput('hello\r\nworld');

        expect(controller.lines, ['hello', 'world']);
      },
    );

    test('interactive shell backspace rewrites the prompt line', () async {
      if (!_hasNativeTerminal) {
        return;
      }

      if (!(Platform.isLinux || Platform.isMacOS)) {
        return;
      }

      final shellController = GhosttyTerminalController(
        defaultShell: '/bin/bash',
      );
      addTearDown(shellController.dispose);

      await shellController.start(
        shell: '/bin/bash',
        arguments: const <String>['--noprofile', '--norc', '-i'],
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(shellController.write("PS1='> '\n"), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(shellController.write('abc'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        shellController.sendKey(key: GhosttyKey.GHOSTTY_KEY_BACKSPACE),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(shellController.write('d'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(_lastNonEmptyLine(shellController.lines), endsWith('abd'));
    });

    test('interactive clean zsh handles arrow editing and backspace', () async {
      if (!_hasNativeTerminal) {
        return;
      }

      if (!(Platform.isLinux || Platform.isMacOS)) {
        return;
      }

      final shellController = GhosttyTerminalController(defaultShell: 'zsh');
      addTearDown(shellController.dispose);

      try {
        await shellController.start(
          shell: 'zsh',
          arguments: const <String>['-f', '-i'],
        );
      } on ProcessException {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        shellController.write(
          "PROMPT='%# '\n"
          "RPROMPT=\n"
          "unsetopt TRANSIENT_RPROMPT\n",
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(shellController.write('ac'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        shellController.sendKey(key: GhosttyKey.GHOSTTY_KEY_ARROW_LEFT),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(shellController.write('b'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        shellController.sendKey(key: GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        shellController.sendKey(key: GhosttyKey.GHOSTTY_KEY_BACKSPACE),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(shellController.write('c'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(_lastNonEmptyLine(shellController.lines), endsWith('abc'));
    });

    test('interactive clean zsh handles editing with a right prompt', () async {
      if (!_hasNativeTerminal) {
        return;
      }

      if (!(Platform.isLinux || Platform.isMacOS)) {
        return;
      }

      final shellController = GhosttyTerminalController(defaultShell: 'zsh');
      addTearDown(shellController.dispose);

      try {
        await shellController.start(
          shell: 'zsh',
          arguments: const <String>['-f', '-i'],
        );
      } on ProcessException {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        shellController.write(
          "PROMPT='%# '\n"
          "RPROMPT='R'\n"
          "unsetopt TRANSIENT_RPROMPT\n",
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(shellController.write('ac'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        shellController.sendKey(key: GhosttyKey.GHOSTTY_KEY_ARROW_LEFT),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(shellController.write('b'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        shellController.sendKey(key: GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        shellController.sendKey(key: GhosttyKey.GHOSTTY_KEY_BACKSPACE),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(shellController.write('c'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 180));

      final line = _lastNonEmptyLine(shellController.lines);
      expect(line, contains('% abc'));
    });
  });

  group('decodeHexBytes', () {
    test('empty string returns empty bytes', () {
      expect(decodeHexBytes(''), isEmpty);
    });

    test('whitespace only returns empty bytes', () {
      expect(decodeHexBytes('   '), isEmpty);
    });

    test('single byte', () {
      expect(decodeHexBytes('1b'), [0x1b]);
    });

    test('multiple bytes', () {
      expect(decodeHexBytes('1b 5b 41'), [0x1b, 0x5b, 0x41]);
    });

    test('handles extra whitespace', () {
      expect(decodeHexBytes('  0a   0d  '), [0x0a, 0x0d]);
    });
  });
}

Future<TestGesture> _startMouseGesture(
  WidgetTester tester,
  Offset offset,
) async {
  final gesture = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
  await gesture.down(offset);
  return gesture;
}

class _RecordingTerminalController extends GhosttyTerminalController {
  GhosttyKey? lastKey;
  GhosttyKeyAction? lastAction;
  String lastUtf8Text = '';
  int lastUnshiftedCodepoint = 0;
  final List<_RecordedMouseEvent> mouseEvents = <_RecordedMouseEvent>[];

  @override
  bool sendKey({
    required GhosttyKey key,
    GhosttyKeyAction action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
    int mods = 0,
    int consumedMods = 0,
    bool composing = false,
    String utf8Text = '',
    int unshiftedCodepoint = 0,
  }) {
    lastKey = key;
    lastAction = action;
    lastUtf8Text = utf8Text;
    lastUnshiftedCodepoint = unshiftedCodepoint;
    return true;
  }

  @override
  bool sendMouse({
    required GhosttyMouseAction action,
    GhosttyMouseButton? button,
    int mods = 0,
    required VtMousePosition position,
    required VtMouseEncoderSize size,
    GhosttyMouseTrackingMode? trackingMode,
    GhosttyMouseFormat? format,
    bool? anyButtonPressed,
    bool? trackLastCell,
  }) {
    mouseEvents.add(
      _RecordedMouseEvent(
        action: action,
        button: button,
        position: position,
        size: size,
        mods: mods,
      ),
    );
    return true;
  }
}

class _RecordedMouseEvent {
  const _RecordedMouseEvent({
    required this.action,
    required this.button,
    required this.position,
    required this.size,
    required this.mods,
  });

  final GhosttyMouseAction action;
  final GhosttyMouseButton? button;
  final VtMousePosition position;
  final VtMouseEncoderSize size;
  final int mods;
}

class _InteractiveEchoTerminalController extends GhosttyTerminalController {
  _InteractiveEchoTerminalController() : super() {
    appendDebugOutput('abc');
  }

  @override
  bool sendKey({
    required GhosttyKey key,
    GhosttyKeyAction action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
    int mods = 0,
    int consumedMods = 0,
    bool composing = false,
    String utf8Text = '',
    int unshiftedCodepoint = 0,
  }) {
    if (action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS &&
        key == GhosttyKey.GHOSTTY_KEY_BACKSPACE) {
      appendDebugOutput('\b \b');
      return true;
    }
    return false;
  }

  @override
  bool write(String text, {bool sanitizePaste = false}) {
    appendDebugOutput(text);
    return true;
  }
}

List<int> decodeHexBytes(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const <int>[];
  }
  return trimmed
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map((part) => int.parse(part, radix: 16))
      .toList(growable: false);
}

String _lastNonEmptyLine(List<String> lines) {
  return lines
      .lastWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => lines.isEmpty ? '' : lines.last,
      )
      .trimRight();
}

Future<_TerminalPaintStats> _captureTerminalPaintStats(GlobalKey key) async {
  final image = await _captureTerminalImageData(key);
  return _measureTerminalPaintStats(image.rgba);
}

Future<_TerminalImageData> _captureTerminalImageData(GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return _TerminalImageData(
      width: image.width,
      height: image.height,
      rgba: byteData!.buffer.asUint8List(),
    );
  } finally {
    image.dispose();
  }
}

Future<_TerminalPaintStats> _captureModePaintStats(
  WidgetTester tester, {
  required Widget Function({
    bool autofocus,
    FocusNode? focusNode,
    Color? backgroundColor,
    Color? foregroundColor,
    double? fontSize,
    double? lineHeight,
    GhosttyTerminalRendererMode renderer,
    GhosttyTerminalCopyOptions copyOptions,
    GhosttyTerminalWordBoundaryPolicy wordBoundaryPolicy,
    EdgeInsets? padding,
    ValueChanged<GhosttyTerminalSelection?>? onSelectionChanged,
    ValueChanged<GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?>?
    onSelectionContentChanged,
    Future<void> Function(String uri)? onOpenHyperlink,
  })
  buildView,
  required GhosttyTerminalRendererMode renderer,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: buildView(
        renderer: renderer,
        backgroundColor: const Color(0xFF0A0F14),
        foregroundColor: const Color(0xFFE6EDF3),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _captureTerminalPaintStats(key);
}

_TerminalPaintStats _measureTerminalPaintStats(Uint8List rgba) {
  const backgroundR = 0x0A;
  const backgroundG = 0x0F;
  const backgroundB = 0x14;

  var nonBackgroundPixels = 0;
  var redPixels = 0;
  var greenPixels = 0;
  var bluePixels = 0;
  for (var index = 0; index + 3 < rgba.length; index += 4) {
    final r = rgba[index];
    final g = rgba[index + 1];
    final b = rgba[index + 2];
    final a = rgba[index + 3];
    if (a == 0) {
      continue;
    }
    final dr = (r - backgroundR).abs();
    final dg = (g - backgroundG).abs();
    final db = (b - backgroundB).abs();
    if (dr > 10 || dg > 10 || db > 10) {
      nonBackgroundPixels++;
    }
    if (r > 150 && r > g + 20 && r > b + 20) {
      redPixels++;
    }
    if (g > 120 && g > r + 10 && g > b + 10) {
      greenPixels++;
    }
    if (b > 120 && b > r + 10 && b > g + 10) {
      bluePixels++;
    }
  }
  return _TerminalPaintStats(
    nonBackgroundPixels: nonBackgroundPixels,
    redPixels: redPixels,
    greenPixels: greenPixels,
    bluePixels: bluePixels,
  );
}

final class _TerminalPaintStats {
  const _TerminalPaintStats({
    required this.nonBackgroundPixels,
    required this.redPixels,
    required this.greenPixels,
    required this.bluePixels,
  });

  final int nonBackgroundPixels;
  final int redPixels;
  final int greenPixels;
  final int bluePixels;
}

final class _TerminalImageData {
  const _TerminalImageData({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

bool _pixelIsNonBackground(
  _TerminalImageData image, {
  required int x,
  required int y,
}) {
  if (x < 0 || x >= image.width || y < 0 || y >= image.height) {
    return false;
  }

  final index = ((y * image.width) + x) * 4;
  final r = image.rgba[index];
  final g = image.rgba[index + 1];
  final b = image.rgba[index + 2];
  final a = image.rgba[index + 3];
  if (a == 0) {
    return false;
  }

  return (r - 0x0A).abs() > 10 ||
      (g - 0x0F).abs() > 10 ||
      (b - 0x14).abs() > 10;
}

bool _pixelMatchesColor(
  _TerminalImageData image, {
  required int x,
  required int y,
  required Color color,
  int tolerance = 4,
}) {
  if (x < 0 || x >= image.width || y < 0 || y >= image.height) {
    return false;
  }

  final index = ((y * image.width) + x) * 4;
  final r = image.rgba[index];
  final g = image.rgba[index + 1];
  final b = image.rgba[index + 2];
  final a = image.rgba[index + 3];
  if (a == 0) {
    return false;
  }

  return (r - _colorRed8(color)).abs() <= tolerance &&
      (g - _colorGreen8(color)).abs() <= tolerance &&
      (b - _colorBlue8(color)).abs() <= tolerance;
}

int _countPixelsNearColor(
  _TerminalImageData image, {
  required Color color,
  int tolerance = 24,
}) {
  var count = 0;
  for (var index = 0; index + 3 < image.rgba.length; index += 4) {
    final r = image.rgba[index];
    final g = image.rgba[index + 1];
    final b = image.rgba[index + 2];
    final a = image.rgba[index + 3];
    if (a == 0) {
      continue;
    }
    if ((r - _colorRed8(color)).abs() <= tolerance &&
        (g - _colorGreen8(color)).abs() <= tolerance &&
        (b - _colorBlue8(color)).abs() <= tolerance) {
      count++;
    }
  }
  return count;
}

int _colorRed8(Color color) => (color.toARGB32() >> 16) & 0xFF;

int _colorGreen8(Color color) => (color.toARGB32() >> 8) & 0xFF;

int _colorBlue8(Color color) => color.toARGB32() & 0xFF;

int _countNonBackgroundPixelsInHorizontalSpan(
  _TerminalImageData image, {
  required int y,
  required int startX,
  required int endX,
}) {
  var count = 0;
  for (var x = startX; x <= endX; x++) {
    if (_pixelIsNonBackground(image, x: x, y: y)) {
      count++;
    }
  }
  return count;
}

int _countNonBackgroundPixelsInVerticalSpan(
  _TerminalImageData image, {
  required int x,
  required int startY,
  required int endY,
}) {
  var count = 0;
  for (var y = startY; y <= endY; y++) {
    if (_pixelIsNonBackground(image, x: x, y: y)) {
      count++;
    }
  }
  return count;
}
