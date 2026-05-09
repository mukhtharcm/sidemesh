List<String> searchQueryTerms(String rawQuery) {
  return rawQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
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
