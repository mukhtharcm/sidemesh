import 'dart:async';
import 'dart:convert';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/terminal_screen.dart';
import 'package:sidemesh_mobile/src/widgets/terminal_keybar.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

class _UnavailableApi extends ApiClient {
  @override
  Future<List<HostTerminalInfo>> fetchTerminals(HostProfile host) async =>
      throw StateError('Terminal unavailable');
}

void main() {
  testWidgets('connection waits for hello and stop is in menu', (tester) async {
    final api = _LiveApi();
    await tester.pumpWidget(
      MaterialApp(
        home: TerminalScreen(
          host: const HostProfile(
            id: 'live-test',
            label: 'Test',
            baseUrl: 'http://localhost',
            token: 'test',
          ),
          api: api,
          cwd: '/',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Connecting…'), findsOneWidget);
    final top = tester.getTopLeft(find.byType(TerminalView));
    api.channel.emit(jsonEncode({'type': 'hello', 'terminal': _running}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Connecting…'), findsNothing);
    expect(tester.getTopLeft(find.byType(TerminalView)), top);
    expect(find.text('Stop terminal'), findsNothing);
    await tester.tap(find.byTooltip('Terminal actions'));
    await tester.pumpAndSettle();
    expect(find.text('Stop terminal'), findsOneWidget);
    expect(find.byTooltip('Start a new terminal'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.channel.dispose();
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    for (final dark in [false, true]) {
      testWidgets('terminal controls and output: $platform, dark=$dark', (
        tester,
      ) async {
        var closed = false;
        final palette = ThemeVariant.codexAmber;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark
                ? buildDarkTheme(palette.dark, platform: platform)
                : buildLightTheme(palette.light, platform: platform),
            home: TerminalScreen(
              host: const HostProfile(
                id: 'terminal-test',
                label: 'Test',
                baseUrl: 'http://localhost',
                token: 'test',
              ),
              api: _UnavailableApi(),
              cwd: '/',
              onClose: () => closed = true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(TerminalKeyBar),
          platform == TargetPlatform.iOS ? findsOneWidget : findsNothing,
        );
        final terminal = tester
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal;
        expect(terminal.buffer.lines[0].getText().trim(), isEmpty);
        expect(find.byTooltip('Start a new terminal'), findsOneWidget);
        await tester.tap(find.byTooltip('Back to machine'));
        expect(closed, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

const _running = <String, Object?>{
  'id': 'term',
  'title': 'Shell',
  'cwd': '/',
  'status': 'running',
  'backend': 'direct-pty',
  'shell': '/bin/sh',
};

class _LiveApi extends ApiClient {
  final channel = _ControllableWebSocketChannel();
  @override
  Future<List<HostTerminalInfo>> fetchTerminals(HostProfile host) async => [
    HostTerminalInfo.fromJson(_running),
  ];
  @override
  WebSocketChannel openTerminalLive(
    HostProfile host,
    String terminalId, {
    int since = -1,
  }) => channel;
}

class _ControllableWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _incoming.stream;

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
