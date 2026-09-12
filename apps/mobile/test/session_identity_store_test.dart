import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_identity.dart';
import 'package:sidemesh_mobile/src/session_identity_store.dart';
import 'package:sidemesh_mobile/src/session_policy_store.dart';
import 'package:sidemesh_mobile/src/session_turn_config_store.dart';
import 'package:sidemesh_mobile/src/session_pins_store.dart';
import 'package:sidemesh_mobile/src/session_read_store.dart';
import 'package:sidemesh_mobile/src/screens/inspector/inspector_controller.dart';
import 'package:sidemesh_mobile/src/screens/inspector/inspector_persistence.dart';

void main() {
  test('saved choices follow ownership and explicit removal cannot revive an old alias', () async {
    SharedPreferences.setMockInitialValues({});
    const host = HostProfile(id: 'alias-host', label: 'Host', baseUrl: 'http://localhost', token: 'test');
    const raw = 'native-id';
    final scoped = SessionAliases.wrap('work', raw);
    final legacy = SessionAliases.wrap('copilot', raw);
    final identities = SessionIdentityStore.instance;
    final policies = SessionPolicyStore.instance;
    final configs = SessionTurnConfigStore.instance;
    final pins = SessionPinsStore.instance;
    final reads = SessionReadStore.instance;
    final message = SessionMessage(id: 'message', role: 'assistant', text: 'Keep this',
      createdAt: DateTime.now(), seq: 1, attachments: const []);
    await policies.setPolicy(host, raw, const SessionPolicy(approval: ApprovalPolicy.never));
    await policies.setPolicy(host, scoped, const SessionPolicy(approval: ApprovalPolicy.untrusted));
    await configs.setConfig(host, legacy, const SessionTurnConfig(model: 'saved-model'));
    await pins.pin(host, raw, message);
    await reads.ensureLoaded();
    reads.markSeen(host, raw, message.createdAt);
    await InspectorPersistence.save('${host.id}|$legacy', InspectorSurfaceKind.search);
    const aliases = SessionAliases(rawProviderId: 'work', kinds: {'work': 'copilot', 'other': 'copilot'},
      aliases: {'work': 'work', 'other': 'other', 'copilot': 'work'});
    await identities.save(host.id, aliases);
    expect(policies.policyFor(host, raw).approval, ApprovalPolicy.untrusted);
    expect(configs.configFor(host, scoped).model, 'saved-model');
    expect(pins.pinsFor(host, scoped).single.messageId, message.id);
    expect(reads.lastSeen(host, scoped)!.millisecondsSinceEpoch, message.createdAt.millisecondsSinceEpoch);
    expect(await InspectorPersistence.load('${host.id}|$scoped'), InspectorSurfaceKind.search);
    expect(configs.configFor(host, SessionAliases.wrap('other', raw)).isEmpty, isTrue);
    await policies.setPolicy(host, scoped, const SessionPolicy());
    await configs.setConfig(host, raw, const SessionTurnConfig());
    await pins.unpin(host, legacy, message.id);
    await InspectorPersistence.save('${host.id}|$scoped', null);
    reads.markUnread(host, scoped);
    await reads.flush();
    expect(policies.policyFor(host, legacy).isEmpty, isTrue);
    expect(configs.configFor(host, legacy).isEmpty, isTrue);
    expect(pins.pinsFor(host, raw), isEmpty);
    expect(await InspectorPersistence.load('${host.id}|$legacy'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sidemesh_session_policies_v1'), isNull);
    expect(prefs.getString('sidemesh_session_turn_config_v1'), isNull);
    expect(prefs.getString('sidemesh_session_message_pins_v1'), isNull);
    expect(jsonDecode(prefs.getString('sidemesh_session_read_state_v1')!), {'${host.id}:$scoped': 0});
    identities.resetForTest();
    await identities.ensureLoaded();
    expect(identities.canonical(host.id, raw), scoped);
    reads.resetForTest();
  });
}
