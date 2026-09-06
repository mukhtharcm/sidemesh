import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/app_tokens.dart';
import 'package:sidemesh_mobile/src/widgets/app_snackbar.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'toast follows theme and stays above the keyboard, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        BuildContext? source;
        var acted = false;
        final theme =
            (dark
                    ? buildDarkTheme(ThemeVariant.nord.dark)
                    : buildLightTheme(ThemeVariant.nord.light))
                .copyWith(platform: TargetPlatform.iOS);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 40),
                viewInsets: const EdgeInsets.only(bottom: 280),
                accessibleNavigation: true,
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) {
                source = context;
                return const Scaffold();
              },
            ),
          ),
        );
        showAppSnackBar(
          source!,
          'Message removed from the queue.',
          duration: const Duration(milliseconds: 300),
          action: SnackBarAction(label: 'Undo', onPressed: () => acted = true),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        final message = find.text('Message removed from the queue.');
        expect(message, findsOneWidget);
        expect(tester.getTopLeft(message).dy, greaterThan(40));
        expect(tester.getBottomLeft(message).dy, lessThan(360));
        expect(
          tester.widget<Text>(message).style,
          theme.snackBarTheme.contentTextStyle,
        );
        expect(
          tester.getSize(find.byTooltip('Dismiss')).height,
          greaterThanOrEqualTo(AppSizes.control),
        );
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(acted, isTrue);
        expect(message, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  testWidgets('dismisses when the timer fires before the overlay builds', (
    tester,
  ) async {
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

    showAppSnackBar(context!, 'racy toast', duration: Duration.zero);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.text('racy toast'), findsNothing);
  });

  testWidgets('close works while the toast is animating in', (tester) async {
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
      'early close',
      duration: const Duration(minutes: 1),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump();

    expect(find.text('early close'), findsNothing);
  });
}
