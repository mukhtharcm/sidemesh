import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/image_blob_cache_store.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/markdown_content.dart';

const _host = HostProfile(
  id: 'markdown-host',
  label: 'Markdown host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  Directory? tempRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempRoot = Directory.systemTemp.createTempSync('sidemesh-markdown-image-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationCacheDirectory') {
            return tempRoot!.path;
          }
          return null;
        });
    await ImageBlobCacheStore.instance.clearAll();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    final root = tempRoot;
    tempRoot = null;
    if (root != null && await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  testWidgets('loads local markdown images through the session filesystem', (
    tester,
  ) async {
    final api = _MarkdownImageApi(_onePixelPng);

    await _pumpMarkdown(
      tester,
      api: api,
      text: '![result](./artifacts/result.png)',
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_MarkdownImage',
      ),
      findsOneWidget,
    );
    await _waitForRequest(tester, api);
    await tester.pumpAndSettle();

    expect(api.paths, ['./artifacts/result.png']);
    expect(api.sessionIds, ['session-1']);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Image unavailable'), findsNothing);
  });

  testWidgets('markdown parser preserves local image targets', (tester) async {
    final sources = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: GptMarkdown(
          '![result](./artifacts/result.png)',
          imageBuilder: (context, source, width, height) {
            sources.add(source);
            return const SizedBox(width: 10, height: 10);
          },
        ),
      ),
    );

    expect(sources, ['./artifacts/result.png']);
  });

  testWidgets('opens workspace-local links in the file viewer', (tester) async {
    final api = _MarkdownImageApi(_onePixelPng);
    String? openedPath;

    await _pumpMarkdown(
      tester,
      api: api,
      text: '[View result](./artifacts/result.png)',
      onOpenFile: (path) => openedPath = path,
    );
    await tester.tap(find.text('View result'));
    await tester.pump();

    expect(openedPath, './artifacts/result.png');
  });

  testWidgets('uses a compact error card for inaccessible local images', (
    tester,
  ) async {
    final api = _MarkdownImageApi.error();

    await _pumpMarkdown(tester, api: api, text: '![private](/tmp/private.png)');
    await _waitForRequest(tester, api);
    await tester.pump();

    expect(api.paths, ['/tmp/private.png']);
    expect(api.sessionIds, ['session-1']);
    expect(find.text('Image unavailable'), findsOneWidget);
    expect(find.text('private.png'), findsOneWidget);
    final compactBox = tester.widget<ConstrainedBox>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConstrainedBox &&
            widget.constraints.maxHeight == 72 &&
            widget.constraints.minHeight == 58,
      ),
    );
    expect(compactBox.constraints.maxHeight, 72);
  });

  testWidgets('loads bare relative image sources through the host workspace', (
    tester,
  ) async {
    final api = _MarkdownImageApi(_onePixelPng);

    await _pumpMarkdown(
      tester,
      api: api,
      text: '![result](asset-without-a-scheme.png)',
    );
    await _waitForRequest(tester, api);
    await tester.pumpAndSettle();

    expect(api.paths, ['asset-without-a-scheme.png']);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Image unavailable'), findsNothing);
  });

  testWidgets('passes a Markdown document directory to the host resolver', (
    tester,
  ) async {
    final api = _MarkdownImageApi(_onePixelPng);

    await _pumpMarkdown(
      tester,
      api: api,
      text: '![result](./result.png)',
      basePath: '/repo/docs',
    );
    await _waitForRequest(tester, api);

    expect(api.paths, ['./result.png']);
    expect(api.basePaths, ['/repo/docs']);
  });

  testWidgets('loads loopback images through the connected host', (
    tester,
  ) async {
    final api = _MarkdownImageApi(_onePixelPng);

    await _pumpMarkdown(
      tester,
      api: api,
      text: '![preview](http://localhost:3000/result.png)',
    );
    await tester.runAsync(() async {
      for (var attempt = 0;
          attempt < 100 && api.hostUrls.isEmpty;
          attempt += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(api.hostUrls, ['http://localhost:3000/result.png']);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('publishes a referenced temporary image after workspace denial', (
    tester,
  ) async {
    final api = _MarkdownImageApi.temporary(_onePixelPng);

    await _pumpMarkdown(
      tester,
      api: api,
      text: '![validation](/tmp/validation.png)',
    );
    await _waitForRequest(tester, api);
    await tester.runAsync(() async {
      for (var attempt = 0;
          attempt < 100 && api.artifactSources.isEmpty;
          attempt += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(api.artifactSources, ['/tmp/validation.png']);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Image unavailable'), findsNothing);
  });
}

Future<void> _pumpMarkdown(
  WidgetTester tester, {
  required _MarkdownImageApi api,
  required String text,
  void Function(String path)? onOpenFile,
  String? basePath,
}) {
  final palette = ThemeVariant.codexAmber.light;
  return tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: MarkdownContent(
              text: text,
              textColor: palette.textPrimary,
              host: _host,
              api: api,
              sessionId: 'session-1',
              onOpenFile: onOpenFile,
              basePath: basePath,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _waitForRequest(WidgetTester tester, _MarkdownImageApi api) async {
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 100 && api.paths.isEmpty; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

class _MarkdownImageApi extends ApiClient {
  _MarkdownImageApi(this.bytes) : error = null;

  _MarkdownImageApi.error()
    : bytes = Uint8List(0),
      error = StateError('path is outside any workspace');

  _MarkdownImageApi.temporary(this.bytes)
    : error = const ApiException(403, '{"error":"outside workspace"}');

  final Uint8List bytes;
  final Object? error;
  final List<String> paths = <String>[];
  final List<String?> sessionIds = <String?>[];
  final List<String?> basePaths = <String?>[];
  final List<String> hostUrls = <String>[];
  final List<String> artifactSources = <String>[];

  @override
  Future<Uint8List> fetchFsBlob(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
    String? basePath,
  }) async {
    paths.add(path);
    sessionIds.add(sessionId);
    basePaths.add(basePath);
    final failure = error;
    if (failure != null) throw failure;
    return bytes;
  }

  @override
  Future<Uint8List> fetchHostResource(HostProfile host, String url) async {
    hostUrls.add(url);
    return bytes;
  }

  @override
  Future<SessionArtifact> publishSessionArtifact(
    HostProfile host, {
    required String sessionId,
    required String source,
  }) async {
    artifactSources.add(source);
    return SessionArtifact(
      id: 'artifact.png',
      contentType: 'image/png',
      size: bytes.length,
    );
  }

  @override
  Future<Uint8List> fetchSessionArtifact(
    HostProfile host,
    String artifactId,
  ) async {
    return bytes;
  }
}

final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
