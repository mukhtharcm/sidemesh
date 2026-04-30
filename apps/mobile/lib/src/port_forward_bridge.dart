import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'models.dart';

class PortForwardBridge {
  PortForwardBridge({
    required this.host,
    required this.api,
    required this.portForward,
  });

  final HostProfile host;
  final ApiClient api;
  final HostPortForwardInfo portForward;

  ServerSocket? _server;
  final Set<_PortForwardConnection> _connections = {};
  bool _disposed = false;

  int? get localPort => _server?.port;

  Uri? get localUri {
    final port = localPort;
    if (port == null) return null;
    if (portForward.scheme == 'tcp') {
      return Uri(scheme: 'tcp', host: '127.0.0.1', port: port);
    }
    return Uri(
      scheme: portForward.scheme == 'https' ? 'https' : 'http',
      host: '127.0.0.1',
      port: port,
    );
  }

  Future<Uri> start() async {
    if (_disposed) {
      throw StateError('Port forward bridge has been disposed.');
    }
    if (_server == null) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_handleClient, onError: (_) {});
    }
    final uri = localUri;
    if (uri == null) {
      throw StateError('Local port was not assigned.');
    }
    return uri;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final connection in _connections.toList(growable: false)) {
      await connection.close();
    }
    _connections.clear();
    await _server?.close();
    _server = null;
  }

  void _handleClient(Socket client) {
    if (_disposed) {
      client.destroy();
      return;
    }
    final connection = _PortForwardConnection(
      client: client,
      channel: api.openPortForwardTunnel(host, portForward.id),
      onClose: (connection) => _connections.remove(connection),
    );
    _connections.add(connection);
    connection.start();
  }
}

class _PortForwardConnection {
  _PortForwardConnection({
    required this.client,
    required this.channel,
    required this.onClose,
  });

  final Socket client;
  final WebSocketChannel channel;
  final void Function(_PortForwardConnection connection) onClose;

  StreamSubscription<Uint8List>? _clientSub;
  StreamSubscription<dynamic>? _channelSub;
  bool _closed = false;

  void start() {
    _clientSub = client.listen(
      (data) => channel.sink.add(Uint8List.fromList(data)),
      onError: (_) => unawaited(close()),
      onDone: () => unawaited(close()),
      cancelOnError: true,
    );
    _clientSub?.pause();
    _channelSub = channel.stream.listen(
      (message) {
        if (_closed) return;
        if (message is Uint8List) {
          client.add(message);
        } else if (message is List<int>) {
          client.add(message);
        } else if (message is String) {
          final error = _errorFromControlFrame(message);
          if (error != null) {
            client.add(utf8.encode('Sidemesh port forward error: $error\n'));
            unawaited(close());
          }
        }
      },
      onError: (_) => unawaited(close()),
      onDone: () => unawaited(close()),
      cancelOnError: true,
    );
    unawaited(_resumeClientWhenReady());
  }

  Future<void> _resumeClientWhenReady() async {
    try {
      await channel.ready;
      if (!_closed) {
        _clientSub?.resume();
      }
    } catch (_) {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose(this);
    await _clientSub?.cancel();
    await _channelSub?.cancel();
    try {
      await channel.sink.close();
    } catch (_) {
      // noop
    }
    client.destroy();
  }
}

String? _errorFromControlFrame(String payload) {
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map && decoded['type'] == 'error') {
      final message = decoded['message'];
      return message is String ? message : 'unknown error';
    }
  } catch (_) {
    // Non-JSON text frames are ignored because the tunnel data itself is binary.
  }
  return null;
}
