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
}

class _ImageApi extends ApiClient {
  _ImageApi(this.bytes);

  final Uint8List bytes;
  var requestCount = 0;

  @override
  Future<Uint8List> fetchFsBlob(HostProfile host, String path) async {
    requestCount += 1;
    return bytes;
  }
}
