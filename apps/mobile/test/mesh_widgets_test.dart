import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/mesh_widgets.dart';

void main() {
  testWidgets('MeshSurface forwards taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        MeshSurface(
          selected: true,
          onTap: () => taps++,
          child: const Text('Tap surface'),
        ),
      ),
    );

    await tester.tap(find.text('Tap surface'));

    expect(taps, 1);
  });

  testWidgets('MeshStatusBadge renders status label and icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MeshStatusBadge(
          label: 'approval',
          tone: MeshStatusTone.approval,
          icon: Icons.verified_user_outlined,
        ),
      ),
    );

    expect(find.text('approval'), findsOneWidget);
    expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
  });

  testWidgets('MeshListRow renders title, subtitle, badges, and trailing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const MeshListRow(
          title: Text('Remote host'),
          subtitle: Text('ssh://desk.local'),
          badges: [
            MeshStatusBadge(
              label: 'online',
              tone: MeshStatusTone.success,
              compact: true,
            ),
          ],
          trailing: Icon(Icons.chevron_right_rounded),
        ),
      ),
    );

    expect(find.text('Remote host'), findsOneWidget);
    expect(find.text('ssh://desk.local'), findsOneWidget);
    expect(find.text('online'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(ThemeVariant.codexAmber.light),
    home: Scaffold(body: Center(child: child)),
  );
}
