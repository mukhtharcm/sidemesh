import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Renders a unified-diff string with a Codex-TUI-inspired look:
///
/// - Line numbers (old / new) rendered in a gutter column.
/// - `+` / `-` / ` ` glyph in a mini gutter with contrasting background tints.
/// - GitHub-style green/red row backgrounds (theme-aware via [AppColors]).
/// - File headers (`diff --git`, `---`, `+++`) rendered in muted text.
/// - Hunk headers (`@@ -a,b +c,d @@`) rendered in info blue.
///
/// The widget accepts any patch produced by `git diff`, `diffy`, or Codex's
/// `file_change` activity.  Malformed input degrades gracefully into a plain
/// mono-rendered block.
class DiffView extends StatelessWidget {
  const DiffView({
    super.key,
    required this.diff,
    this.showLineNumbers = true,
    this.maxLines,
  });

  final String diff;

  /// When false, only glyph gutter is shown.
  final bool showLineNumbers;

  /// Optional cap so giant diffs stay compact inside a card.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final parsed = _parseDiff(diff);

    final rows = maxLines == null
        ? parsed
        : parsed.take(maxLines!).toList(growable: false);
    final truncated = maxLines != null && parsed.length > maxLines!;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.codeBorder),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Horizontal scroll so long lines don't wrap. LayoutBuilder +
            // ConstrainedBox(minWidth) ensures each row's background fills
            // at least the full viewport width, so short rows don't have
            // half-painted backgrounds when the user scrolls right.
            LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: constraints.maxWidth,
                    ),
                    child: IntrinsicWidth(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final row in rows)
                            _DiffRow(
                              row: row,
                              showLineNumbers: showLineNumbers,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (truncated)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: colors.surfaceMuted,
                child: Text(
                  '…${parsed.length - maxLines!} more lines',
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.row, required this.showLineNumbers});

  final _DiffLine row;
  final bool showLineNumbers;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    final (lineBg, gutterBg, glyphColor, textColor) = switch (row.kind) {
      _DiffKind.add => (
          colors.diffAddLine,
          colors.diffAddGutter,
          colors.diffAddGlyph,
          colors.textPrimary,
        ),
      _DiffKind.del => (
          colors.diffDelLine,
          colors.diffDelGutter,
          colors.diffDelGlyph,
          colors.textPrimary,
        ),
      _DiffKind.context => (
          colors.codeBackground,
          colors.surfaceMuted,
          colors.diffGutterText,
          colors.textPrimary,
        ),
      _DiffKind.hunk => (
          colors.infoMuted,
          colors.infoMuted,
          colors.diffHunkLine,
          colors.diffHunkLine,
        ),
      _DiffKind.meta => (
          colors.surfaceMuted,
          colors.surfaceMuted,
          colors.diffMetaLine,
          colors.diffMetaLine,
        ),
    };

    final glyph = switch (row.kind) {
      _DiffKind.add => '+',
      _DiffKind.del => '-',
      _DiffKind.context => ' ',
      _DiffKind.hunk => '@',
      _DiffKind.meta => '·',
    };

    final textStyle = monoStyle(color: textColor, fontSize: 12.5, height: 1.5);
    final mutedMono = monoStyle(
      color: colors.diffGutterText,
      fontSize: 11.5,
      height: 1.5,
    );
    final glyphStyle = monoStyle(
      color: glyphColor,
      fontSize: 12.5,
      fontWeight: FontWeight.w800,
      height: 1.5,
    );

    return ColoredBox(
      color: lineBg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLineNumbers) ...[
            _GutterCell(
              width: 44,
              background: gutterBg,
              child: Text(
                row.oldNumber?.toString() ?? '',
                textAlign: TextAlign.right,
                style: mutedMono,
              ),
            ),
            _GutterCell(
              width: 44,
              background: gutterBg,
              child: Text(
                row.newNumber?.toString() ?? '',
                textAlign: TextAlign.right,
                style: mutedMono,
              ),
            ),
          ],
          _GutterCell(
            width: 22,
            background: gutterBg,
            child: Text(glyph, textAlign: TextAlign.center, style: glyphStyle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 14, 2),
            child: Text(
              row.content.isEmpty ? ' ' : row.content,
              style: textStyle,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _GutterCell extends StatelessWidget {
  const _GutterCell({
    required this.width,
    required this.background,
    required this.child,
  });

  final double width;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      color: background,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

enum _DiffKind { add, del, context, hunk, meta }

class _DiffLine {
  _DiffLine({
    required this.kind,
    required this.content,
    this.oldNumber,
    this.newNumber,
  });

  final _DiffKind kind;
  final String content;
  final int? oldNumber;
  final int? newNumber;
}

List<_DiffLine> _parseDiff(String input) {
  if (input.isEmpty) {
    return const [];
  }

  // Expand tabs to 4 spaces so indentation looks like code instead of a box
  // glyph or a single character gap. Most git tooling renders tabs this way.
  final lines = _expandTabs(input, 4).split('\n');
  // Strip a trailing empty line that comes from a terminal newline.
  if (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  final out = <_DiffLine>[];
  int oldNum = 0;
  int newNum = 0;

  for (final raw in lines) {
    if (raw.startsWith('@@')) {
      final match = _hunkHeader.firstMatch(raw);
      if (match != null) {
        oldNum = int.tryParse(match.group(1) ?? '0') ?? 0;
        newNum = int.tryParse(match.group(2) ?? '0') ?? 0;
      }
      out.add(_DiffLine(kind: _DiffKind.hunk, content: raw));
      continue;
    }
    if (raw.startsWith('diff ') ||
        raw.startsWith('index ') ||
        raw.startsWith('--- ') ||
        raw.startsWith('+++ ') ||
        raw.startsWith('new file mode') ||
        raw.startsWith('deleted file mode') ||
        raw.startsWith('similarity ') ||
        raw.startsWith('rename ') ||
        raw.startsWith('Binary ') ||
        raw.startsWith('\\ ')) {
      out.add(_DiffLine(kind: _DiffKind.meta, content: raw));
      continue;
    }
    if (raw.startsWith('+')) {
      out.add(
        _DiffLine(
          kind: _DiffKind.add,
          content: raw.substring(1),
          newNumber: newNum,
        ),
      );
      newNum += 1;
      continue;
    }
    if (raw.startsWith('-')) {
      out.add(
        _DiffLine(
          kind: _DiffKind.del,
          content: raw.substring(1),
          oldNumber: oldNum,
        ),
      );
      oldNum += 1;
      continue;
    }
    // Context lines (or lines without prefix) belong to both sides.
    final content = raw.startsWith(' ') ? raw.substring(1) : raw;
    out.add(
      _DiffLine(
        kind: _DiffKind.context,
        content: content,
        oldNumber: oldNum,
        newNumber: newNum,
      ),
    );
    oldNum += 1;
    newNum += 1;
  }

  return out;
}

final RegExp _hunkHeader = RegExp(r'@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@');

/// Expands tab characters line-aware so column alignment matches a real
/// monospace rendering. Tab stops sit at [tabWidth] intervals relative to
/// the start of each line.
String _expandTabs(String input, int tabWidth) {
  if (!input.contains('\t')) return input;
  final out = StringBuffer();
  int col = 0;
  for (int i = 0; i < input.length; i += 1) {
    final ch = input[i];
    if (ch == '\n') {
      out.write('\n');
      col = 0;
    } else if (ch == '\t') {
      final spaces = tabWidth - (col % tabWidth);
      out.write(' ' * spaces);
      col += spaces;
    } else {
      out.write(ch);
      col += 1;
    }
  }
  return out.toString();
}
