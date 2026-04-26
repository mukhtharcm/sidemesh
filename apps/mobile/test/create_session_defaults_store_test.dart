import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/create_session_defaults_store.dart';
import 'package:sidemesh_mobile/src/session_policy_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CreateSessionDefaultsStore.instance.resetForTest();
  });

  test('loads factory defaults when nothing is persisted', () async {
    await CreateSessionDefaultsStore.instance.ensureLoaded();

    final defaults = CreateSessionDefaultsStore.instance.defaults;
    expect(defaults.approval, ApprovalPolicy.onRequest);
    expect(defaults.sandbox, SandboxMode.workspaceWrite);
    expect(defaults.fastMode, isFalse);
    expect(defaults.webSearch, isFalse);
  });

  test('persists custom launch defaults', () async {
    final store = CreateSessionDefaultsStore.instance;
    await store.ensureLoaded();

    await store.setDefaults(
      const CreateSessionDefaults(
        approval: ApprovalPolicy.never,
        sandbox: SandboxMode.dangerFullAccess,
        fastMode: true,
        webSearch: true,
      ),
    );

    CreateSessionDefaultsStore.instance.resetForTest();
    await CreateSessionDefaultsStore.instance.ensureLoaded();
    final restored = CreateSessionDefaultsStore.instance.defaults;

    expect(restored.approval, ApprovalPolicy.never);
    expect(restored.sandbox, SandboxMode.dangerFullAccess);
    expect(restored.fastMode, isTrue);
    expect(restored.webSearch, isTrue);
  });
}
