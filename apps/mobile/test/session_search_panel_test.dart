import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/inspector/inspector_search.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/app_tokens.dart';
import 'package:sidemesh_mobile/src/widgets/app_sheets.dart';
import 'package:sidemesh_mobile/src/widgets/mesh_widgets.dart';

void main() {
  testWidgets('open search follows loading, retry, new records, and filters', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    final revision = ValueNotifier(0);
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    addTearDown(revision.dispose);
    var loading = true;
    String? error;
    var retried = false;
    var records = <SearchRecord>[];
    final surface = buildInspectorSearchSurface(
      ownerKey: 'test',
      controller: controller,
      focusNode: focus,
      recordsBuilder: () => records,
      refresh: revision,
      loadingBuilder: () => loading,
      errorBuilder: () => error,
      onRetry: () => retried = true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.nord.light),
        home: Scaffold(body: Builder(builder: surface.bodyBuilder)),
      ),
    );
    await tester.pump();
    expect(find.byType(MeshLoader), findsOneWidget);
    expect(find.text('0 items'), findsNothing);
    loading = false;
    error = 'Connection lost';
    revision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Could not load conversation'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
    error = null;
    revision.value++;
    await tester.pumpAndSettle();
    expect(find.text('No messages or actions to search yet.'), findsOneWidget);
    records = [_messageRecord()];
    revision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Type to search this conversation.'), findsOneWidget);
    expect(find.text('1 match'), findsNothing);
    await tester.enterText(find.byType(TextField), 'rounded');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('1 match'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Theme.dart');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RichText>(find.byType(RichText))
          .any((text) => text.text.toPlainText().contains('Theme.dart')),
      isTrue,
    );
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(
      find.text('No matches. Try another word or filter.'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('Type to search this conversation.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('search sheet fits a small phone with keyboard, dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme:
              (dark
                      ? buildDarkTheme(ThemeVariant.nord.dark)
                      : buildLightTheme(ThemeVariant.nord.light))
                  .copyWith(platform: TargetPlatform.iOS),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  backgroundColor: Colors.transparent,
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(1.6),
                      viewInsets: const EdgeInsets.only(bottom: 280),
                    ),
                    child: MeshBottomSheetScaffold(
                      title: 'Search',
                      maxHeightFactor: .88,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.sm,
                        AppSpacing.lg,
                        AppSpacing.lg + 280,
                      ),
                      child: SearchPanel(
                        controller: controller,
                        focusNode: focus,
                        records: [_messageRecord()],
                      ),
                    ),
                  ),
                ),
                child: const Text('Open search'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      expect(find.text('Search'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPanel), findsNothing);
    });
  }
}

SearchRecord _messageRecord() {
  final date = DateTime(2026, 9, 6);
  return SearchRecord(
    id: 'message',
    kind: SearchRecordKind.message,
    createdAt: date,
    haystack: 'Use a rounded search field\nTheme.dart',
    title: 'You',
    message: SessionMessage(
      id: 'message',
      role: 'user',
      text: 'Use a rounded search field',
      attachments: const [],
      createdAt: date,
      seq: 1,
    ),
  );
}
