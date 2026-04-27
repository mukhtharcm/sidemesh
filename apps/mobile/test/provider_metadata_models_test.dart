import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
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
        'workspace': {'remoteGitDiff': true},
      },
      'hostCapabilities': {
        'workspace': {'gitStatus': true, 'gitDiff': true},
      },
      'supportedProviders': [
        {
          'kind': 'codex',
          'displayName': 'Codex',
          'defaultCommand': 'codex',
          'commandEnvironmentVariables': [
            'SIDEMESH_CODEX_BIN',
            'SIDEMESH_PROVIDER_COMMAND',
          ],
        },
      ],
    });

    expect(node.provider, 'codex');
    expect(node.providerDisplayName, 'Codex');
    expect(node.providerDisplayVersion, 'codex-cli 0.125.0');
    expect(node.providerCapabilities.supports('sessions', 'create'), isTrue);
    expect(
      node.providerCapabilities.supports('workspace', 'gitStatus'),
      isFalse,
    );
    expect(
      node.providerCapabilities.supports('workspace', 'remoteGitDiff'),
      isTrue,
    );
    expect(node.supportsHostCapability('workspace', 'gitStatus'), isTrue);
    expect(node.supportsHostCapability('workspace', 'gitDiff'), isTrue);
    expect(node.supportedProviders, hasLength(1));
    expect(node.supportedProviders.single.kind, 'codex');
    expect(node.supportedProviders.single.commandEnvironmentVariables, [
      'SIDEMESH_CODEX_BIN',
      'SIDEMESH_PROVIDER_COMMAND',
    ]);
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
    expect(node.providerVersion, 'codex-cli 0.124.0');
    expect(node.providerDisplayName, 'Codex');
    expect(node.providerDisplayVersion, 'codex-cli 0.124.0');
    expect(node.providerConfig.kind, isEmpty);
    expect(node.providerCapabilities.values, isEmpty);
    expect(node.hostCapabilities.values, isEmpty);
    expect(node.supportsHostCapability('workspace', 'gitStatus'), isFalse);
    expect(node.supportedProviders, isEmpty);
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
    final chatOnly = NodeInfo.fromJson(_fakeNodePayload(
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
        'runtimeControls': {
          'model': false,
          'approvalPolicy': false,
        },
        'workspace': {
          'filesystem': false,
          'remoteGitDiff': false,
        },
      },
    ));

    expect(chatOnly.providerDisplayVersion, 'fake-provider 1.0.0 (chat-only)');
    expect(chatOnly.providerCapabilities.supports('input', 'text'), isTrue);
    expect(chatOnly.providerCapabilities.supports('input', 'imageUrl'), isFalse);
    expect(chatOnly.providerCapabilities.supports('input', 'skills'), isFalse);
    expect(
      chatOnly.providerCapabilities.supports('configuration', 'models'),
      isFalse,
    );
    expect(
      chatOnly.providerCapabilities.supports('runtimeControls', 'model'),
      isFalse,
    );
    expect(
      chatOnly.providerCapabilities.supports('workspace', 'filesystem'),
      isFalse,
    );

    final noFiles = NodeInfo.fromJson(_fakeNodePayload(
      'no-files',
      providerCapabilities: {
        'input': {'imageUrl': true, 'skills': true},
        'configuration': {'models': true, 'skills': true},
        'runtimeControls': {'model': true},
        'workspace': {'filesystem': false, 'remoteGitDiff': false},
      },
    ));

    expect(noFiles.providerCapabilities.supports('input', 'imageUrl'), isTrue);
    expect(
      noFiles.providerCapabilities.supports('configuration', 'models'),
      isTrue,
    );
    expect(
      noFiles.providerCapabilities.supports('workspace', 'filesystem'),
      isFalse,
    );
    expect(
      noFiles.providerCapabilities.supports('workspace', 'remoteGitDiff'),
      isFalse,
    );
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
    'hostCapabilities': {
      'workspace': {'gitStatus': true, 'gitDiff': true},
    },
    'supportedProviders': const [],
  };
}
