import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/screens/image_viewer_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  ImageViewerSource buildSource({
    String heroTag = 'test-image',
    String title = 'Generated image',
    String subtitle = '/tmp/generated.png',
  }) => ImageViewerSource(
    imageProvider: const _TestImageProvider(),
    heroTag: heroTag,
    title: title,
    subtitle: subtitle,
  );

  Widget buildTestApp(Widget home) {
    return MaterialApp(
      theme: buildDarkTheme(ThemeVariant.codexAmber.dark),
      home: TooltipVisibility(visible: false, child: home),
    );
  }

  testWidgets('image viewer zoom controls update the scale label', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        ImageViewerScreen(sources: <ImageViewerSource>[buildSource()]),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Generated image'), findsOneWidget);
    expect(find.text('/tmp/generated.png'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('200%'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.center_focus_strong_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('image viewer keyboard shortcuts page through route gallery', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        ImageViewerScreen(
          sources: <ImageViewerSource>[
            buildSource(
              heroTag: 'first-image',
              title: 'First image',
              subtitle: '/tmp/first.png',
            ),
            buildSource(
              heroTag: 'second-image',
              title: 'Second image',
              subtitle: '/tmp/second.png',
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('First image'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Second image'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('First image'), findsOneWidget);
  });

  testWidgets('image viewer keyboard shortcuts control current zoom', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        ImageViewerScreen(sources: <ImageViewerSource>[buildSource()]),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('100%'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('200%'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('300%'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('auto presentation uses a dialog on wide layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      buildTestApp(
        Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    showImageViewer(context, source: buildSource());
                  },
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('/tmp/generated.png'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('image viewer dialog closes from escape key', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      buildTestApp(
        Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    showImageGalleryViewer(
                      context,
                      sources: <ImageViewerSource>[
                        buildSource(
                          heroTag: 'dialog-first-image',
                          title: 'Dialog first image',
                        ),
                        buildSource(
                          heroTag: 'dialog-second-image',
                          title: 'Dialog second image',
                        ),
                      ],
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(Dialog), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(Dialog), findsNothing);
  });
}

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  const _TestImageProvider();

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_TestImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _TestImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_loadImage());
  }

  Future<ImageInfo> _loadImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = const Color(0xFFE78A3C);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 48, 48), paint);
    final image = await recorder.endRecording().toImage(48, 48);
    return ImageInfo(image: image);
  }
}
