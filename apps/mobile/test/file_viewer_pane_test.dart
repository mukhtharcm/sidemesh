import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/fs_models.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/archive_preview_pane.dart';
import 'package:sidemesh_mobile/src/screens/file_viewer_screen.dart';
import 'package:sidemesh_mobile/src/screens/pdf_viewer_pane.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/syntax_code_block.dart';
import 'package:sidemesh_mobile/src/app_icons.dart';

void main() {
  late VideoPlayerPlatform originalPlatform;
  late _FakeVideoPlayerPlatform fakeVideoPlatform;

  setUp(() {
    originalPlatform = VideoPlayerPlatform.instance;
    fakeVideoPlatform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fakeVideoPlatform;
  });

  tearDown(() {
    VideoPlayerPlatform.instance = originalPlatform;
  });

  testWidgets(
    'file viewer auto-opens video previews from the authenticated blob url',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: const FsFile(
          path: '/workspace/clips/demo.mp4',
          size: 4096,
          binary: true,
          truncated: false,
          modifiedAtMs: 0,
          mimeHint: 'video/mp4',
          encoding: 'none',
          contents: '',
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/clips/demo.mp4',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(find.text('Tap the video to play or pause.'), findsOneWidget);
      expect(
        fakeVideoPlatform.dataSources.single.uri,
        'http://localhost:3000/api/fs/blob?path=%2Fworkspace%2Fclips%2Fdemo.mp4',
      );
      expect(fakeVideoPlatform.dataSources.single.httpHeaders, <String, String>{
        'Authorization': 'Bearer token',
      });

      await tester.tap(
        find.descendant(
          of: find.byType(IconButton),
          matching: find.byIcon(AppIcons.play_arrow_rounded),
        ),
      );
      await tester.pump();

      expect(fakeVideoPlatform.calls.contains('play'), isTrue);
    },
  );

  testWidgets(
    'file viewer auto-opens audio previews from the authenticated blob url',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: const FsFile(
          path: '/workspace/audio/theme.m4a',
          size: 6144,
          binary: true,
          truncated: false,
          modifiedAtMs: 0,
          mimeHint: 'audio/mp4',
          encoding: 'none',
          contents: '',
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/audio/theme.m4a',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Audio preview'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
      expect(find.text('00:12'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(
        fakeVideoPlatform.dataSources.single.uri,
        'http://localhost:3000/api/fs/blob?path=%2Fworkspace%2Faudio%2Ftheme.m4a',
      );
      expect(fakeVideoPlatform.dataSources.single.httpHeaders, <String, String>{
        'Authorization': 'Bearer token',
      });

      await tester.tap(
        find.descendant(
          of: find.byType(IconButton),
          matching: find.byIcon(AppIcons.play_circle_fill_rounded),
        ),
      );
      await tester.pump();

      expect(fakeVideoPlatform.calls.contains('play'), isTrue);

      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged?.call(6000);
      await tester.pump();
      slider.onChangeEnd?.call(6000);
      await tester.pump();

      expect(
        fakeVideoPlatform.seekPositions.single,
        const Duration(seconds: 6),
      );
    },
  );

  testWidgets(
    'file viewer auto-opens PDF previews from authenticated blob bytes',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: const FsFile(
          path: '/workspace/docs/guide.pdf',
          size: 32768,
          binary: true,
          truncated: false,
          modifiedAtMs: 0,
          mimeHint: 'application/pdf',
          encoding: 'none',
          contents: '',
        ),
        blobBytes: Uint8List.fromList(List<int>.generate(32, (index) => index)),
      );
      late PdfViewerPanePreviewData capturedPreviewData;

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/docs/guide.pdf',
            pdfViewerBuilder: (context, data) {
              capturedPreviewData = data;
              return const Center(child: Text('PDF preview ready'));
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('PDF preview ready'), findsOneWidget);
      expect(api.fetchFsBlobCalls, 1);
      expect(api.lastFetchFsBlobPath, '/workspace/docs/guide.pdf');
      expect(capturedPreviewData.bytes, hasLength(32));
      expect(capturedPreviewData.sourceName, '/workspace/docs/guide.pdf');
    },
  );

  testWidgets(
    'file viewer auto-opens zip previews and can return to binary summary',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: const FsFile(
          path: '/workspace/build/artifacts.zip',
          size: 2048,
          binary: true,
          truncated: false,
          modifiedAtMs: 0,
          mimeHint: 'application/zip',
          encoding: 'none',
          contents: '',
        ),
        blobBytes: _buildZipBytes(),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/build/artifacts.zip',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('ZIP contents'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('assets/'), findsOneWidget);
      expect(find.text('docs/guide.md'), findsOneWidget);
      expect(api.blobFetchPaths, <String>['/workspace/build/artifacts.zip']);

      await tester.tap(_appBarAction(AppIcons.description_rounded));
      await tester.pumpAndSettle();

      expect(find.text('ZIP archive'), findsOneWidget);
      expect(
        find.textContaining('Use Preview archive to list its contents.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'file viewer shows archive skip state directly for oversized zip files',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: const FsFile(
          path: '/workspace/build/huge.zip',
          size: archivePreviewMaxArchiveBytes + 1,
          binary: true,
          truncated: false,
          modifiedAtMs: 0,
          mimeHint: 'application/zip',
          encoding: 'none',
          contents: '',
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/build/huge.zip',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Archive preview skipped'), findsOneWidget);
      expect(find.textContaining('archives up to 16.0 MiB'), findsOneWidget);
      expect(api.blobFetchPaths, isEmpty);
    },
  );

  testWidgets(
    'file viewer auto-opens structured JSON previews and can return to raw text',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: _textFile(
          path: '/workspace/config/services.json',
          mimeHint: 'application/json',
          contents:
              '{'
              '"meta":{"enabled":true,"retries":3},'
              '"services":[{"name":"api","port":8080}]}',
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/config/services.json',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('JSON structure'), findsOneWidget);
      expect(find.byType(SyntaxCodeBlock), findsNothing);
      expect(find.text('services'), findsOneWidget);

      await tester.tap(find.text('services'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('[0]'));
      await tester.pumpAndSettle();

      expect(find.text('name'), findsOneWidget);
      expect(find.text('api'), findsOneWidget);
      expect(find.text('port'), findsOneWidget);
      expect(find.text('8080'), findsOneWidget);

      await tester.tap(_appBarAction(AppIcons.description_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(SyntaxCodeBlock), findsOneWidget);
    },
  );

  testWidgets(
    'file viewer auto-opens structured YAML previews for nested documents',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: _textFile(
          path: '/workspace/config/deploy.yaml',
          mimeHint: 'text/yaml',
          contents:
              'env:\n'
              '  production:\n'
              '    replicas: 3\n'
              '    regions:\n'
              '      - iad\n'
              '      - sfo\n',
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/config/deploy.yaml',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('YAML structure'), findsOneWidget);
      expect(find.text('env'), findsOneWidget);

      await tester.tap(find.text('env'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('production'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('regions'));
      await tester.pumpAndSettle();

      expect(find.text('replicas'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('iad'), findsOneWidget);
      expect(find.text('sfo'), findsOneWidget);
    },
  );

  testWidgets(
    'file viewer shows structured parse errors directly without crashing',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: _textFile(
          path: '/workspace/config/broken.json',
          mimeHint: 'application/json',
          contents: '{"items": [1, 2, }',
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/config/broken.json',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Could not parse JSON'), findsOneWidget);
      expect(
        find.textContaining('The raw text view is still available.'),
        findsOneWidget,
      );

      await tester.tap(_appBarAction(AppIcons.description_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(SyntaxCodeBlock), findsOneWidget);
    },
  );

  testWidgets(
    'file viewer auto-opens CSV files in table preview and can return to raw text',
    (tester) async {
      final api = _FakeFileViewerApi(
        file: _textFile(
          path: '/workspace/reports/demo.csv',
          mimeHint: 'text/csv',
          contents:
              'name,notes,count\n'
              'alpha,"ready now and waiting for approval from multiple reviewers before this row is considered complete for the preview widget to clip safely",3\n'
              'beta,missing\n',
        ),
      );

      await tester.pumpWidget(
        _buildTestApp(
          FileViewerScreen(
            host: _host,
            api: api,
            path: '/workspace/reports/demo.csv',
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(Table), findsOneWidget);
      expect(find.text('CSV'), findsOneWidget);
      expect(find.text('3 rows'), findsOneWidget);
      expect(find.text('3 columns'), findsOneWidget);
      expect(find.text('Uneven rows'), findsOneWidget);
      expect(
        find.textContaining('Rows have different column counts'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Long cells are clipped in table view.'),
        findsOneWidget,
      );
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('missing'), findsOneWidget);
      expect(find.textContaining('name,notes,count'), findsNothing);

      await tester.tap(_appBarAction(AppIcons.description_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(Table), findsNothing);
      expect(find.textContaining('name,notes,count'), findsOneWidget);
    },
  );
}

Finder _appBarAction(IconData icon) {
  return find.descendant(of: find.byType(AppBar), matching: find.byIcon(icon));
}

Widget _buildTestApp(Widget home) {
  return MaterialApp(
    theme: buildDarkTheme(ThemeVariant.codexAmber.dark),
    home: TooltipVisibility(visible: false, child: home),
  );
}

const HostProfile _host = HostProfile(
  id: 'host-1',
  label: 'Local',
  baseUrl: 'http://localhost:3000',
  token: 'token',
);

FsFile _textFile({
  required String path,
  required String contents,
  required String mimeHint,
}) {
  return FsFile(
    path: path,
    size: contents.length,
    binary: false,
    truncated: false,
    modifiedAtMs: 0,
    mimeHint: mimeHint,
    encoding: 'utf8',
    contents: contents,
  );
}

class _FakeFileViewerApi extends ApiClient {
  _FakeFileViewerApi({required this.file, this.blobBytes});

  final FsFile file;
  final Uint8List? blobBytes;
  final List<String> blobFetchPaths = <String>[];
  int fetchFsBlobCalls = 0;
  String? lastFetchFsBlobPath;

  @override
  Future<FsFile> readFile(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    return file;
  }

  @override
  Uri fsBlobUri(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) {
    return Uri.http('localhost:3000', '/api/fs/blob', <String, String>{
      'path': path,
    });
  }

  @override
  Future<Uint8List> fetchFsBlob(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    fetchFsBlobCalls += 1;
    lastFetchFsBlobPath = path;
    blobFetchPaths.add(path);
    if (blobBytes == null) {
      throw StateError('Missing fake blob bytes for $path');
    }
    return blobBytes!;
  }

  @override
  Map<String, String> authHeaders(HostProfile host) {
    return <String, String>{'Authorization': 'Bearer ${host.token}'};
  }
}

Uint8List _buildZipBytes() {
  final archive = Archive()
    ..addFile(ArchiveFile('assets/', 0, const <int>[])..isFile = false)
    ..addFile(ArchiveFile.string('README.md', 'hello zip!'))
    ..addFile(ArchiveFile.string('docs/guide.md', 'guide contents'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<String> calls = <String>[];
  final List<DataSource> dataSources = <DataSource>[];
  final Map<int, Stream<VideoEvent>> streams = <int, Stream<VideoEvent>>{};
  final List<Duration> seekPositions = <Duration>[];
  Duration currentPosition = Duration.zero;
  int nextPlayerId = 0;

  @override
  Future<void> init() async {
    calls.add('init');
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('createWithOptions');
    dataSources.add(options.dataSource);
    final playerId = nextPlayerId++;
    streams[playerId] = Stream<VideoEvent>.value(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 12),
        size: const Size(1920, 1080),
      ),
    );
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return streams[playerId]!;
  }

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seekTo');
    seekPositions.add(position);
    currentPosition = position;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    calls.add('setLooping');
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('setVolume');
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    calls.add('setPlaybackSpeed');
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    calls.add('getPosition');
    return currentPosition;
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {
    calls.add('setMixWithOthers');
  }

  @override
  Widget buildView(int playerId) {
    return Texture(textureId: playerId);
  }
}
