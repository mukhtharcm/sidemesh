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

  testWidgets('MeshCard routes through MeshSurface compatibility layer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const MeshCard(
          tone: MeshCardTone.elevated,
          child: Text('Legacy card'),
        ),
      ),
    );

    expect(find.byType(MeshSurface), findsOneWidget);
    expect(find.text('Legacy card'), findsOneWidget);
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

  testWidgets('MeshStatusBadge constrains long labels', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 120,
          child: MeshStatusBadge(
            label: 'Waiting for very long pending approval kind',
            tone: MeshStatusTone.approval,
            icon: Icons.gpp_maybe_rounded,
            compact: true,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(
      find.text('Waiting for very long pending approval kind'),
    );
    expect(label.overflow, TextOverflow.ellipsis);
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

  testWidgets('MeshListRow can render unframed grouped rows', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        MeshListRow(
          title: const Text('Terminal'),
          subtitle: const Text('Open a shell in this workspace.'),
          leading: const Icon(Icons.terminal_rounded),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => taps++,
          framed: false,
          dense: true,
        ),
      ),
    );

    expect(find.byType(MeshSurface), findsNothing);
    expect(find.text('Terminal'), findsOneWidget);

    await tester.tap(find.text('Terminal'));

    expect(taps, 1);
  });
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(ThemeVariant.codexAmber.light),
    home: Scaffold(body: Center(child: child)),
  );
}
