import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/fs_models.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/inspector/inspector_file_browser.dart';

void main() {
  testWidgets(
    'workspace browser opens directly into a selected file and updates when selection changes',
    (tester) async {
      final api = _FakeWorkspaceApi(
        files: <String, String>{
          '/workspace/lib/main.dart': 'void main() => print("first file");',
          '/workspace/lib/other.dart': 'void other() => print("second file");',
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkspaceBrowserPane(
              host: _host,
              api: api,
              root: '/workspace',
              initialSelectedPath: '/workspace/lib/main.dart',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);
      expect(find.textContaining('first file'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkspaceBrowserPane(
              host: _host,
              api: api,
              root: '/workspace',
              initialSelectedPath: '/workspace/lib/other.dart',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('other.dart'), findsOneWidget);
      expect(find.textContaining('second file'), findsOneWidget);
      expect(api.readPaths, <String>[
        '/workspace/lib/main.dart',
        '/workspace/lib/other.dart',
      ]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

const HostProfile _host = HostProfile(
  id: 'host-1',
  label: 'Local',
  baseUrl: 'http://localhost:3000',
  token: 'token',
);

class _FakeWorkspaceApi extends ApiClient {
  _FakeWorkspaceApi({required this.files});

  final Map<String, String> files;
  final List<String> readPaths = <String>[];

  @override
  Future<FsListing> listDirectory(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    final entries = files.keys
        .where((entryPath) => entryPath.startsWith('$path/'))
        .map((entryPath) {
          final name = entryPath.split('/').last;
          return FsEntry(
            name: name,
            path: entryPath,
            isDirectory: false,
            isFile: true,
          );
        })
        .toList(growable: false);
    return FsListing(path: path, entries: entries);
  }

  @override
  Future<FsFile> readFile(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
    String? basePath,
  }) async {
    readPaths.add(path);
    final contents = files[path];
    if (contents == null) {
      throw StateError('Missing fake file: $path');
    }
    return FsFile(
      path: path,
      size: contents.length,
      binary: false,
      truncated: false,
      modifiedAtMs: 0,
      mimeHint: 'text/plain',
      encoding: 'utf8',
      contents: contents,
    );
  }

  @override
  IOWebSocketChannel openFsLive(
    HostProfile host, {
    String? agentProvider,
    String? sessionId,
  }) {
    throw StateError('WebSocket not needed in this test');
  }
}
