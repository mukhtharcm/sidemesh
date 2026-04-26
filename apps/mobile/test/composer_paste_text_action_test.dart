import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/widgets/composer_paste_text_action.dart';

void main() {
  testWidgets('falls back to text paste after async image probe', (
    tester,
  ) async {
    final contextKey = GlobalKey();
    var fallbackInvocations = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Actions(
          actions: <Type, Action<Intent>>{
            PasteTextIntent: ComposerPasteTextAction(
              onPasteImage: () async {
                await Future<void>.microtask(() {});
                return false;
              },
            ),
          },
          child: Builder(
            builder: (overrideContext) {
              return Actions(
                actions: <Type, Action<Intent>>{
                  PasteTextIntent: Action.overridable(
                    context: overrideContext,
                    defaultAction: _FallbackPasteAction(
                      onInvoke: () => fallbackInvocations += 1,
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

    final result = Actions.maybeInvoke<PasteTextIntent>(
      contextKey.currentContext!,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    if (result is Future<Object?>) {
      await result;
    }
    await tester.pump();

    expect(fallbackInvocations, 1);
  });
}

class _FallbackPasteAction extends Action<PasteTextIntent> {
  _FallbackPasteAction({required this.onInvoke});

  final VoidCallback onInvoke;

  @override
  Object? invoke(PasteTextIntent intent) {
    onInvoke();
    return null;
  }
}
