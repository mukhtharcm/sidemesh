import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/port_forward_bridge.dart';

void main() {
  test('builds a parseable HTTP error response for failed HTTP forwards', () {
    final response = utf8.decode(
      buildPortForwardHttpErrorResponse('target connection failed'),
    );
    final parts = response.split('\r\n\r\n');

    expect(parts, hasLength(2));
    expect(parts.first, startsWith('HTTP/1.1 502 Bad Gateway\r\n'));
    expect(parts.first, contains('Content-Type: text/plain; charset=utf-8'));
    expect(parts.first, contains('Connection: close'));
    expect(
      parts.last,
      'Sidemesh port forward error: target connection failed\n',
    );

    final contentLengthHeader = parts.first
        .split('\r\n')
        .firstWhere((line) => line.startsWith('Content-Length: '));
    final contentLength = int.parse(
      contentLengthHeader.substring('Content-Length: '.length),
    );

    expect(contentLength, utf8.encode(parts.last).length);
  });
}
