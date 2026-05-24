import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  group('GhosttyTerminalSnapshot wrapped hyperlinks', () {
    test('detects raw URLs across wrapped rows', () {
      const snapshot = GhosttyTerminalSnapshot(
        lines: <GhosttyTerminalLine>[
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'see https://example.c', cells: 21),
          ], wrap: true),
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'om/docs now', cells: 11),
          ], wrapContinuation: true),
        ],
      );

      expect(
        snapshot.hyperlinkAt(const GhosttyTerminalCellPosition(row: 0, col: 8)),
        'https://example.com/docs',
      );
      expect(
        snapshot.hyperlinkAt(const GhosttyTerminalCellPosition(row: 1, col: 2)),
        'https://example.com/docs',
      );

      final selection = snapshot.wordSelectionAt(
        const GhosttyTerminalCellPosition(row: 1, col: 2),
      );
      expect(selection, isNotNull);
      expect(
        selection!.normalized.base,
        const GhosttyTerminalCellPosition(row: 0, col: 4),
      );
      expect(
        selection.normalized.extent,
        const GhosttyTerminalCellPosition(row: 1, col: 6),
      );
      expect(
        snapshot.textForSelection(
          selection,
          options: const GhosttyTerminalCopyOptions(joinWrappedLines: true),
        ),
        'https://example.com/docs',
      );
    });

    test('trims wrapped raw URL punctuation from selection', () {
      const snapshot = GhosttyTerminalSnapshot(
        lines: <GhosttyTerminalLine>[
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'see https://example.c', cells: 21),
          ], wrap: true),
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'om/docs).', cells: 9),
          ], wrapContinuation: true),
        ],
      );

      final selection = snapshot.wordSelectionAt(
        const GhosttyTerminalCellPosition(row: 1, col: 3),
      );
      expect(selection, isNotNull);
      expect(
        snapshot.textForSelection(
          selection!,
          options: const GhosttyTerminalCopyOptions(joinWrappedLines: true),
        ),
        'https://example.com/docs',
      );
    });

    test('resolves styled hyperlinks across wrapped rows', () {
      const linkStyle = GhosttyTerminalStyle(
        hyperlink: 'https://docs.example.com/guide',
      );
      const snapshot = GhosttyTerminalSnapshot(
        lines: <GhosttyTerminalLine>[
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'open ', cells: 5),
            GhosttyTerminalRun(text: 'guide-', cells: 6, style: linkStyle),
          ], wrap: true),
          GhosttyTerminalLine(<GhosttyTerminalRun>[
            GhosttyTerminalRun(text: 'page', cells: 4, style: linkStyle),
            GhosttyTerminalRun(text: ' now', cells: 4),
          ], wrapContinuation: true),
        ],
      );

      expect(
        snapshot.hyperlinkAt(const GhosttyTerminalCellPosition(row: 1, col: 1)),
        'https://docs.example.com/guide',
      );

      final selection = snapshot.wordSelectionAt(
        const GhosttyTerminalCellPosition(row: 1, col: 1),
      );
      expect(selection, isNotNull);
      expect(
        snapshot.textForSelection(
          selection!,
          options: const GhosttyTerminalCopyOptions(joinWrappedLines: true),
        ),
        'guide-page',
      );
    });
  });
}
