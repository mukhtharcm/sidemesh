import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/mesh_widgets.dart';

const int defaultTabularPreviewRowLimit = 200;
const int defaultTabularPreviewColumnLimit = 24;
const int defaultTabularPreviewCellCharacterLimit = 120;

enum DelimitedTextFormat {
  csv(',', 'CSV'),
  tsv('\t', 'TSV');

  const DelimitedTextFormat(this.delimiter, this.label);

  final String delimiter;
  final String label;
}

DelimitedTextFormat? delimitedTextFormatForFile(String path, String? mimeHint) {
  final lowerPath = path.toLowerCase();
  if (lowerPath.endsWith('.csv')) {
    return DelimitedTextFormat.csv;
  }
  if (lowerPath.endsWith('.tsv')) {
    return DelimitedTextFormat.tsv;
  }

  final normalizedMime = (mimeHint ?? '').toLowerCase().trim();
  final mime = normalizedMime.split(';').first.trim();
  return switch (mime) {
    'text/csv' || 'application/csv' => DelimitedTextFormat.csv,
    'text/tab-separated-values' || 'text/tsv' => DelimitedTextFormat.tsv,
    _ => null,
  };
}

class DelimitedTextPreviewData {
  const DelimitedTextPreviewData({
    required this.format,
    required this.rowCount,
    required this.columnCount,
    required this.displayRows,
    required this.displayColumnCount,
    required this.hasUnevenRows,
    required this.hasHiddenRows,
    required this.hasHiddenColumns,
    required this.hasClippedCells,
    required this.hasUnterminatedQuote,
  });

  final DelimitedTextFormat format;
  final int rowCount;
  final int columnCount;
  final List<List<String>> displayRows;
  final int displayColumnCount;
  final bool hasUnevenRows;
  final bool hasHiddenRows;
  final bool hasHiddenColumns;
  final bool hasClippedCells;
  final bool hasUnterminatedQuote;

  bool get isEmpty => rowCount == 0 || columnCount == 0;

  List<String> get notices => <String>[
    if (hasHiddenRows)
      'Showing the first ${displayRows.length} of $rowCount rows.',
    if (hasHiddenColumns)
      'Showing the first $displayColumnCount of $columnCount columns.',
    if (hasClippedCells) 'Long cells are clipped in table view.',
    if (hasUnevenRows)
      'Rows have different column counts, missing cells are left blank.',
    if (hasUnterminatedQuote)
      'Some quoted cells were not closed, parsed best-effort.',
  ];
}

DelimitedTextPreviewData parseDelimitedTextPreview({
  required String contents,
  required DelimitedTextFormat format,
  int maxPreviewRows = defaultTabularPreviewRowLimit,
  int maxPreviewColumns = defaultTabularPreviewColumnLimit,
  int maxCellCharacters = defaultTabularPreviewCellCharacterLimit,
}) {
  final source = contents.startsWith('\ufeff')
      ? contents.substring(1)
      : contents;
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var inQuotes = false;

  void pushField() {
    row.add(field.toString());
    field = StringBuffer();
  }

  void pushRow() {
    rows.add(List<String>.unmodifiable(row));
    row = <String>[];
  }

  for (var index = 0; index < source.length; index++) {
    final char = source[index];
    if (inQuotes) {
      if (char == '"') {
        final nextIsQuote =
            index + 1 < source.length && source[index + 1] == '"';
        if (nextIsQuote) {
          field.write('"');
          index++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(char);
      }
      continue;
    }

    if (char == '"') {
      if (field.length == 0) {
        inQuotes = true;
      } else {
        field.write(char);
      }
      continue;
    }
    if (char == format.delimiter) {
      pushField();
      continue;
    }
    if (char == '\n' || char == '\r') {
      pushField();
      pushRow();
      if (char == '\r' &&
          index + 1 < source.length &&
          source[index + 1] == '\n') {
        index++;
      }
      continue;
    }
    field.write(char);
  }

  final hasUnterminatedQuote = inQuotes;
  if (field.length > 0 || row.isNotEmpty) {
    pushField();
    pushRow();
  }

  var columnCount = 0;
  var hasUnevenRows = false;
  for (final parsedRow in rows) {
    columnCount = math.max(columnCount, parsedRow.length);
  }
  for (final parsedRow in rows) {
    if (parsedRow.length != columnCount) {
      hasUnevenRows = true;
      break;
    }
  }

  final limitedRows = rows.take(maxPreviewRows).toList(growable: false);
  final displayColumnCount = math.min(columnCount, maxPreviewColumns);
  var hasClippedCells = false;
  for (final parsedRow in limitedRows) {
    final visibleCells = math.min(parsedRow.length, displayColumnCount);
    for (var column = 0; column < visibleCells; column++) {
      final compacted = compactTabularCell(parsedRow[column]);
      if (compacted.length > maxCellCharacters) {
        hasClippedCells = true;
        break;
      }
    }
    if (hasClippedCells) {
      break;
    }
  }

  return DelimitedTextPreviewData(
    format: format,
    rowCount: rows.length,
    columnCount: columnCount,
    displayRows: List<List<String>>.unmodifiable(limitedRows),
    displayColumnCount: displayColumnCount,
    hasUnevenRows: hasUnevenRows,
    hasHiddenRows: rows.length > maxPreviewRows,
    hasHiddenColumns: columnCount > maxPreviewColumns,
    hasClippedCells: hasClippedCells,
    hasUnterminatedQuote: hasUnterminatedQuote,
  );
}

String compactTabularCell(String value) {
  return value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', ' | ')
      .replaceAll('\t', '    ');
}

class TabularFilePreview extends StatelessWidget {
  const TabularFilePreview({
    super.key,
    required this.contents,
    required this.format,
    this.maxPreviewRows = defaultTabularPreviewRowLimit,
    this.maxPreviewColumns = defaultTabularPreviewColumnLimit,
    this.maxCellCharacters = defaultTabularPreviewCellCharacterLimit,
  });

  final String contents;
  final DelimitedTextFormat format;
  final int maxPreviewRows;
  final int maxPreviewColumns;
  final int maxCellCharacters;

  @override
  Widget build(BuildContext context) {
    final preview = parseDelimitedTextPreview(
      contents: contents,
      format: format,
      maxPreviewRows: maxPreviewRows,
      maxPreviewColumns: maxPreviewColumns,
      maxCellCharacters: maxCellCharacters,
    );
    final colors = context.colors;
    if (preview.isEmpty) {
      return const MeshEmptyState.compact(
        icon: Icons.table_chart_rounded,
        title: 'No rows to preview',
        body: 'This file is empty, or it does not contain any delimited rows.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            MeshPill(
              label: preview.format.label,
              tone: MeshPillTone.accent,
              icon: Icons.table_chart_rounded,
            ),
            MeshPill(label: _countLabel(preview.rowCount, 'row'), mono: true),
            MeshPill(
              label: _countLabel(preview.columnCount, 'column'),
              mono: true,
            ),
            if (preview.hasUnevenRows)
              const MeshPill(label: 'Uneven rows', tone: MeshPillTone.warning),
          ],
        ),
        if (preview.notices.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          MeshCard(
            tone: MeshCardTone.muted,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 10,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    preview.notices.join(' '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        _TabularGrid(preview: preview, maxCellCharacters: maxCellCharacters),
      ],
    );
  }
}

class _TabularGrid extends StatelessWidget {
  const _TabularGrid({required this.preview, required this.maxCellCharacters});

  final DelimitedTextPreviewData preview;
  final int maxCellCharacters;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final columnWidths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(52),
      for (var index = 0; index < preview.displayColumnCount; index++)
        index + 1: FixedColumnWidth(
          _estimateColumnWidth(
            preview,
            columnIndex: index,
            maxCellCharacters: maxCellCharacters,
          ),
        ),
    };
    final totalWidth = columnWidths.values.fold<double>(
      0,
      (sum, width) => sum + (width as FixedColumnWidth).value,
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: colors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final minWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : totalWidth;
            final tableWidth = math.max(minWidth, totalWidth);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: tableWidth,
                child: SelectionArea(
                  child: Table(
                    border: TableBorder(
                      horizontalInside: BorderSide(
                        color: colors.border.withValues(alpha: 0.72),
                      ),
                      verticalInside: BorderSide(
                        color: colors.border.withValues(alpha: 0.72),
                      ),
                    ),
                    columnWidths: columnWidths,
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    children: [
                      TableRow(
                        decoration: BoxDecoration(color: colors.surfaceMuted),
                        children: [
                          _TableHeaderCell(label: '#', alignEnd: true),
                          for (
                            var column = 0;
                            column < preview.displayColumnCount;
                            column++
                          )
                            _TableHeaderCell(label: _columnLabel(column)),
                        ],
                      ),
                      for (
                        var rowIndex = 0;
                        rowIndex < preview.displayRows.length;
                        rowIndex++
                      )
                        TableRow(
                          decoration: BoxDecoration(
                            color: rowIndex.isEven
                                ? colors.surface
                                : colors.surfaceMuted.withValues(alpha: 0.48),
                          ),
                          children: [
                            _TableIndexCell(index: rowIndex + 1),
                            for (
                              var column = 0;
                              column < preview.displayColumnCount;
                              column++
                            )
                              _TableValueCell(
                                value:
                                    column <
                                        preview.displayRows[rowIndex].length
                                    ? preview.displayRows[rowIndex][column]
                                    : '',
                                maxCharacters: maxCellCharacters,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TableHeaderCell extends StatelessWidget {
  const _TableHeaderCell({required this.label, this.alignEnd = false});

  final String label;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: monoStyle(
            color: colors.textSecondary,
            fontSize: 12,
            fontWeight: AppWeights.title,
          ),
        ),
      ),
    );
  }
}

class _TableIndexCell extends StatelessWidget {
  const _TableIndexCell({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          '$index',
          style: monoStyle(color: colors.textTertiary, fontSize: 12),
        ),
      ),
    );
  }
}

class _TableValueCell extends StatelessWidget {
  const _TableValueCell({required this.value, required this.maxCharacters});

  final String value;
  final int maxCharacters;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final compacted = compactTabularCell(value);
    final wasClipped = compacted.length > maxCharacters;
    final visibleText = wasClipped
        ? '${compacted.substring(0, math.max(0, maxCharacters - 3))}...'
        : compacted;
    final child = Text(
      visibleText.isEmpty ? ' ' : visibleText,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: monoStyle(
        color: colors.textPrimary,
        fontSize: 12.5,
        fontWeight: AppWeights.body,
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: wasClipped ? Tooltip(message: compacted, child: child) : child,
    );
  }
}

String _countLabel(int count, String noun) {
  final suffix = count == 1 ? '' : 's';
  return '$count $noun$suffix';
}

String _columnLabel(int index) {
  var value = index;
  final buffer = StringBuffer();
  do {
    final remainder = value % 26;
    buffer.writeCharCode(65 + remainder);
    value = value ~/ 26 - 1;
  } while (value >= 0);
  return buffer.toString().split('').reversed.join();
}

double _estimateColumnWidth(
  DelimitedTextPreviewData preview, {
  required int columnIndex,
  required int maxCellCharacters,
}) {
  var maxChars = _columnLabel(columnIndex).length;
  for (final row in preview.displayRows) {
    if (columnIndex >= row.length) {
      continue;
    }
    final compacted = compactTabularCell(row[columnIndex]);
    maxChars = math.max(
      maxChars,
      math.min(compacted.length, maxCellCharacters),
    );
  }
  final width = (maxChars * 7.2) + 30;
  return width.clamp(120.0, 280.0).toDouble();
}
