import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  testWidgets('HostsPane keeps mobile host row actions behind a menu', (
    tester,
  ) async {
    var opens = 0;
    var edits = 0;
    var removes = 0;
    var toggles = 0;
    const host = HostProfile(
      id: 'host-1',
      label: 'Cortex dev workstation',
      baseUrl: 'http://cortex-dev.local:8899/workspace',
      token: 'token',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: HostsPane(
              hosts: const [host],
              hostNodes: const {},
              installedAppVersion: '1.0.0',
              onOpenHost: (_) => opens++,
              onEditHost: (_) => edits++,
              onRemoveHost: (_) => removes++,
              onToggleEnabled: (_) => toggles++,
              onAddHost: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Cortex dev workstation'), findsOneWidget);
    expect(find.text('cortex-dev.local:8899'), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    expect(find.byIcon(Icons.edit_rounded), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Edit host'), findsOneWidget);
    expect(find.text('Remove host'), findsOneWidget);

    await tester.tap(find.text('Edit host'));
    await tester.pumpAndSettle();

    expect(edits, 1);
    expect(opens, 0);
    expect(removes, 0);
    expect(toggles, 0);
  });
}
