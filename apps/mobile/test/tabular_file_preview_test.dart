import 'package:flutter_test/flutter_test.dart';

import 'package:sidemesh_mobile/src/screens/tabular_file_preview.dart';

void main() {
  test(
    'parses quoted CSV cells, uneven rows, and preview limits defensively',
    () {
      final preview = parseDelimitedTextPreview(
        contents:
            'name,notes,count,owner\n'
            'alpha,"line 1\nline 2 with extra detail",3,sam\n'
            'beta,short\n',
        format: DelimitedTextFormat.csv,
        maxPreviewRows: 2,
        maxPreviewColumns: 3,
        maxCellCharacters: 12,
      );

      expect(preview.rowCount, 3);
      expect(preview.columnCount, 4);
      expect(preview.displayRows.length, 2);
      expect(preview.displayColumnCount, 3);
      expect(preview.hasHiddenRows, isTrue);
      expect(preview.hasHiddenColumns, isTrue);
      expect(preview.hasUnevenRows, isTrue);
      expect(preview.hasClippedCells, isTrue);
      expect(preview.hasUnterminatedQuote, isFalse);
      expect(preview.displayRows[1][1], 'line 1\nline 2 with extra detail');
    },
  );

  test('keeps malformed quoted CSV files parseable without crashing', () {
    final preview = parseDelimitedTextPreview(
      contents: 'name,notes\nalpha,"unterminated',
      format: DelimitedTextFormat.csv,
    );

    expect(preview.rowCount, 2);
    expect(preview.columnCount, 2);
    expect(preview.hasUnterminatedQuote, isTrue);
    expect(preview.displayRows[1][1], 'unterminated');
  });

  test('recognizes CSV and TSV files from path or mime', () {
    expect(
      delimitedTextFormatForFile('/workspace/data/demo.csv', null),
      DelimitedTextFormat.csv,
    );
    expect(
      delimitedTextFormatForFile('/workspace/data/demo.tsv', null),
      DelimitedTextFormat.tsv,
    );
    expect(
      delimitedTextFormatForFile('/workspace/data/report.txt', 'text/csv'),
      DelimitedTextFormat.csv,
    );
    expect(
      delimitedTextFormatForFile(
        '/workspace/data/report.txt',
        'text/tab-separated-values; charset=utf-8',
      ),
      DelimitedTextFormat.tsv,
    );
  });
}
