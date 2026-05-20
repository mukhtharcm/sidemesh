import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/fs_models.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/file_viewer_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

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
    'file viewer opens video previews from the authenticated blob url',
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

      expect(find.text('Video file'), findsOneWidget);
      expect(find.textContaining('Use Play video to open it.'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.play_circle_outline_rounded),
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
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
      );
      await tester.pump();

      expect(fakeVideoPlatform.calls.contains('play'), isTrue);
    },
  );
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

class _FakeFileViewerApi extends ApiClient {
  _FakeFileViewerApi({required this.file});

  final FsFile file;

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
  Map<String, String> authHeaders(HostProfile host) {
    return <String, String>{'Authorization': 'Bearer ${host.token}'};
  }
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<String> calls = <String>[];
  final List<DataSource> dataSources = <DataSource>[];
  final Map<int, Stream<VideoEvent>> streams = <int, Stream<VideoEvent>>{};
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
    return Duration.zero;
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
