import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/search_query.dart';

void main() {
  test('splits search queries into normalized terms', () {
    expect(searchQueryTerms('  Foo   BAR  '), <String>['foo', 'bar']);
  });

  test('matches search queries across separate fields', () {
    expect(matchesSearchQuery('Donation system\nMacBook\n/repo', 'donation repo'), isTrue);
    expect(matchesSearchQuery('Donation system\nMacBook\n/repo', 'donation windows'), isFalse);
  });

  test('finds ranges for each matched term', () {
    final matches = searchQueryMatchRanges(
      'configure nginx reverse proxy',
      'config proxy',
    );

    expect(matches.length, 2);
    expect(matches[0].start, 0);
    expect(matches[0].end, 6);
    expect(matches[1].start, 24);
    expect(matches[1].end, 29);
  });

  test('merges overlapping ranges from repeated terms', () {
    final matches = searchQueryMatchRanges('foobar', 'foo foobar');

    expect(matches.length, 1);
    expect(matches[0].start, 0);
    expect(matches[0].end, 6);
  });
}
