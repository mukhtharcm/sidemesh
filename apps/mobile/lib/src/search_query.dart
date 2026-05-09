List<String> searchQueryTerms(String rawQuery) {
  return rawQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
}

class SearchQueryMatchRange {
  const SearchQueryMatchRange(this.start, this.end);

  final int start;
  final int end;
}

bool matchesSearchQuery(String haystack, String rawQuery) {
  final terms = searchQueryTerms(rawQuery);
  if (terms.isEmpty) {
    return true;
  }

  final normalizedHaystack = haystack.toLowerCase();
  for (final term in terms) {
    if (!normalizedHaystack.contains(term)) {
      return false;
    }
  }
  return true;
}

List<SearchQueryMatchRange> searchQueryMatchRanges(
  String text,
  String rawQuery,
) {
  final terms = searchQueryTerms(rawQuery).toSet().toList(growable: false);
  if (terms.isEmpty || text.isEmpty) {
    return const <SearchQueryMatchRange>[];
  }

  final lowerText = text.toLowerCase();
  final matches = <SearchQueryMatchRange>[];
  for (final term in terms) {
    var start = 0;
    while (start < lowerText.length) {
      final index = lowerText.indexOf(term, start);
      if (index < 0) {
        break;
      }
      matches.add(SearchQueryMatchRange(index, index + term.length));
      start = index + term.length;
    }
  }

  if (matches.isEmpty) {
    return const <SearchQueryMatchRange>[];
  }

  matches.sort((left, right) {
    final startCompare = left.start.compareTo(right.start);
    if (startCompare != 0) {
      return startCompare;
    }
    return left.end.compareTo(right.end);
  });

  final merged = <SearchQueryMatchRange>[];
  var current = matches.first;
  for (var i = 1; i < matches.length; i++) {
    final next = matches[i];
    if (next.start <= current.end) {
      current = SearchQueryMatchRange(
        current.start,
        current.end > next.end ? current.end : next.end,
      );
      continue;
    }
    merged.add(current);
    current = next;
  }
  merged.add(current);
  return merged;
}
