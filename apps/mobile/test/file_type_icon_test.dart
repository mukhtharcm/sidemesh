import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/widgets/file_type_icon.dart';

void main() {
  testWidgets('major lockfiles use branded SVG icons when available', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              FileTypeIcon('pnpm-lock.yaml'),
              FileTypeIcon('yarn.lock'),
              FileTypeIcon('bun.lock'),
              FileTypeIcon('package-lock.json'),
              FileTypeIcon('cargo.lock'),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(SvgPicture), findsNWidgets(5));
  });

  testWidgets('unknown lockfiles still fall back to a lock glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: FileTypeIcon('composer.lock')),
      ),
    );

    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
  });
}
