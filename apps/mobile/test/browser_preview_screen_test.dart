import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/browser_preview_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  setUp(() {
    _installClipboardMock();
  });

  tearDown(() {
    _clearClipboardMock();
  });

  testWidgets(
    'browser preview keeps cleared console rows hidden across reconnect snapshots',
    (tester) async {
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

      api.emit({'type': 'hello', 'preview': _previewJson()});
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

      api.emit({
        'type': 'consoleSnapshot',
        'entries': [
          {
            'seq': 1,
            'type': 'console',
            'level': 'log',
            'text': 'first log',
            'timestamp': DateTime(2026, 1, 1).millisecondsSinceEpoch,
          },
        ],
      });
      await _pumpFrames(tester);
      expect(find.text('first log'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await _pumpFrames(tester);
      expect(find.text('first log'), findsNothing);

      api.emit({
        'type': 'consoleSnapshot',
        'entries': [
          {
            'seq': 1,
            'type': 'console',
            'level': 'log',
            'text': 'first log',
            'timestamp': DateTime(2026, 1, 1).millisecondsSinceEpoch,
          },
          {
            'seq': 2,
            'type': 'console',
            'level': 'info',
            'text': 'second log',
            'timestamp': DateTime(2026, 1, 1, 0, 0, 1).millisecondsSinceEpoch,
          },
        ],
      });
      await _pumpFrames(tester);

      expect(find.text('first log'), findsNothing);
      expect(find.text('second log'), findsOneWidget);
    },
  );

  testWidgets('browser preview auto-resizes the remote viewport when enabled', (
    tester,
  ) async {
    final api = _BrowserPreviewFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      Scaffold(
        body: BrowserPreviewPane(
          host: _host(),
          api: api,
          preview: _preview(),
          showHeader: false,
          autoResizeViewport: true,
        ),
      ),
      size: const Size(1180, 900),
    );

    await _pumpFrames(tester);
    expect(
      api.sentMessages.where((message) => message['type'] == 'resize'),
      isEmpty,
    );

    api.emit({'type': 'hello', 'preview': _previewJson()});
    await _pumpFrames(tester);

    expect(
      api.sentMessages,
      contains(
        containsPair('type', 'resize'),
      ),
    );
    expect(api.sentMessages.last['width'], 1180);
    expect(api.sentMessages.last['height'] as int, greaterThan(700));
  });

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
          'method': 'POST',
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
        'method': 'POST',
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
        'requestHeaders': {
          'accept': '*/*',
          'content-type': 'application/json',
        },
        'responseHeaders': {'content-type': 'text/javascript'},
        'requestBody': '{"query":"network ok"}',
        'requestBodyError': null,
        'body': 'console.log("network ok")',
        'bodyBase64Encoded': false,
        'bodyError': null,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Request headers'), findsOneWidget);
    expect(find.text('Request body'), findsOneWidget);
    expect(find.text('Response body'), findsOneWidget);
    expect(find.textContaining('network ok'), findsWidgets);

    await tester.tap(find.byIcon(Icons.copy_all_rounded));
    await _pumpFrames(tester);
    await tester.tap(find.text('Copy as cURL'));
    await _pumpFrames(tester);

    final clipboard = await Clipboard.getData('text/plain');
    expect(clipboard?.text, contains('curl'));
    expect(clipboard?.text, contains('--data-raw'));
    expect(clipboard?.text, contains('assets/main.js'));
  });

  testWidgets('browser preview renders websocket detail and ws filter', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
          'requestId': 'socket-1',
          'url': 'ws://127.0.0.1:3000/socket',
          'method': 'GET',
          'resourceType': 'WebSocket',
          'status': 101,
          'mimeType': null,
          'encodedDataLength': null,
          'durationMs': 120,
          'startedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
          'webSocketMessageCount': 2,
        },
        {
          'requestId': 'request-1',
          'url': 'http://127.0.0.1:3000/assets/main.js',
          'method': 'GET',
          'resourceType': 'Script',
          'status': 200,
          'mimeType': 'text/javascript',
          'encodedDataLength': 2048,
          'durationMs': 31,
          'startedAt': DateTime(2026, 1, 1, 0, 0, 1).millisecondsSinceEpoch,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
      ],
    });
    await _pumpFrames(tester);

    expect(find.text('socket'), findsOneWidget);
    expect(find.text('main.js'), findsOneWidget);
    expect(find.textContaining('2 msgs'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'WS'));
    await _pumpFrames(tester);
    expect(find.text('socket'), findsOneWidget);
    expect(find.text('main.js'), findsNothing);

    await tester.tap(find.text('socket'));
    await _pumpFrames(tester);
    expect(api.sentMessages.last['type'], 'networkDetailRequest');
    expect(api.sentMessages.last['requestId'], 'socket-1');

    api.emit({
      'type': 'networkDetail',
      'requestId': 'socket-1',
      'detail': {
        'requestId': 'socket-1',
        'url': 'ws://127.0.0.1:3000/socket',
        'method': 'GET',
        'resourceType': 'WebSocket',
        'status': 101,
        'statusText': 'Switching Protocols',
        'mimeType': null,
        'encodedDataLength': null,
        'durationMs': 120,
        'startedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'errorText': null,
        'finished': true,
        'failed': false,
        'servedFromCache': false,
        'requestHeaders': {
          'upgrade': 'websocket',
        },
        'responseHeaders': {
          'upgrade': 'websocket',
        },
        'requestBody': null,
        'requestBodyError': null,
        'body': null,
        'bodyBase64Encoded': false,
        'bodyError': null,
        'webSocketMessages': [
          {
            'direction': 'sent',
            'timestamp': DateTime(2026, 1, 1).millisecondsSinceEpoch,
            'opcode': 1,
            'payload': 'ping',
            'base64Encoded': false,
            'error': null,
          },
          {
            'direction': 'received',
            'timestamp': DateTime(2026, 1, 1, 0, 0, 1).millisecondsSinceEpoch,
            'opcode': 1,
            'payload': 'pong',
            'base64Encoded': false,
            'error': null,
          },
        ],
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('ping'), findsOneWidget);
    expect(find.text('pong'), findsOneWidget);
    expect(find.text('Response body'), findsNothing);
  });

  testWidgets('browser preview renders storage snapshots and refreshes them', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
    await tester.tap(find.text('Storage'));
    await _pumpFrames(tester);

    expect(api.sentMessages.last['type'], 'storageRefreshRequest');

    api.emit({
      'type': 'storageSnapshot',
      'snapshot': {
        'url': 'http://127.0.0.1:3000/app',
        'origin': 'http://127.0.0.1:3000',
        'refreshedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'cookies': [
          {
            'name': 'sid',
            'value': 'abc123',
            'domain': '127.0.0.1',
            'path': '/',
            'expires': null,
            'size': 9,
            'httpOnly': true,
            'secure': false,
            'session': true,
            'sameSite': 'Lax',
          },
        ],
        'indexedDbDatabases': [
          {
            'name': 'app-cache',
            'version': 3,
            'objectStores': [
              {
                'name': 'items',
                'keyPath': 'id',
                'autoIncrement': false,
                'indexes': [
                  {
                    'name': 'byUpdatedAt',
                    'keyPath': 'updatedAt',
                    'unique': false,
                    'multiEntry': false,
                  },
                ],
              },
            ],
          },
        ],
        'localStorage': [
          {
            'key': 'theme',
            'value': 'amber',
          },
        ],
        'sessionStorage': [
          {
            'key': 'draft',
            'value': '42',
          },
        ],
        'usage': 2048,
        'quota': 10485760,
        'usageBreakdown': [
          {'storageType': 'indexeddb', 'usage': 1536},
          {'storageType': 'local_storage', 'usage': 512},
        ],
        'warnings': [],
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Cookies'), findsWidgets);
    expect(find.text('IndexedDB'), findsWidgets);
    expect(find.text('localStorage'), findsWidgets);
    expect(find.text('sessionStorage'), findsWidgets);
    expect(find.text('Usage breakdown'), findsOneWidget);
    expect(find.text('app-cache'), findsOneWidget);
    expect(find.textContaining('10.0 MB'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('sid'),
      find.byKey(const ValueKey('browserPreviewStorageList')),
      const Offset(0, -200),
    );
    await _pumpFrames(tester);
    expect(find.text('sid'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('theme'),
      find.byKey(const ValueKey('browserPreviewStorageList')),
      const Offset(0, -200),
    );
    await _pumpFrames(tester);
    expect(find.text('theme'), findsOneWidget);
    expect(find.text('amber'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('draft'),
      find.byKey(const ValueKey('browserPreviewStorageList')),
      const Offset(0, -200),
    );
    await _pumpFrames(tester);
    expect(find.text('draft'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('browserPreviewStorageRefreshButton')),
    );
    await _pumpFrames(tester);
    expect(api.sentMessages.last['type'], 'storageRefreshRequest');

    await tester.tap(find.text('Network'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Storage'));
    await _pumpFrames(tester);
    expect(api.sentMessages.last['type'], 'storageRefreshRequest');
  });

  testWidgets('browser preview storage actions send mutation messages', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
    api.emit({
      'type': 'frame',
      'data':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Y0/8AAAAASUVORK5CYII=',
      'width': 390,
      'height': 844,
    });
    await _pumpFrames(tester);

    await tester.tap(find.byIcon(Icons.construction_outlined));
    await _pumpFrames(tester);
    await tester.tap(find.text('Storage'));
    await _pumpFrames(tester);

    api.emit({
      'type': 'storageSnapshot',
      'snapshot': {
        'url': 'http://127.0.0.1:3000/app',
        'origin': 'http://127.0.0.1:3000',
        'refreshedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'cookies': [
          {
            'name': 'sid',
            'value': 'abc123',
            'domain': '127.0.0.1',
            'path': '/',
            'expires': null,
            'size': 9,
            'httpOnly': true,
            'secure': false,
            'session': true,
            'sameSite': 'Lax',
          },
        ],
        'indexedDbDatabases': const [],
        'localStorage': [
          {
            'key': 'theme',
            'value': 'amber',
          },
        ],
        'sessionStorage': [],
        'usage': 2048,
        'quota': 10485760,
        'usageBreakdown': const [],
        'warnings': const [],
      },
    });
    await _pumpFrames(tester);

    await tester.dragUntilVisible(
      find.byKey(const ValueKey('browserPreviewStorageAdd-localStorage')),
      find.byKey(const ValueKey('browserPreviewStorageList')),
      const Offset(0, -200),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey('browserPreviewStorageAdd-localStorage')),
    );
    await _pumpFrames(tester);
    final dialogFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogFields.at(0), 'accent');
    await tester.enterText(dialogFields.at(1), 'orange');
    await tester.tap(find.text('Save'));
    await _pumpFrames(tester);

    expect(api.sentMessages.last, {
      'type': 'storageSetEntry',
      'area': 'localStorage',
      'key': 'accent',
      'value': 'orange',
    });

    await tester.dragUntilVisible(
      find.byKey(const ValueKey('browserPreviewStorageClear-cookies')),
      find.byKey(const ValueKey('browserPreviewStorageList')),
      const Offset(0, 200),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey('browserPreviewStorageClear-cookies')),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('Clear'));
    await _pumpFrames(tester);

    expect(api.sentMessages.last, {
      'type': 'storageClearCookies',
    });
  });

  testWidgets('browser preview renders inspector snapshots and selects tree nodes', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
    await tester.tap(find.text('Inspector'));
    await _pumpFrames(tester);

    expect(api.sentMessages.last['type'], 'inspectorSnapshotRequest');

    api.emit({
      'type': 'inspectorSnapshot',
      'snapshot': {
        'url': 'http://127.0.0.1:3000/app',
        'refreshedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'selectedPath': [0, 0],
        'treeRoot': {
          'path': const [],
          'nodeName': 'html',
          'selector': 'html',
          'textPreview': null,
          'childElementCount': 1,
          'isSelected': false,
          'truncatedChildren': false,
          'children': [
            {
              'path': [0],
              'nodeName': 'body',
              'selector': 'body',
              'textPreview': null,
              'childElementCount': 2,
              'isSelected': false,
              'truncatedChildren': false,
              'children': [
                {
                  'path': [0, 0],
                  'nodeName': 'main',
                  'selector': 'main#app.shell',
                  'textPreview': 'Ship faster',
                  'childElementCount': 0,
                  'isSelected': true,
                  'truncatedChildren': false,
                  'children': const [],
                },
                {
                  'path': [0, 1],
                  'nodeName': 'button',
                  'selector': 'button.cta',
                  'textPreview': 'Deploy',
                  'childElementCount': 0,
                  'isSelected': false,
                  'truncatedChildren': false,
                  'children': const [],
                },
              ],
            },
          ],
        },
        'selectedNode': {
          'path': [0, 0],
          'nodeName': 'main',
          'selector': 'main#app.shell',
          'textPreview': 'Ship faster',
          'childElementCount': 0,
          'isSelected': true,
          'truncatedChildren': false,
          'children': const [],
          'attributes': [
            {'name': 'id', 'value': 'app'},
          ],
          'computedStyles': [
            {'name': 'display', 'value': 'block'},
          ],
          'inlineStyles': [
            {'name': 'color', 'value': 'red'},
          ],
          'box': {
            'x': 20,
            'y': 80,
            'width': 320,
            'height': 200,
          },
        },
        'warnings': const [],
      },
    });
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('browserPreviewInspectorList')),
      findsOneWidget,
    );
    expect(find.text('main#app.shell'), findsWidgets);
    await tester.dragUntilVisible(
      find.text('Computed styles'),
      find.byKey(const ValueKey('browserPreviewInspectorList')),
      const Offset(0, -220),
    );
    await _pumpFrames(tester);
    expect(find.text('Computed styles'), findsOneWidget);
    expect(find.text('display'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('button.cta'),
      find.byKey(const ValueKey('browserPreviewInspectorList')),
      const Offset(0, 220),
    );
    await _pumpFrames(tester);
    expect(find.text('button.cta'), findsOneWidget);

    await tester.tap(find.text('button.cta'));
    await _pumpFrames(tester);

    expect(api.sentMessages.last, {
      'type': 'inspectorSelectPath',
      'path': [0, 1],
    });

    await tester.tap(find.text('Network'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Inspector'));
    await _pumpFrames(tester);

    expect(api.sentMessages.last['type'], 'inspectorSnapshotRequest');
  });

  testWidgets('browser preview inspector pick mode sends inspect-point messages', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
    await tester.tap(find.text('Inspector'));
    await _pumpFrames(tester);

    api.emit({
      'type': 'inspectorSnapshot',
      'snapshot': {
        'url': 'http://127.0.0.1:3000/app',
        'refreshedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'selectedPath': [0],
        'treeRoot': {
          'path': const [],
          'nodeName': 'html',
          'selector': 'html',
          'textPreview': null,
          'childElementCount': 1,
          'isSelected': false,
          'truncatedChildren': false,
          'children': const [],
        },
        'selectedNode': {
          'path': [0],
          'nodeName': 'body',
          'selector': 'body',
          'textPreview': null,
          'childElementCount': 0,
          'isSelected': true,
          'truncatedChildren': false,
          'children': const [],
          'attributes': const [],
          'computedStyles': const [],
          'inlineStyles': const [],
          'box': {
            'x': 0,
            'y': 0,
            'width': 390,
            'height': 844,
          },
        },
        'warnings': const [],
      },
    });
    await _pumpFrames(tester);

    await tester.tap(
      find.byKey(const ValueKey('browserPreviewInspectorPickButton')),
    );
    await _pumpFrames(tester);
    expect(
      find.text('Tap the page preview to inspect an element'),
      findsOneWidget,
    );

    final previewRect = tester.getRect(
      find.byKey(const ValueKey('browserPreviewCanvas')),
    );
    await tester.tapAt(previewRect.center);
    await _pumpFrames(tester);

    expect(api.sentMessages.last['type'], 'inspectorInspectPoint');
    expect(
      (api.sentMessages.last['x'] as num).toDouble(),
      closeTo(0.5, 0.000001),
    );
    expect(
      (api.sentMessages.last['y'] as num).toDouble(),
      closeTo(0.5, 0.000001),
    );
  });

  testWidgets('browser preview network tab supports search and sort', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
          'encodedDataLength': 4096,
          'durationMs': 80,
          'startedAt': DateTime(2026, 1, 1, 0, 0, 2).millisecondsSinceEpoch,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
        {
          'requestId': 'request-2',
          'url': 'http://127.0.0.1:3000/assets/site.css',
          'method': 'GET',
          'resourceType': 'Stylesheet',
          'status': 200,
          'mimeType': 'text/css',
          'encodedDataLength': 512,
          'durationMs': 12,
          'startedAt': DateTime(2026, 1, 1, 0, 0, 1).millisecondsSinceEpoch,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
      ],
    });
    await _pumpFrames(tester);

    final searchField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Search requests',
    );
    await tester.enterText(searchField, 'site');
    await _pumpFrames(tester);

    expect(find.text('site.css'), findsOneWidget);
    expect(find.text('main.js'), findsNothing);

    await tester.enterText(searchField, '');
    await _pumpFrames(tester);

    await tester.tap(find.text('Newest'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Largest').last);
    await _pumpFrames(tester);

    expect(
      tester.getTopLeft(find.text('main.js')).dy,
      lessThan(tester.getTopLeft(find.text('site.css')).dy),
    );
  });

  testWidgets('browser preview replaces stale network rows from fresh snapshots', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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

    api.emit({
      'type': 'networkSnapshot',
      'entries': [
        {
          'requestId': 'request-2',
          'url': 'http://127.0.0.1:3000/assets/site.css',
          'method': 'GET',
          'resourceType': 'Stylesheet',
          'status': 200,
          'mimeType': 'text/css',
          'encodedDataLength': 512,
          'durationMs': 12,
          'startedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
      ],
    });
    await _pumpFrames(tester);

    expect(find.text('main.js'), findsNothing);
    expect(find.text('site.css'), findsOneWidget);
  });

  testWidgets('browser preview keeps cleared network rows hidden across reconnect snapshots', (
    tester,
  ) async {
    final api = _BrowserPreviewFakeApi();
    addTearDown(api.dispose);
    final startedAt = DateTime(2026, 1, 1).millisecondsSinceEpoch;

    await _pumpApp(
      tester,
      BrowserPreviewScreen(
        host: _host(),
        api: api,
        preview: _preview(),
      ),
      size: const Size(1180, 900),
    );

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
          'startedAt': startedAt,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
      ],
    });
    await _pumpFrames(tester);
    expect(find.text('main.js'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await _pumpFrames(tester);
    expect(find.text('main.js'), findsNothing);

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
          'startedAt': startedAt,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
      ],
    });
    await _pumpFrames(tester);
    expect(find.text('main.js'), findsNothing);

    api.emit({
      'type': 'network',
      'entry': {
        'requestId': 'request-2',
        'url': 'http://127.0.0.1:3000/assets/site.css',
        'method': 'GET',
        'resourceType': 'Stylesheet',
        'status': 200,
        'mimeType': 'text/css',
        'encodedDataLength': 512,
        'durationMs': 12,
        'startedAt': startedAt,
        'errorText': null,
        'finished': true,
        'failed': false,
        'servedFromCache': false,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('site.css'), findsOneWidget);
  });

  testWidgets('browser preview explains when network inspection is unavailable', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
      'type': 'networkStatus',
      'available': false,
      'message': 'Network inspection is unavailable: Network domain is not supported.',
    });
    await _pumpFrames(tester);

    expect(
      find.textContaining('Network inspection is unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('browser preview explains when network details are unavailable while paused', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
          'requestId': 'request-3',
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

    await tester.tap(find.byIcon(Icons.pause_circle_outline_rounded));
    await _pumpFrames(tester);
    await tester.tap(find.text('main.js'));
    await _pumpFrames(tester);

    expect(
      api.sentMessages.where((message) => message['type'] == 'networkDetailRequest'),
      isEmpty,
    );
    expect(
      find.textContaining('Viewer is disconnected. Resume the stream'),
      findsOneWidget,
    );
  });

  testWidgets('browser preview clears stale loading UI when hello resyncs after reconnect', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
    api.emit({
      'type': 'frame',
      'data':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn6zk8AAAAASUVORK5CYII=',
      'width': 390,
      'height': 844,
    });
    await _pumpFrames(tester);

    api.emit({'type': 'loading', 'state': 'started'});
    await _pumpFrames(tester);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    api.emit({'type': 'hello', 'preview': _previewJson()});
    await _pumpFrames(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('browser preview surfaces network detail fetch errors', (
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

    api.emit({'type': 'hello', 'preview': _previewJson()});
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
          'requestId': 'request-2',
          'url': 'http://127.0.0.1:3000/assets/site.css',
          'method': 'GET',
          'resourceType': 'Stylesheet',
          'status': 200,
          'mimeType': 'text/css',
          'encodedDataLength': 512,
          'durationMs': 12,
          'startedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
          'errorText': null,
          'finished': true,
          'failed': false,
          'servedFromCache': false,
        },
      ],
    });
    await _pumpFrames(tester);

    await tester.tap(find.text('site.css'));
    await _pumpFrames(tester);

    api.emit({
      'type': 'networkDetail',
      'requestId': 'request-2',
      'error': 'network request not found',
    });
    await _pumpFrames(tester);

    expect(find.textContaining('network request not found'), findsOneWidget);
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

HostBrowserPreviewInfo _preview({int clients = 1}) => HostBrowserPreviewInfo(
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
  clients: clients,
  createdAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastClientAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastFrameAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
  lastError: null,
);

String? _mockClipboardText;

void _installClipboardMock() {
  _mockClipboardText = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            final arguments = call.arguments;
            if (arguments is Map) {
              _mockClipboardText = arguments['text']?.toString();
            }
            return null;
          case 'Clipboard.getData':
            return <String, dynamic>{'text': _mockClipboardText};
          default:
            return null;
        }
      });
}

void _clearClipboardMock() {
  _mockClipboardText = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

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
