import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/resource_reference.dart';

void main() {
  test('classifies portable and host-owned resource references', () {
    expect(
      parseSessionResourceReference('docs/result.png').kind,
      SessionResourceReferenceKind.localFile,
    );
    expect(
      parseSessionResourceReference('./docs/result.png?raw=1#preview').value,
      './docs/result.png',
    );
    expect(
      parseSessionResourceReference('file:///C:/repo/result.png').value,
      'file:///C:/repo/result.png',
    );
    expect(
      parseSessionResourceReference('http://127.0.0.2:3000/result.png').kind,
      SessionResourceReferenceKind.hostUrl,
    );
    expect(
      parseSessionResourceReference('https://example.com/result.png').kind,
      SessionResourceReferenceKind.publicUrl,
    );
    expect(
      parseSessionResourceReference('#details').kind,
      SessionResourceReferenceKind.anchor,
    );
  });

  test('joins document-relative paths without using the phone platform', () {
    expect(
      resolveHostPathLexically(
        './result.png',
        basePath: '/repo/docs',
      ),
      '/repo/docs/./result.png',
    );
    expect(
      resolveHostPathLexically(
        r'images\result.png',
        basePath: r'C:\repo\docs',
      ),
      r'C:\repo\docs\images\result.png',
    );
  });

  test('detects loopback URLs without treating private public hosts as local', () {
    expect(isHostLoopbackUrl('http://localhost:3000'), isTrue);
    expect(isHostLoopbackUrl('http://app.localhost:3000'), isTrue);
    expect(isHostLoopbackUrl('http://[::1]:3000'), isTrue);
    expect(isHostLoopbackUrl('http://192.168.1.5:3000'), isFalse);
  });
}
