import 'package:xterm/xterm.dart' as xterm;

final RegExp terminalUrlRegExp = RegExp(
  r'(https?:\/\/[^\s<>]+|www\.[^\s<>]+)',
  caseSensitive: false,
);

class TerminalUrlMatch {
  const TerminalUrlMatch({
    required this.displayText,
    required this.href,
    required this.start,
    required this.end,
  });

  final String displayText;
  final String href;
  final int start;
  final int end;
}

class TerminalLogicalLine {
  const TerminalLogicalLine._({
    required this.startRow,
    required this.endRow,
    required this.text,
    required List<_TerminalLogicalSlice> slices,
  }) : _slices = slices;

  final int startRow;
  final int endRow;
  final String text;
  final List<_TerminalLogicalSlice> _slices;

  int? textIndexForTap(xterm.CellOffset offset) {
    final slice = _sliceForRow(offset.y);
    if (slice == null || slice.text.isEmpty || offset.x >= slice.text.length) {
      return null;
    }
    return slice.start + offset.x;
  }

  int? textIndexForSelection(xterm.CellOffset offset) {
    final slice = _sliceForRow(offset.y);
    if (slice == null) {
      return null;
    }
    final x = offset.x.clamp(0, slice.text.length);
    return slice.start + x;
  }

  xterm.BufferRangeLine? rangeForSpan(int start, int end) {
    if (start < 0 || end <= start || end > text.length) {
      return null;
    }
    final startSlice = _sliceForIndex(start);
    final endSlice = _sliceForIndex(end - 1);
    if (startSlice == null || endSlice == null) {
      return null;
    }
    return xterm.BufferRangeLine(
      xterm.CellOffset(start - startSlice.start, startSlice.row),
      xterm.CellOffset(end - endSlice.start, endSlice.row),
    );
  }

  _TerminalLogicalSlice? _sliceForRow(int row) {
    for (final slice in _slices) {
      if (slice.row == row) {
        return slice;
      }
    }
    return null;
  }

  _TerminalLogicalSlice? _sliceForIndex(int index) {
    for (final slice in _slices) {
      if (index >= slice.start && index < slice.end) {
        return slice;
      }
    }
    return null;
  }
}

class _TerminalLogicalSlice {
  const _TerminalLogicalSlice({
    required this.row,
    required this.text,
    required this.start,
  });

  final int row;
  final String text;
  final int start;

  int get end => start + text.length;
}

TerminalLogicalLine logicalLineAt(xterm.Terminal terminal, int row) {
  final buffer = terminal.buffer;
  final height = buffer.height;
  if (height <= 0) {
    return const TerminalLogicalLine._(
      startRow: 0,
      endRow: 0,
      text: '',
      slices: <_TerminalLogicalSlice>[],
    );
  }

  var startRow = row.clamp(0, height - 1);
  while (startRow > 0 && buffer.lines[startRow].isWrapped) {
    startRow--;
  }

  var endRow = startRow;
  while (endRow + 1 < height && buffer.lines[endRow + 1].isWrapped) {
    endRow++;
  }

  final slices = <_TerminalLogicalSlice>[];
  final builder = StringBuffer();
  var cursor = 0;
  for (var currentRow = startRow; currentRow <= endRow; currentRow++) {
    final line = buffer.lines[currentRow];
    final text = line.getText(0, line.getTrimmedLength());
    slices.add(
      _TerminalLogicalSlice(row: currentRow, text: text, start: cursor),
    );
    builder.write(text);
    cursor += text.length;
  }

  return TerminalLogicalLine._(
    startRow: startRow,
    endRow: endRow,
    text: builder.toString(),
    slices: slices,
  );
}

TerminalUrlMatch? terminalUrlAtCell(
  xterm.Terminal terminal,
  xterm.CellOffset offset,
) {
  final line = logicalLineAt(terminal, offset.y);
  final index = line.textIndexForTap(offset);
  if (index == null) {
    return null;
  }
  for (final match in terminalUrlRegExp.allMatches(line.text)) {
    final parsed = _parsedUrlMatch(line.text, match);
    if (parsed == null) {
      continue;
    }
    if (index >= parsed.start && index < parsed.end) {
      return parsed;
    }
  }
  return null;
}

xterm.BufferRangeLine? terminalUrlRangeContainingSelection(
  xterm.Terminal terminal,
  xterm.BufferRange selection,
) {
  final normalized = selection.normalized;
  final line = logicalLineAt(terminal, normalized.begin.y);
  if (normalized.end.y > line.endRow) {
    return null;
  }
  final selectionStart = line.textIndexForSelection(normalized.begin);
  if (selectionStart == null) {
    return null;
  }
  final selectionText = terminal.buffer.getText(normalized);
  if (selectionText.isEmpty) {
    return null;
  }
  final selectionEnd = selectionStart + selectionText.length;

  for (final match in terminalUrlRegExp.allMatches(line.text)) {
    final parsed = _parsedUrlMatch(line.text, match);
    if (parsed == null) {
      continue;
    }
    if (parsed.start <= selectionStart && parsed.end >= selectionEnd) {
      return line.rangeForSpan(parsed.start, parsed.end);
    }
  }
  return null;
}

TerminalUrlMatch? firstTerminalUrl(String text) {
  final match = terminalUrlRegExp.firstMatch(text);
  if (match == null) {
    return null;
  }
  return _parsedUrlMatch(text, match);
}

TerminalUrlMatch? _parsedUrlMatch(String source, RegExpMatch match) {
  var raw = match.group(0);
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final trimmed = raw.replaceAll(RegExp(r'[),.!?;:\]]+$'), '');
  if (trimmed.isEmpty) {
    return null;
  }
  final removed = raw.length - trimmed.length;
  final end = match.end - removed;
  final href = trimmed.startsWith('www.') ? 'https://$trimmed' : trimmed;
  return TerminalUrlMatch(
    displayText: trimmed,
    href: href,
    start: match.start,
    end: end,
  );
}
