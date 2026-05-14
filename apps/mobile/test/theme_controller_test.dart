import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/theme/theme_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads default typography preferences', () async {
    final controller = await ThemeController.load();

    expect(
      controller.typography.interfaceFont,
      InterfaceFontFamily.systemSans,
    );
    expect(controller.typography.interfaceScale, TextSizePreset.standard);
  });

  test('persists typography preferences', () async {
    final controller = await ThemeController.load();

    await controller.setInterfaceFont(InterfaceFontFamily.systemSans);
    await controller.setInterfaceScale(TextSizePreset.large);

    final restored = await ThemeController.load();
    expect(restored.typography.interfaceFont, InterfaceFontFamily.systemSans);
    expect(restored.typography.interfaceScale, TextSizePreset.large);
  });
}
