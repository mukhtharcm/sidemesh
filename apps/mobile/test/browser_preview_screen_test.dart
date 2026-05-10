import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/browser_preview_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  testWidgets('browser preview renders a live network tab and detail sheet', (
    tester,
  ) async {
    final api = _BrowserPreviewFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      BrowserPreviewScreen(
        host: _host(),
        api: api,
        preview: _preview(),
      ),
      size: const Size(1180, 900),
    );

    api.emit({
      'type': 'hello',
      'preview': _previewJson(),
    });
    api.emit({
      'type': 'frame',
      'data':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn6zk8AAAAASUVORK5CYII=',
      'width': 390,
      'height': 844,
    });
    await _pumpFrames(tester);

    await tester.tap(find.byIcon(Icons.construction_outlined));
    await _pumpFrames(tester);
    await tester.tap(find.text('Network'));
    await _pumpFrames(tester);

    api.emit({
      'type': 'networkSnapshot',
      'entries': [
        {
          'requestId': 'request-1',
          'url': 'http://127.0.0.1:3000/assets/main.js',
          'method': 'GET',
          'resourceType': 'Script',
          'status': 200,
          'mimeType': 'text/javascript',
          'encodedDataLength': 2048,
          'durationMs': 31,
          'startedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
      ],
    });
    await _pumpFrames(tester);

    expect(find.text('main.js'), findsOneWidget);
    expect(find.text('200'), findsOneWidget);

    await tester.tap(find.text('main.js'));
    await _pumpFrames(tester);

    expect(api.sentMessages.last['type'], 'networkDetailRequest');
    expect(api.sentMessages.last['requestId'], 'request-1');

    api.emit({
      'type': 'networkDetail',
      'requestId': 'request-1',
      'detail': {
        'requestId': 'request-1',
        'url': 'http://127.0.0.1:3000/assets/main.js',
        'method': 'GET',
        'resourceType': 'Script',
        'status': 200,
        'statusText': 'OK',
        'mimeType': 'text/javascript',
        'encodedDataLength': 2048,
        'durationMs': 31,
        'startedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'errorText': null,
        'finished': true,
        'failed': false,
        'servedFromCache': false,
        'requestHeaders': {'accept': '*/*'},
        'responseHeaders': {'content-type': 'text/javascript'},
        'body': 'console.log("network ok")',
        'bodyBase64Encoded': false,
        'bodyError': null,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Request headers'), findsOneWidget);
    expect(find.text('Response body'), findsOneWidget);
    expect(find.textContaining('network ok'), findsOneWidget);
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpApp(
  WidgetTester tester,
  Widget child, {
  required Size size,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      home: TooltipVisibility(visible: false, child: child),
    ),
  );
}

HostProfile _host() => HostProfile(
  id: 'browser-preview-network-test',
  label: 'Fake Host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

Map<String, Object?> _previewJson() => <String, Object?>{
  'id': 'preview-1',
  'label': 'Preview',
  'url': 'http://127.0.0.1:3000/',
  'targetHost': '127.0.0.1',
  'targetPort': 3000,
  'scheme': 'http',
  'cwd': '/repo',
  'sessionId': 'session-1',
  'profileMode': 'temporary',
  'status': 'running',
  'width': 390,
  'height': 844,
  'clients': 1,
  'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'updatedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastClientAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastFrameAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastError': null,
};

HostBrowserPreviewInfo _preview() => HostBrowserPreviewInfo(
  id: 'preview-1',
  label: 'Preview',
  url: 'http://127.0.0.1:3000/',
  targetHost: '127.0.0.1',
  targetPort: 3000,
  scheme: 'http',
  cwd: '/repo',
  sessionId: 'session-1',
  profileMode: 'temporary',
  status: 'running',
  width: 390,
  height: 844,
  clients: 1,
  createdAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastClientAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastFrameAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastError: null,
);

class _BrowserPreviewFakeApi extends ApiClient {
  final _ControllableWebSocketChannel _channel = _ControllableWebSocketChannel();
  final List<Map<String, dynamic>> sentMessages = <Map<String, dynamic>>[];
  StreamSubscription<dynamic>? _outgoingSubscription;

  _BrowserPreviewFakeApi() {
    _outgoingSubscription = _channel.outgoing.listen((message) {
      if (message is String) {
        sentMessages.add(jsonDecode(message) as Map<String, dynamic>);
      }
    });
  }

  @override
  WebSocketChannel openBrowserPreviewLive(HostProfile host, String previewId) =>
      _channel;

  void emit(Map<String, Object?> event) {
    _channel.emit(jsonEncode(event));
  }

  void dispose() {
    unawaited(_outgoingSubscription?.cancel());
    _channel.dispose();
  }
}

class _ControllableWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  Stream<dynamic> get outgoing => _outgoing.stream;

  @override
  WebSocketSink get sink => _TestWebSocketSink(_outgoing.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  void emit(String raw) {
    _incoming.add(raw);
  }

  void dispose() {
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
  }
}

class _TestWebSocketSink implements WebSocketSink {
  _TestWebSocketSink(this._delegate);

  final StreamSink<dynamic> _delegate;

  @override
  Future<void> addStream(Stream<dynamic> stream) => _delegate.addStream(stream);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _delegate.close();

  @override
  Future<void> get done => _delegate.done;

  @override
  void add(dynamic data) => _delegate.add(data);
}
