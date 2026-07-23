import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/app_tokens.dart';
import 'package:sidemesh_mobile/src/widgets/app_primitives.dart';
import 'package:sidemesh_mobile/src/widgets/app_sheets.dart';
import 'package:sidemesh_mobile/src/widgets/mesh_widgets.dart';

void main() {
  testWidgets('section and management rows share one label grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.nord.light),
        home: const Scaffold(
          body: SizedBox(
            width: 600,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSectionHeader(
                  icon: Icons.tune_rounded,
                  title: 'Section title',
                  subtitle: 'Section description',
                ),
                AppSettingsRow(
                  icon: Icons.palette_rounded,
                  title: 'Row title',
                  subtitle: 'Row description',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final sectionX = tester.getTopLeft(find.text('Section title')).dx;
    final rowX = tester.getTopLeft(find.text('Row title')).dx;
    expect(sectionX, rowX);
  });

  testWidgets('global interactive controls use the canonical height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.nord.light),
        home: Scaffold(
          body: Row(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Save')),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.widgetWithText(FilledButton, 'Save')).height,
      AppSizes.control,
    );
    expect(tester.getSize(find.byType(IconButton)).height, AppSizes.control);
  });

  testWidgets('desktop management content uses the shared maximum width', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1200, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.nord.light),
        home: const Scaffold(
          body: AppContentColumn(
            child: SizedBox(key: ValueKey('content'), height: 100),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('content'))).width,
      AppSizes.contentMaxWidth,
    );
  });

  test('typography tokens reserve heavy weight for page titles', () {
    expect(AppWeights.body, FontWeight.w400);
    expect(AppWeights.title, FontWeight.w600);
    expect(AppWeights.strong, FontWeight.w700);
  });

  testWidgets('choice rows expose selection and respect disabled state', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.nord.light),
        home: Scaffold(
          body: Column(
            children: [
              AppChoiceRow(
                title: 'Selected model',
                selected: true,
                onTap: () => taps += 1,
              ),
              AppChoiceRow(
                title: 'Unavailable model',
                enabled: false,
                onTap: () => taps += 1,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    await tester.tap(find.text('Selected model'));
    await tester.tap(find.text('Unavailable model'));
    expect(taps, 1);
  });

  testWidgets('compact list sections stay flat and provide dividers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.nord.light),
        home: const Scaffold(
          body: AppListSection(
            title: 'Tools',
            children: [Text('Files'), Text('Terminal')],
          ),
        ),
      ),
    );

    expect(find.byType(MeshCard), findsNothing);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('mobile sheets use the full viewport width', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(400, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.nord.light),
        home: const Scaffold(
          body: MeshBottomSheetScaffold(
            icon: Icons.tune_rounded,
            title: 'Short choice',
            description: 'Choose one option.',
            child: SizedBox(height: 120),
          ),
        ),
      ),
    );

    final surface = find
        .descendant(
          of: find.byType(MeshBottomSheetScaffold),
          matching: find.byType(DecoratedBox),
        )
        .first;
    expect(tester.getSize(surface).width, 400);
  });
}
