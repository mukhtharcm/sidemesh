import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/screens/inspector/inspector_controller.dart';
import 'package:sidemesh_mobile/src/screens/inspector/inspector_persistence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('ignores the legacy automatically opened files surface', () async {
    const ownerKey = 'host|session';
    const legacyKey = 'sidemesh.inspector.surface.$ownerKey';
    SharedPreferences.setMockInitialValues(<String, Object>{
      legacyKey: 'fileBrowser',
    });

    expect(await InspectorPersistence.load(ownerKey), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(legacyKey), isFalse);
  });

  test('migrates a restorable legacy surface to v2', () async {
    const ownerKey = 'host|session';
    const legacyKey = 'sidemesh.inspector.surface.$ownerKey';
    const currentKey = 'sidemesh.inspector.surface.v2.$ownerKey';
    SharedPreferences.setMockInitialValues(<String, Object>{
      legacyKey: 'terminal',
    });

    expect(
      await InspectorPersistence.load(ownerKey),
      InspectorSurfaceKind.terminal,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(legacyKey), isFalse);
    expect(prefs.getString(currentKey), 'terminal');
  });

  test('restores and clears a deliberately opened v2 surface', () async {
    const ownerKey = 'host|session';
    const currentKey = 'sidemesh.inspector.surface.v2.$ownerKey';
    SharedPreferences.setMockInitialValues(<String, Object>{
      currentKey: 'fileBrowser',
    });

    expect(
      await InspectorPersistence.load(ownerKey),
      InspectorSurfaceKind.fileBrowser,
    );

    await InspectorPersistence.save(ownerKey, null);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(currentKey), isFalse);
  });
}
