import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_overrides_store.dart';

void main() {
  final store = SessionOverridesStore.instance;

  setUp(() {
    store.clearForTest();
  });

  test('overlay preserves sub-agent lineage from a newer override', () {
    final override = SessionSummary(
      id: 'session-child',
      title: 'Delegated explorer',
      preview: 'Delegated explorer',
      cwd: '/repo',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(20),
      source: 'sub-agent',
      provider: 'codex',
      status: 'idle',
      runtime: null,
      gitInfo: null,
      isSubAgent: true,
      subAgent: SessionSubAgentInfo(
        parentSessionId: 'session-parent',
        sourceKind: 'thread_spawn',
        agentRole: 'explorer',
      ),
    );
    final incoming = SessionSummary(
      id: 'session-child',
      title: 'Old title',
      preview: 'Delegated explorer',
      cwd: '/repo',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(10),
      source: 'codex',
      provider: 'codex',
      status: 'idle',
      runtime: null,
      gitInfo: null,
    );

    store.apply('host-1', override);
    final merged = store.overlay('host-1', incoming);

    expect(merged.title, 'Delegated explorer');
    expect(merged.isSubAgent, isTrue);
    expect(merged.subAgent?.parentSessionId, 'session-parent');
    expect(merged.subAgent?.agentRole, 'explorer');
  });
}
