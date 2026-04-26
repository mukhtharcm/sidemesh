import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/widgets/composer_paste_text_action.dart';

void main() {
  testWidgets('falls back to text paste after async image probe', (
    tester,
  ) async {
    final harness = await _pumpPasteHarness(
      tester,
      onPasteImage: () async {
        await Future<void>.microtask(() {});
        return false;
      },
    );

    final result = await harness.invoke();

    expect(result, 'fallback-result');
    expect(harness.fallbackInvocations, 1);
  });

  testWidgets('does not invoke text fallback when image paste succeeds', (
    tester,
  ) async {
    final harness = await _pumpPasteHarness(
      tester,
      onPasteImage: () async => true,
    );

    final result = await harness.invoke();

    expect(result, isNull);
    expect(harness.fallbackInvocations, 0);
  });

  testWidgets('returns async fallback result unchanged', (tester) async {
    final harness = await _pumpPasteHarness(
      tester,
      onPasteImage: () async => false,
      fallbackResult: Future<Object?>.value('async-fallback-result'),
    );

    final result = await harness.invoke();

    expect(result, 'async-fallback-result');
    expect(harness.fallbackInvocations, 1);
  });
}

class _FallbackPasteAction extends Action<PasteTextIntent> {
  _FallbackPasteAction({required this.onInvoke, this.result});

  final VoidCallback onInvoke;
  final Object? result;

  @override
  Object? invoke(PasteTextIntent intent) {
    onInvoke();
    return result;
  }
}

class _PasteHarness {
  _PasteHarness({
    required this.contextKey,
    required this.fallbackInvocationCount,
  });

  final GlobalKey contextKey;
  final ValueNotifier<int> fallbackInvocationCount;

  int get fallbackInvocations => fallbackInvocationCount.value;

  Future<Object?> invoke() async {
    final result = Actions.maybeInvoke<PasteTextIntent>(
      contextKey.currentContext!,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    if (result is Future<Object?>) {
      return await result;
    }
    return result;
  }
}

Future<_PasteHarness> _pumpPasteHarness(
  WidgetTester tester, {
  required Future<bool> Function() onPasteImage,
  Object? fallbackResult = 'fallback-result',
}) async {
  final contextKey = GlobalKey();
  final fallbackInvocations = ValueNotifier<int>(0);

  await tester.pumpWidget(
    MaterialApp(
      home: Actions(
        actions: <Type, Action<Intent>>{
          PasteTextIntent: ComposerPasteTextAction(onPasteImage: onPasteImage),
        },
        child: Builder(
          builder: (overrideContext) {
            return Actions(
              actions: <Type, Action<Intent>>{
                PasteTextIntent: Action.overridable(
                  context: overrideContext,
                  defaultAction: _FallbackPasteAction(
                    onInvoke: () => fallbackInvocations.value += 1,
                    result: fallbackResult,
                  ),
                ),
              },
              child: SizedBox(key: contextKey),
            );
          },
        ),
      ),
    ),
  );

  return _PasteHarness(
    contextKey: contextKey,
    fallbackInvocationCount: fallbackInvocations,
  );
}
