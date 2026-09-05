import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/session_row_card.dart';
import 'package:sidemesh_mobile/src/workspace_label.dart';

void main() {
  test('home labels cover remote Unix and Windows paths', () {
    for (final path in ['/Users/alex', '/home/alex/', '/root', r'C:\Users\alex', '~']) {
      expect(workspaceLabel(path), '~');
    }
    expect(workspaceLabel('/Users/alex/project'), 'project');
    expect(workspaceLabel('/home/alex/repo/.git'), '.git');
  });

  testWidgets('grouped row is compact and hides repeated metadata and previews', (tester) async {
    final session = SessionSummary.fromJson({
      'id': 'row', 'title': 'Fix the build', 'cwd': '/home/alex/project',
      'preview': 'Do not repeat this preview', 'provider': 'codex',
      'status': 'idle', 'updatedAt': '2026-09-05T12:00:00Z',
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(ThemeVariant.nord.light),
      home: Scaffold(body: SizedBox(width: 390, child: SessionRowCard(
        host: const HostProfile(id: 'machine', label: 'Laptop', baseUrl: 'http://127.0.0.1:8899', token: ''),
        session: session, favorite: false, showHost: false, showWorkspace: false,
        onTap: () {}, onToggleFavorite: () {},
      ))),
    ));
    expect(find.text('Fix the build'), findsOneWidget);
    expect(find.text('Laptop'), findsNothing);
    expect(find.text('project'), findsNothing);
    expect(find.text('codex'), findsNothing);
    expect(find.text('Do not repeat this preview'), findsNothing);
    expect(tester.getSize(find.byType(SessionRowCard)).height, lessThanOrEqualTo(60));
    expect(tester.takeException(), isNull);
  });
}
