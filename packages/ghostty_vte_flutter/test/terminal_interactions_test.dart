import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboardText;

  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboardText =
                  (call.arguments as Map<Object?, Object?>)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return clipboardText == null
                  ? null
                  : <String, Object?>{'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('terminal interaction helpers', () {
    test('copy helper uses host callback when provided', () async {
      String? copied;

      await ghosttyTerminalCopyText(
        'hello',
        onCopySelection: (text) async {
          copied = text;
        },
      );

      expect(copied, 'hello');
    });

    test('paste helper uses host callback when provided', () async {
      final text = await ghosttyTerminalReadPasteText(
        onPasteRequest: () async => 'world',
      );

      expect(text, 'world');
    });

    test('copy helper falls back to the clipboard', () async {
      await ghosttyTerminalCopyText('clipboard');

      final data = await Clipboard.getData(Clipboard.kTextPlain);
      expect(clipboardText, 'clipboard');
      expect(data?.text, 'clipboard');
    });

    test('selection content helper builds a payload from the resolver', () {
      final content = ghosttyTerminalSelectionContentFor<int>(
        7,
        resolveText: (selection) => 'selection:$selection',
      );

      expect(content?.selection, 7);
      expect(content?.text, 'selection:7');
    });

    test('selection content helper returns null for no selection', () {
      final content = ghosttyTerminalSelectionContentFor<int>(
        null,
        resolveText: (selection) => '$selection',
      );

      expect(content, isNull);
    });

    test(
      'selection notify helper emits both selection and content payloads',
      () {
        int? changedSelection;
        GhosttyTerminalSelectionContent<int>? changedContent;

        ghosttyTerminalNotifySelectionChange<int>(
          previousSelection: 1,
          nextSelection: 2,
          resolveText: (selection) => 'value:$selection',
          onSelectionChanged: (selection) {
            changedSelection = selection;
          },
          onSelectionContentChanged: (content) {
            changedContent = content;
          },
        );

        expect(changedSelection, 2);
        expect(changedContent?.selection, 2);
        expect(changedContent?.text, 'value:2');
      },
    );

    test('selection content notifier emits derived content only', () {
      GhosttyTerminalSelectionContent<int>? changedContent;

      ghosttyTerminalNotifySelectionContent<int>(
        selection: 9,
        resolveText: (selection) => 'content:$selection',
        onSelectionContentChanged: (content) {
          changedContent = content;
        },
      );

      expect(changedContent?.selection, 9);
      expect(changedContent?.text, 'content:9');
    });

    test('hyperlink resolver normalizes empty URIs to null', () {
      final link = ghosttyTerminalResolveHyperlinkAt<int>(
        3,
        resolveUri: (_) => '',
      );

      expect(link, isNull);
    });

    test('hyperlink opener uses host callback when provided', () async {
      String? openedUri;

      await ghosttyTerminalOpenHyperlink(
        'https://example.com',
        onOpenHyperlink: (uri) async {
          openedUri = uri;
        },
      );

      expect(openedUri, 'https://example.com');
    });
  });
}
