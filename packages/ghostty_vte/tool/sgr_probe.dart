// ignore_for_file: avoid_print

import 'package:ghostty_vte/ghostty_vte.dart';

void main() {
  final parser = VtSgrParser();
  for (final params in <List<int>>[
    <int>[0],
    <int>[1],
    <int>[31],
    <int>[0, 31],
    <int>[22],
    <int>[24],
  ]) {
    final attrs = parser.parseParams(params);
    print('params=$params');
    for (final attr in attrs) {
      print(
        '  tag=${attr.tag} underline=${attr.underline} palette=${attr.paletteIndex}',
      );
    }
  }
  parser.close();
}
