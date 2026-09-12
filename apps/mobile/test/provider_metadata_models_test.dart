import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/provider_labels.dart';
import 'package:sidemesh_mobile/src/session_identity.dart';

void main() {
  test('audio and resource inputs preserve their payload and display metadata', () {
    const items = [
      SessionInputItem.audio('UklGRg==', 'audio/wav', name: 'clip.wav'),
      SessionInputItem.resource('attachment:///empty.txt', text: ''),
      SessionInputItem.resource('attachment:///raw.bin', blob: 'AP8='),
      SessionInputItem.resourceLink('urn:example:record', 'Record'),
    ];
    for (final item in items) {
      final restored = SessionInputItem.fromJson(item.toJson());
      expect(restored.toJson(), item.toJson());
      expect(SessionMessageAttachment.fromJson(restored.contentAttachment.toJson()).toJson(), item.contentAttachment.toJson());
    }
  });

  test('instance identities keep capability lookup and legacy ownership separate', () {
    final payload = <String, dynamic>{
      'provider': 'copilot', 'providerId': 'second',
      'defaultProviderCapabilities': {'input': {'imageUrl': true}},
      'sessionAliases': {
        'rawProviderId': 'first', 'kinds': {'first': 'copilot', 'second': 'copilot'},
        'aliases': {'first': 'first', 'second': 'second', 'copilot': 'first'},
      },
      'supportedProviders': [
        {'id': 'first', 'kind': 'copilot', 'displayName': 'Copilot',
          'capabilities': {'input': {'imageUrl': false}}, 'state': 'unavailable', 'error': 'Not installed'},
        {'id': 'second', 'kind': 'copilot', 'displayName': 'Copilot',
          'capabilities': {'input': {'imageUrl': true}}, 'state': 'ready', 'isDefault': true},
      ],
    };
    final node = NodeInfo.fromJson(payload);
    expect(node.providerId, 'second');
    expect(node.providerSummary(null).id, 'second');
    expect(node.providerSummary('copilot').id, 'first');
    expect(node.providerSummary('first').error, 'Not installed');
    expect(node.capabilitiesForProvider('first').supports('input', 'imageUrl'), isFalse);
    expect(node.capabilitiesForProvider('second').supports('input', 'imageUrl'), isTrue);
    expect(agentProviderDisplayLabel('copilot', providerId: 'second', nodeInfo: node), 'Copilot · second');
    final aliases = node.sessionAliases!;
    expect(aliases.resolve('native-id')!.providerId, 'first');
    expect(aliases.resolve(SessionAliases.wrap('copilot', 'native-id'))!.sessionId, SessionAliases.wrap('first', 'native-id'));
    expect(aliases.resolve(SessionAliases.wrap('second', 'native:雪'))!.providerId, 'second');
    expect(aliases.resolve(SessionAliases.wrap('unknown', 'native-id')), isNull);
    final patched = node.copyWithUpdateInfo(UpdateInfo.fromJson({'ok': true}));
    expect(patched.providerId, 'second');
    expect(patched.sessionAliases!.resolve('native-id')!.providerId, 'first');
    payload['supportedProviders'] = [(payload['supportedProviders'] as List).last];
    final removed = NodeInfo.fromJson(payload);
    expect(removed.providerSummary('copilot').id, isEmpty);
    expect(removed.capabilitiesForProvider('copilot').supports('input', 'imageUrl'), isFalse);
    expect(removed.sessionAliases!.resolve('native-id')!.providerId, 'first');
    payload.remove('sessionAliases');
    payload['supportedProviders'] = node.supportedProviders.map((entry) => {
      'id': entry.id, 'kind': entry.kind, 'capabilities': entry.capabilities.values,
    }).toList();
    expect(NodeInfo.fromJson(payload).providerSummary('copilot').id, isEmpty);
  });

  test('session identity metadata survives copies and cache JSON', () {
    final session = SessionSummary.fromJson({
      'id': 'legacy-raw', 'canonicalSessionId': SessionAliases.wrap('work', 'legacy-raw'),
      'provider': 'copilot', 'providerId': 'work',
    });
    final restored = SessionSummary.fromJson(session.copyWith(title: 'New title').toJson());
    expect(restored.providerReference, 'work');
    expect(restored.provider, 'copilot');
    expect(restored.canonicalSessionId, SessionAliases.wrap('work', 'legacy-raw'));
    expect(restored.copyWith(id: restored.canonicalSessionId).id, restored.canonicalSessionId);
  });

  test('NodeInfo parses provider metadata from new daemons', () {
    final node = NodeInfo.fromJson({
      'label': 'Provider stack',
      'hostname': 'macbook.local',
      'platform': 'darwin',
      'codexVersion': 'codex-cli 0.125.0',
      'provider': 'codex',
      'providerName': 'Codex',
      'providerVersion': 'codex-cli 0.125.0',
      'providerConfig': {'kind': 'codex', 'command': 'codex'},
      'providerCapabilities': {
        'sessions': {'create': true},
      },
      'defaultProviderCapabilities': {
        'sessions': {'create': true, 'searchSessions': true},
      },
      'hostCapabilities': {
        'workspace': {'filesystem': true, 'gitStatus': true, 'gitDiff': true},
      },
      'supportedProviders': [
        {
          'kind': 'codex',
          'displayName': 'Codex',
          'defaultCommand': 'codex',
          'supportedApprovalPolicies': [
            'untrusted',
            'on-failure',
            'on-request',
            'never',
          ],
          'capabilities': {
            'sessions': {'create': true},
          },
          'commandEnvironmentVariables': [
            'SIDEMESH_CODEX_BIN',
            'SIDEMESH_PROVIDER_COMMAND',
          ],
        },
      ],
      'updateChannel': 'bleeding-edge',
      'currentCommitSha': 'a1b2c3d4e5f6789012345678901234567890abcd',
      'latestCommitSha': 'b1c2d3e4f5a6789012345678901234567890abcd',
      'installType': 'git',
      'updateAvailable': true,
      'updateSupported': true,
      'recommendedMobileClientVersion': '1.2.0',
      'minimumMobileClientVersion': '1.1.0',
    });

    expect(node.provider, 'codex');
    expect(node.providerDisplayName, 'Codex');
    expect(node.providerDisplayVersion, 'codex-cli 0.125.0');
    expect(node.defaultProviderCapabilities.supports('sessions', 'create'), isTrue);
    expect(
      node.defaultProviderCapabilities.supports('sessions', 'searchSessions'),
      isTrue,
    );
    expect(
      node.defaultProviderCapabilities.supports('workspace', 'gitStatus'),
      isFalse,
    );
    expect(node.supportsHostCapability('workspace', 'gitStatus'), isTrue);
    expect(node.supportsHostCapability('workspace', 'gitDiff'), isTrue);
    expect(node.supportsHostCapability('workspace', 'filesystem'), isTrue);
    expect(node.supportedProviders, hasLength(1));
    expect(node.supportedProviders.single.kind, 'codex');
    expect(node.supportedProviders.single.commandEnvironmentVariables, [
      'SIDEMESH_CODEX_BIN',
      'SIDEMESH_PROVIDER_COMMAND',
    ]);
    expect(node.updateChannel, 'bleeding-edge');
    expect(node.shortCurrentCommitSha, 'a1b2c3d');
    expect(node.shortLatestCommitSha, 'b1c2d3e');
    expect(node.currentInstallLabel, 'Early access@a1b2c3d');
    expect(node.latestInstallLabel, 'verified@b1c2d3e');
    expect(node.updateBadgeLabel, 'Verified update available');
    expect(node.recommendedMobileClientVersion, '1.2.0');
    expect(node.minimumMobileClientVersion, '1.1.0');
    expect(node.advertisesMobileClientVersionHints, isTrue);
    expect(node.supportedProviders.single.supportedApprovalPolicies, [
      'untrusted',
      'on-failure',
      'on-request',
      'never',
    ]);
    expect(
      node.capabilitiesForProvider('codex').supports('sessions', 'create'),
      isTrue,
    );
  });

  test('NodeInfo stays compatible with older Codex-only daemon payloads', () {
    final node = NodeInfo.fromJson({
      'label': 'Old daemon',
      'hostname': 'macbook.local',
      'platform': 'darwin',
      'codexVersion': 'codex-cli 0.124.0',
    });

    expect(node.provider, 'codex');
    expect(node.providerName, 'Codex');
    expect(node.providerVersion, isEmpty);
    expect(node.providerDisplayName, 'Codex');
    expect(node.providerDisplayVersion, isEmpty);
    expect(node.updateChannel, 'stable');
    expect(node.currentCommitSha, isNull);
    expect(node.providerConfig.kind, isEmpty);
    expect(node.defaultProviderCapabilities.values, isEmpty);
    expect(node.hostCapabilities.values, isEmpty);
    expect(node.supportsHostCapability('workspace', 'gitStatus'), isFalse);
    expect(node.supportedProviders, isEmpty);
    expect(node.advertisesMobileClientVersionHints, isFalse);
  });

  test('UpdateInfo patches NodeInfo update fields', () {
    final node = NodeInfo.fromJson({
      'label': 'Provider stack',
      'hostname': 'macbook.local',
      'platform': 'darwin',
      'codexVersion': 'codex-cli 0.125.0',
      'provider': 'codex',
      'providerName': 'Codex',
      'providerVersion': 'codex-cli 0.125.0',
      'providerConfig': {'kind': 'codex', 'command': 'codex'},
      'providerCapabilities': {
        'sessions': {'create': true},
      },
      'defaultProviderCapabilities': {
        'sessions': {'create': true},
      },
      'hostCapabilities': {
        'workspace': {'filesystem': true},
      },
      'supportedProviders': [
        {
          'kind': 'codex',
          'displayName': 'Codex',
          'defaultCommand': 'codex',
          'capabilities': {
            'sessions': {'create': true},
          },
        },
      ],
      'packageVersion': '0.1.0',
      'latestVersion': '0.2.0',
      'updateChannel': 'stable',
      'installType': 'git',
      'updateSupported': true,
      'updateAvailable': false,
      'recommendedMobileClientVersion': '1.2.0',
      'minimumMobileClientVersion': '1.0.0',
    });
    final updateInfo = UpdateInfo.fromJson({
      'ok': true,
      'refreshed': true,
      'packageVersion': '0.1.0',
      'latestVersion': null,
      'currentCommitSha': 'a1b2c3d4e5f6789012345678901234567890abcd',
      'latestCommitSha': 'b1c2d3e4f5a6789012345678901234567890abcd',
      'updateChannel': 'bleeding-edge',
      'installType': 'git',
      'updateSupported': true,
      'updateAvailable': true,
    });

    final patched = node.copyWithUpdateInfo(updateInfo);

    expect(updateInfo.ok, isTrue);
    expect(updateInfo.refreshed, isTrue);
    expect(patched.provider, 'codex');
    expect(patched.updateChannel, 'bleeding-edge');
    expect(patched.shortCurrentCommitSha, 'a1b2c3d');
    expect(patched.shortLatestCommitSha, 'b1c2d3e');
    expect(patched.updateAvailable, isTrue);
    expect(patched.updateBadgeLabel, 'Verified update available');
    expect(patched.recommendedMobileClientVersion, '1.2.0');
    expect(patched.minimumMobileClientVersion, '1.0.0');
  });

  test('UpdateOperation parses authoritative updater phases and results', () {
    final operation = UpdateOperation.fromJson({
      'id': 'update-1',
      'state': 'failed',
      'phase': 'completed',
      'channel': 'bleeding-edge',
      'startedAt': 1000,
      'updatedAt': 2000,
      'finishedAt': 3000,
      'previousVersion': '0.2.2',
      'previousCommitSha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'targetCommitSha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'installedVersion': '0.2.2',
      'installedCommitSha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'cutoverStarted': true,
      'restored': true,
      'error': 'candidate health check failed',
      'logPath': '/tmp/update.log',
    });

    expect(operation.isTerminal, isTrue);
    expect(operation.isFailed, isTrue);
    expect(operation.isInProgress, isFalse);
    expect(operation.restored, isTrue);
    expect(operation.cutoverStarted, isTrue);
    expect(operation.shortTargetCommitSha, 'bbbbbbb');
    expect(operation.shortInstalledCommitSha, 'aaaaaaa');
    expect(operation.startedDateTime.millisecondsSinceEpoch, 1000);
    expect(operation.finishedDateTime?.millisecondsSinceEpoch, 3000);
  });

  test('ProviderMetadata drops malformed provider entries', () {
    final metadata = ProviderMetadata.fromJson({
      'currentProvider': 'codex',
      'providers': [
        {
          'kind': 'codex',
          'displayName': 'Codex',
          'defaultCommand': 'codex',
          'commandEnvironmentVariables': ['SIDEMESH_CODEX_BIN'],
          'supportedApprovalPolicies': ['on-request', 'never'],
        },
        {'displayName': 'Missing kind'},
      ],
    });

    expect(metadata.currentProvider, 'codex');
    expect(metadata.providers, hasLength(1));
    expect(metadata.providers.single.kind, 'codex');
    expect(metadata.providers.single.displayName, 'Codex');
    expect(metadata.providers.single.defaultCommand, 'codex');
  });

  test('agent provider labels use advertised metadata before fallbacks', () {
    final node = NodeInfo.fromJson({
      'label': 'Provider stack',
      'hostname': 'macbook.local',
      'platform': 'darwin',
      'codexVersion': 'codex-cli 0.125.0',
      'provider': 'copilot',
      'providerName': 'GitHub Copilot',
      'providerVersion': 'cli 0.0.350',
      'providerConfig': {'kind': 'copilot', 'command': 'copilot'},
      'supportedProviders': [
        {
          'kind': 'copilot',
          'displayName': 'Copilot Agent',
          'defaultCommand': 'copilot',
        },
      ],
    });

    expect(
      agentProviderDisplayLabel('copilot', nodeInfo: node),
      'Copilot Agent',
    );
    expect(agentProviderDisplayLabel('copilot'), 'GitHub Copilot');
    expect(agentProviderDisplayLabel('open-claw'), 'Open Claw');
    expect(agentProviderDisplayLabel(null), isNull);
    expect(agentProviderDisplayLabel(''), isNull);
  });

  test('ModelCatalogEntry uses provider-neutral reasoning metadata', () {
    final model = ModelCatalogEntry.fromJson({
      'id': 'fake:auto',
      'model': 'fake-auto',
      'displayName': 'Fake Auto',
      'description': 'Provider-managed reasoning.',
      'defaultReasoningEffort': 'medium',
      'supportedReasoningEfforts': [
        {'reasoningEffort': 'medium', 'description': 'Provider decides.'},
      ],
      'reasoningEffortControl': 'provider',
      'supportsPersonality': true,
      'additionalSpeedTiers': ['fast'],
      'inputModalities': ['text'],
      'isDefault': false,
      'sortOrder': 1,
      'source': 'builtin',
    });

    expect(model.isAutoModel, isTrue);
    expect(model.supportsFastMode, isTrue);
    expect(model.sortOrder, 1);

    final legacy = ModelCatalogEntry.fromJson({
      'id': 'legacy:model',
      'model': 'legacy-model',
      'displayName': 'Legacy Model',
      'description': 'No new metadata.',
      'defaultReasoningEffort': 'medium',
      'supportedReasoningEfforts': const [],
      'supportsPersonality': false,
      'additionalSpeedTiers': const [],
      'inputModalities': ['text'],
      'isDefault': true,
    });

    expect(legacy.reasoningEffortControl, 'client');
    expect(legacy.isAutoModel, isFalse);
    expect(legacy.sortOrder, isNull);
  });

  test('NodeInfo exposes fake capability profiles for UI gates', () {
    final chatOnly = NodeInfo.fromJson(
      _fakeNodePayload(
        'chat-only',
        providerCapabilities: {
          'sessions': {
            'create': true,
            'history': true,
            'interrupt': true,
            'archive': true,
          },
          'input': {
            'text': true,
            'imageUrl': false,
            'localImage': false,
            'skills': false,
          },
          'configuration': {
            'models': false,
            'profiles': false,
            'skills': false,
          },
          'runtimeControls': {'model': false, 'approvalPolicy': false},
        },
      ),
    );

    expect(chatOnly.providerDisplayVersion, 'fake-provider 1.0.0 (chat-only)');
    expect(chatOnly.defaultProviderCapabilities.supports('input', 'text'), isTrue);
    expect(
      chatOnly.defaultProviderCapabilities.supports('input', 'imageUrl'),
      isFalse,
    );
    expect(chatOnly.defaultProviderCapabilities.supports('input', 'skills'), isFalse);
    expect(
      chatOnly.defaultProviderCapabilities.supports('configuration', 'models'),
      isFalse,
    );
    expect(
      chatOnly.defaultProviderCapabilities.supports('runtimeControls', 'model'),
      isFalse,
    );

    final noFiles = NodeInfo.fromJson(
      _fakeNodePayload(
        'no-files',
        providerCapabilities: {
          'input': {'imageUrl': true, 'skills': true},
          'configuration': {'models': true, 'skills': true},
          'runtimeControls': {'model': true},
        },
      ),
    );

    expect(noFiles.defaultProviderCapabilities.supports('input', 'imageUrl'), isTrue);
    expect(
      noFiles.defaultProviderCapabilities.supports('configuration', 'models'),
      isTrue,
    );
  });

  test('SessionActivity decodes nested and legacy tool semantic payloads', () {
    final nested = SessionActivity.fromJson({
      'id': 'tool-1',
      'type': 'tool',
      'createdAt': DateTime(2026, 4, 28).millisecondsSinceEpoch,
      'seq': 1,
      'status': 'completed',
      'toolName': 'view',
      'title': 'Read README.md',
      'args': {'path': 'README.md'},
      'result': {'content': 'hello'},
      'attachments': [
        {
          'type': 'image',
          'url': 'data:image/png;base64,AAAA',
        },
      ],
      'semantic': {
        'category': 'filesystem',
        'action': 'read',
        'targets': [
          {
            'type': 'file',
            'path': 'README.md',
            'access': 'read',
            'role': 'target',
          },
        ],
      },
    });

    expect(nested.toolSemantic?.category, 'filesystem');
    expect(nested.toolSemantic?.action, 'read');
    expect(nested.toolTarget, 'README.md');
    expect(nested.toolTargets, ['README.md']);
    expect(nested.toolAttachments, hasLength(1));
    expect(nested.toolAttachments.single.isImage, isTrue);
    expect(
      nested.toJson()['attachments'],
      [
        {
          'type': 'image',
          'url': 'data:image/png;base64,AAAA',
          'path': null,
        },
      ],
    );

    final legacy = SessionActivity.fromJson({
      'id': 'tool-2',
      'type': 'tool',
      'createdAt': DateTime(2026, 4, 28).millisecondsSinceEpoch,
      'seq': 2,
      'status': 'completed',
      'toolName': 'session.mode',
      'toolCategory': 'session',
      'toolAction': 'mode_change',
      'toolMode': 'autopilot',
    });

    expect(legacy.toolSemantic?.category, 'session');
    expect(legacy.toolSemantic?.action, 'mode_change');
    expect(legacy.toolMode, 'autopilot');
  });
}

Map<String, dynamic> _fakeNodePayload(
  String profile, {
  required Map<String, dynamic> providerCapabilities,
}) {
  return {
    'label': 'fake-$profile',
    'hostname': 'localhost',
    'platform': 'darwin',
    'codexVersion': 'fake-provider 1.0.0 ($profile)',
    'provider': 'fake',
    'providerName': 'Fake Test Provider',
    'providerVersion': 'fake-provider 1.0.0 ($profile)',
    'providerConfig': {'kind': 'fake', 'command': 'builtin'},
    'providerCapabilities': providerCapabilities,
    'defaultProviderCapabilities': providerCapabilities,
    'hostCapabilities': {
      'workspace': {'filesystem': true, 'gitStatus': true, 'gitDiff': true},
    },
    'supportedProviders': const [],
  };
}
