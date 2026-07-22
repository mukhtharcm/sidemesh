import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/recent_session_view_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('defaults to grouping sessions by project', () async {
    final store = RecentSessionViewStore.forTesting();

    await store.ensureLoaded();

    expect(store.grouping, RecentSessionGrouping.project);
  });

  test('persists the single-list preference', () async {
    final store = RecentSessionViewStore.forTesting();
    await store.ensureLoaded();

    await store.setGrouping(RecentSessionGrouping.singleList);

    final restored = RecentSessionViewStore.forTesting();
    await restored.ensureLoaded();
    expect(restored.grouping, RecentSessionGrouping.singleList);
  });

  test('falls back to project grouping for an unknown stored value', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sidemesh_recent_session_grouping_v1': 'unknown',
    });
    final store = RecentSessionViewStore.forTesting();

    await store.ensureLoaded();

    expect(store.grouping, RecentSessionGrouping.project);
  });

  test('migrates the previous mobile flat-list preference', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sidemesh.recent.viewMode': 'flat',
    });
    final store = RecentSessionViewStore.forTesting();

    await store.ensureLoaded();

    expect(store.grouping, RecentSessionGrouping.singleList);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('sidemesh_recent_session_grouping_v1'),
      'singleList',
    );
  });

  test('migrates the previous desktop project preference', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sidemesh_recent_view_mode': 'byCwd',
    });
    final store = RecentSessionViewStore.forTesting();

    await store.ensureLoaded();

    expect(store.grouping, RecentSessionGrouping.project);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sidemesh_recent_session_grouping_v1'), 'project');
  });
}
