import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/image_blob_cache_store.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  Directory? tempRoot;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempRoot = Directory.systemTemp.createTempSync('sidemesh-image-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationCacheDirectory') {
            return tempRoot!.path;
          }
          return null;
        });
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

  test('clearAll removes cached image files and index state', () async {
    final store = ImageBlobCacheStore.instance;
    final prefs = await SharedPreferences.getInstance();
    final api = _ImageApi(Uint8List.fromList([1, 2, 3]));

    final file = await store.load(host: host, path: '/tmp/image.png', api: api);
    final orphan = File('${file.parent.path}/orphan.blob');
    final temp = File('${file.parent.path}/stale.tmp');
    await orphan.writeAsBytes([4, 5, 6], flush: true);
    await temp.writeAsBytes([7, 8, 9], flush: true);

    expect(api.requestCount, 1);
    expect(await file.exists(), isTrue);
    expect(await orphan.exists(), isTrue);
    expect(await temp.exists(), isTrue);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(prefs.getKeys(), isNotEmpty);

    await store.clearAll();

    expect(await file.exists(), isFalse);
    expect(await orphan.exists(), isFalse);
    expect(await temp.exists(), isFalse);
    expect(await file.parent.exists(), isFalse);
    expect(prefs.getKeys(), isEmpty);
  });

  test('clearHost removes indexed and orphaned files for that host', () async {
    final store = ImageBlobCacheStore.instance;
    final prefs = await SharedPreferences.getInstance();
    final api = _ImageApi(Uint8List.fromList([1, 2, 3]));

    final file = await store.load(host: host, path: '/tmp/image.png', api: api);
    final fileName = file.uri.pathSegments.last;
    final hostPrefix = '${fileName.split('-').first}-';
    final orphan = File('${file.parent.path}/${hostPrefix}orphan.blob');
    await orphan.writeAsBytes([4, 5, 6], flush: true);

    expect(await file.exists(), isTrue);
    expect(await orphan.exists(), isTrue);
    expect(prefs.getKeys(), isNotEmpty);

    await store.clearHost(host);

    expect(await file.exists(), isFalse);
    expect(await orphan.exists(), isFalse);
    expect(prefs.getKeys(), isEmpty);
  });

  test('clearAll prevents in-flight loads from repopulating cache', () async {
    final store = ImageBlobCacheStore.instance;
    final prefs = await SharedPreferences.getInstance();
    final api = _DelayedImageApi([1, 2, 3]);

    final load = store.load(host: host, path: '/tmp/image.png', api: api);
    await api.started.future;

    await store.clearAll();
    api.complete();

    final file = await load;
    addTearDown(() async {
      final parent = file.parent;
      if (await parent.exists()) {
        await parent.delete(recursive: true);
      }
    });

    expect(api.requestCount, 1);
    expect(await file.exists(), isTrue);
    expect(file.path.contains('sidemesh_image_blobs_v1'), isFalse);
    expect(
      await Directory('${tempRoot!.path}/sidemesh_image_blobs_v1').exists(),
      isFalse,
    );
    expect(prefs.getKeys(), isEmpty);
  });

  test('scopes relative image cache entries and requests by session', () async {
    final store = ImageBlobCacheStore.instance;
    final api = _ImageApi(Uint8List.fromList([1, 2, 3]));

    await store.load(
      host: host,
      path: './artifacts/result.png',
      api: api,
      sessionId: 'session-a',
    );
    await store.load(
      host: host,
      path: './artifacts/result.png',
      api: api,
      sessionId: 'session-b',
    );
    await store.load(
      host: host,
      path: './artifacts/result.png',
      api: api,
      sessionId: 'session-a',
    );

    expect(api.requestCount, 2);
    expect(api.sessionIds, ['session-a', 'session-b']);
  });
}

class _ImageApi extends ApiClient {
  _ImageApi(this.bytes);

  final Uint8List bytes;
  var requestCount = 0;
  final List<String?> sessionIds = <String?>[];

  @override
  Future<Uint8List> fetchFsBlob(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    requestCount += 1;
    sessionIds.add(sessionId);
    return bytes;
  }
}

class _DelayedImageApi extends ApiClient {
  _DelayedImageApi(this.bytes);

  final List<int> bytes;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  var requestCount = 0;

  void complete() {
    if (!release.isCompleted) {
      release.complete();
    }
  }

  @override
  Future<Uint8List> fetchFsBlob(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    requestCount += 1;
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return Uint8List.fromList(bytes);
  }
}
