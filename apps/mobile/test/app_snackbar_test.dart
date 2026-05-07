import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/widgets/app_snackbar.dart';

void main() {
  testWidgets('close button drops queued toasts', (tester) async {
    BuildContext? context;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (builderContext) {
            context = builderContext;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );

    showAppSnackBar(
      context!,
      'first toast',
      duration: const Duration(minutes: 1),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('first toast'), findsOneWidget);

    showAppSnackBar(context!, 'second toast');
    await tester.pump();

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump();

    expect(find.text('first toast'), findsNothing);
    expect(find.text('second toast'), findsNothing);
  });

  testWidgets('recovers when active toast overlay is removed', (tester) async {
    BuildContext? firstContext;
    BuildContext? secondContext;

    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('first-app'),
        home: Builder(
          builder: (context) {
            firstContext = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );

    showAppSnackBar(
      firstContext!,
      'first toast',
      duration: const Duration(minutes: 1),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('first toast'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('second-app'),
        home: Builder(
          builder: (context) {
            secondContext = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('first toast'), findsNothing);

    showAppSnackBar(secondContext!, 'second toast');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('second toast'), findsOneWidget);
  });

}
