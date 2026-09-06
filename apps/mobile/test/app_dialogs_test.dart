import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/app_dialogs.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'confirmation stays usable with large text and a keyboard: $mode',
      (tester) async {
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = const Size(320, 640)
          ..viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.reset);
        bool? confirmed;
        final palette = ThemeVariant.codexAmber;
        await tester.pumpWidget(
          MaterialApp(
            themeMode: mode,
            theme: buildLightTheme(palette.light, platform: TargetPlatform.iOS),
            darkTheme: buildDarkTheme(
              palette.dark,
              platform: TargetPlatform.iOS,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.8)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () async {
                    confirmed = await showMeshConfirmDialog(
                      context,
                      icon: Icons.edit_outlined,
                      title: 'Change this saved item?',
                      description:
                          'This change will replace the saved value. Check the new value before you save it.',
                      confirmLabel: 'Save item',
                      child: const TextField(
                        decoration: InputDecoration(labelText: 'Value'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Save item').hitTestable(), findsOneWidget);
        expect(find.text('Cancel').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(confirmed, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }
}
