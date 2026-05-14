import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/create_session_defaults_store.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/fs_models.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/create_session_sheet.dart';
import 'package:sidemesh_mobile/src/screens/host_detail_screen.dart';
import 'package:sidemesh_mobile/src/screens/session_screen.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/session_policy_store.dart';
import 'package:sidemesh_mobile/src/session_turn_config_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'test_path_provider.dart';

void main() {
  setUpAll(() async {
    await configureTestDatabaseFactory();
  });

  setUp(() async {
    SessionLocalStore.instance.resetMigrationState();
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CreateSessionDefaultsStore.instance.resetForTest();
  });

  testWidgets('session screen hides unsupported composer and menu actions', (
    tester,
  ) async {
    final api = _CapabilityFakeApi(_nodeForCapabilities(_minimalCapabilities));
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('session-minimal'),
        session: _session('minimal-session'),
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.byTooltip('Attach images'), findsNothing);
    expect(find.byTooltip('Paste image from clipboard'), findsNothing);

    await tester.tap(find.byTooltip('Session actions'));
    await _pumpFrames(tester);

    expect(find.text('Browse files'), findsOneWidget);
    expect(find.text('Open browser preview'), findsNothing);
    expect(find.text('Manage browser previews'), findsNothing);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Archive'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'session screen surfaces browser preview actions for preview-capable hosts',
    (tester) async {
      final api = _CapabilityFakeApi(
        _nodeForCapabilities(
          _minimalCapabilities,
          hostWorkspaceCapabilities: const {
            'filesystem': true,
            'gitStatus': false,
            'gitDiff': false,
            'browserPreview': true,
            'portForwarding': false,
          },
        ),
      );
      addTearDown(api.dispose);

      await _pumpApp(
        tester,
        SessionScreen(
          host: _host('session-preview-capable'),
          session: _session('preview-capable-session'),
          api: api,
          desktopMode: true,
        ),
        size: const Size(1180, 900),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byTooltip('Session actions'));
      await _pumpFrames(tester);

      expect(find.text('Open browser preview'), findsOneWidget);
      expect(find.text('Manage browser previews'), findsOneWidget);
    },
  );

  testWidgets(
    'session screen hides browser preview actions for tunnel-only hosts',
    (tester) async {
      final api = _CapabilityFakeApi(
        _nodeForCapabilities(
          _minimalCapabilities,
          hostWorkspaceCapabilities: const {
            'filesystem': true,
            'gitStatus': false,
            'gitDiff': false,
            'browserPreview': false,
            'portForwarding': true,
          },
        ),
      );
      addTearDown(api.dispose);

      await _pumpApp(
        tester,
        SessionScreen(
          host: _host('session-tunnel-capable'),
          session: _session('tunnel-capable-session'),
          api: api,
          desktopMode: true,
        ),
        size: const Size(1180, 900),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byTooltip('Session actions'));
      await _pumpFrames(tester);

      expect(find.text('Open browser preview'), findsNothing);
      expect(find.text('Manage browser previews'), findsNothing);
    },
  );

  testWidgets(
    'session screen ignores stale file search results when the mention query changes',
    (tester) async {
      final api = _FileSearchRaceApi(
        _nodeForCapabilities(_fileMentionCapabilities),
      );
      addTearDown(api.dispose);

      await _pumpApp(
        tester,
        SessionScreen(
          host: _host('session-file-mentions'),
          session: _session('file-mention-session'),
          api: api,
          desktopMode: true,
        ),
        size: const Size(1180, 900),
      );
      await _pumpFrames(tester);

      final composer = find.byType(TextField).first;
      await tester.enterText(composer, '@a');
      await tester.pump();

      expect(api.queries, <String>['a']);

      await tester.enterText(composer, '@ab');
      await tester.pump();

      expect(api.queries, <String>['a', 'ab']);

      api.pendingSearch('ab').complete(const <FsSearchResult>[
        FsSearchResult(
          path: '/repo/ab.txt',
          name: 'ab.txt',
          isDirectory: false,
          score: 120,
        ),
      ]);
      await tester.pump();

      expect(find.text('/repo/ab.txt'), findsOneWidget);

      api.pendingSearch('a').complete(const <FsSearchResult>[
        FsSearchResult(
          path: '/repo/a.txt',
          name: 'a.txt',
          isDirectory: false,
          score: 90,
        ),
      ]);
      await tester.pump();

      expect(find.text('/repo/ab.txt'), findsOneWidget);
      expect(find.text('/repo/a.txt'), findsNothing);
    },
  );

  testWidgets('session controls show empty state for chat-only providers', (
    tester,
  ) async {
    final api = _CapabilityFakeApi(_nodeForCapabilities(_minimalCapabilities));

    await _pumpApp(
      tester,
      SessionControlsSheet(
        api: api,
        host: _host('controls-minimal'),
        session: _session('controls-minimal-session'),
        runtimeModel: null,
        runtimeModelProvider: null,
        runtimeMode: null,
        runtimeServiceTier: null,
        runtimeReasoningEffort: null,
        runtimeApproval: null,
        runtimeSandbox: null,
        runtimeNetworkAccess: null,
        policyStore: SessionPolicyStore.instance,
        turnConfigStore: SessionTurnConfigStore.instance,
      ),
      size: const Size(760, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Nothing to change here'), findsOneWidget);
    expect(
      find.text(
        'Fake Test Provider does not expose session settings you can change after a run starts.',
      ),
      findsOneWidget,
    );
    expect(find.text('Model and thinking'), findsNothing);
    expect(find.text('Mode'), findsNothing);
    expect(find.text('Approvals'), findsNothing);
    expect(find.text('File access'), findsNothing);
    expect(find.text('Internet access'), findsNothing);
  });

  testWidgets('session controls show advertised runtime controls', (
    tester,
  ) async {
    final api = _CapabilityFakeApi(
      _nodeForCapabilities(_fullCapabilities),
      models: const [_fakeModel],
    );

    await _pumpApp(
      tester,
      SessionControlsSheet(
        api: api,
        host: _host('controls-full'),
        session: _session('controls-full-session'),
        runtimeModel: null,
        runtimeModelProvider: null,
        runtimeMode: null,
        runtimeServiceTier: null,
        runtimeReasoningEffort: null,
        runtimeApproval: null,
        runtimeSandbox: null,
        runtimeNetworkAccess: null,
        policyStore: SessionPolicyStore.instance,
        turnConfigStore: SessionTurnConfigStore.instance,
      ),
      size: const Size(840, 1100),
    );
    await _pumpFrames(tester);

    expect(find.text('Model and thinking'), findsOneWidget);
    expect(find.text('Mode'), findsOneWidget);
    expect(find.text('Approvals'), findsOneWidget);
    expect(find.text('File access'), findsOneWidget);
    expect(find.text('Internet access'), findsOneWidget);
  });

  testWidgets('session controls use provider-defined mode catalogs', (
    tester,
  ) async {
    final api = _CapabilityFakeApi(
      _nodeForCapabilities(_fullCapabilities),
      modes: const [
        ProviderModeSummary(id: 'build', label: 'Build'),
        ProviderModeSummary(id: 'review', label: 'Review'),
      ],
    );

    await _pumpApp(
      tester,
      SessionControlsSheet(
        api: api,
        host: _host('controls-mode-catalog'),
        session: _session('controls-mode-catalog-session'),
        runtimeModel: null,
        runtimeModelProvider: null,
        runtimeMode: 'build',
        runtimeServiceTier: null,
        runtimeReasoningEffort: null,
        runtimeApproval: null,
        runtimeSandbox: null,
        runtimeNetworkAccess: null,
        policyStore: SessionPolicyStore.instance,
        turnConfigStore: SessionTurnConfigStore.instance,
      ),
      size: const Size(840, 1100),
    );
    await _pumpFrames(tester);

    expect(find.text('Build'), findsWidgets);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Interactive'), findsNothing);
    expect(find.text('Plan'), findsNothing);
  });

  testWidgets('create session sheet hides unsupported launch controls', (
    tester,
  ) async {
    await CreateSessionDefaultsStore.instance.ensureLoaded();
    final api = _CapabilityFakeApi(_nodeForCapabilities(_minimalCapabilities));

    await _pumpApp(
      tester,
      CreateSessionSheet(
        host: _host('create-minimal'),
        api: api,
        initialCwd: '/repo',
        presentation: CreateSessionPresentation.dialog,
      ),
      size: const Size(1600, 1100),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Session setup'));
    await _pumpFrames(tester);

    expect(
      find.text(
        'Fake Test Provider does not offer profiles or model choices here.',
      ),
      findsOneWidget,
    );
    expect(find.text('Permissions'), findsNothing);
    expect(find.text('Live web search'), findsNothing);
  });

  testWidgets('create session sheet shows advertised launch controls', (
    tester,
  ) async {
    await CreateSessionDefaultsStore.instance.ensureLoaded();
    final api = _CapabilityFakeApi(
      _nodeForCapabilities(_fullCapabilities),
      models: const [_fakeModel],
      profiles: const [_fakeProfile],
    );

    await _pumpApp(
      tester,
      CreateSessionSheet(
        host: _host('create-full'),
        api: api,
        initialCwd: '/repo',
        presentation: CreateSessionPresentation.dialog,
      ),
      size: const Size(1600, 1200),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Session setup'));
    await _pumpFrames(tester);

    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Work style'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Fast mode'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Live web search'), findsOneWidget);
  });

  testWidgets('create session sheet sends selected provider for mixed hosts', (
    tester,
  ) async {
    await CreateSessionDefaultsStore.instance.ensureLoaded();
    final api = _CapabilityFakeApi(
      _nodeForCapabilities(
        _fullCapabilities,
        supportedProviders: const [
          ProviderDefinitionSummary(
            kind: 'fake',
            displayName: 'Fake Test Provider',
            defaultCommand: 'builtin',
            commandEnvironmentVariables: ['SIDEMESH_FAKE_CAPABILITY_PROFILE'],
            supportedApprovalPolicies: [
              'untrusted',
              'on-failure',
              'on-request',
              'never',
            ],
            capabilities: ProviderCapabilities(_fullCapabilities),
            config: ProviderConfigSummary(kind: 'fake', command: 'builtin'),
            version: 'fake-provider 1.0.0',
            isDefault: true,
          ),
          ProviderDefinitionSummary(
            kind: 'copilot',
            displayName: 'GitHub Copilot',
            defaultCommand: 'copilot',
            commandEnvironmentVariables: ['SIDEMESH_COPILOT_BIN'],
            supportedApprovalPolicies: ['on-request', 'never'],
            capabilities: ProviderCapabilities(_copilotApprovalCapabilities),
            config: ProviderConfigSummary(kind: 'copilot', command: 'copilot'),
            version: 'GitHub Copilot SDK 9.9.9',
            isDefault: false,
          ),
        ],
      ),
    );

    await _pumpApp(
      tester,
      CreateSessionSheet(
        host: _host('create-provider-switch'),
        api: api,
        initialCwd: '/repo',
        presentation: CreateSessionPresentation.dialog,
      ),
      size: const Size(1600, 1100),
    );
    await _pumpFrames(tester);

    expect(find.text('Fake Test Provider'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('create-session-provider-selector')),
    );
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('provider-picker-copilot')));
    await _pumpFrames(tester);

    expect(find.text('GitHub Copilot'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('create-session-prompt-field')),
      'Start through Copilot.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Start session'));
    await _pumpFrames(tester);

    expect(api.lastCreateRequest, isNotNull);
    expect(api.lastCreateRequest!.provider, 'copilot');
  });

  testWidgets(
    'create session sheet inherits default profile runtime settings until changed',
    (tester) async {
      await CreateSessionDefaultsStore.instance.ensureLoaded();
      final api = _CapabilityFakeApi(
        _nodeForCapabilities(_fullCapabilities),
        models: const [_fakeModel],
        profiles: const [_codexProfile],
      );

      await _pumpApp(
        tester,
        CreateSessionSheet(
          host: _host('create-profile-inherit'),
          api: api,
          initialCwd: '/repo',
          presentation: CreateSessionPresentation.dialog,
        ),
        size: const Size(1600, 1200),
      );
      await _pumpFrames(tester);

      await tester.enterText(
        find.byKey(const ValueKey('create-session-prompt-field')),
        'Use the profile defaults.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Start session'));
      await _pumpFrames(tester);

      expect(api.lastCreateRequest, isNotNull);
      expect(api.lastCreateRequest!.profile, isNull);
      expect(api.lastCreateRequest!.approvalPolicy, isNull);
      expect(api.lastCreateRequest!.sandboxMode, isNull);
      expect(api.lastCreateRequest!.reasoningEffort, isNull);
      expect(api.lastCreateRequest!.fastMode, isNull);
      expect(api.lastCreateRequest!.webSearch, isNull);
    },
  );

  testWidgets(
    'create session sheet still sends explicit launch overrides over profiles',
    (tester) async {
      await CreateSessionDefaultsStore.instance.ensureLoaded();
      final api = _CapabilityFakeApi(
        _nodeForCapabilities(_fullCapabilities),
        models: const [_fakeModel],
        profiles: const [_codexProfile],
      );

      await _pumpApp(
        tester,
        CreateSessionSheet(
          host: _host('create-profile-override'),
          api: api,
          initialCwd: '/repo',
          presentation: CreateSessionPresentation.dialog,
        ),
        size: const Size(1600, 1200),
      );
      await _pumpFrames(tester);

      await tester.tap(find.text('Session setup'));
      await _pumpFrames(tester);
      await tester.ensureVisible(find.text('Never ask').first);
      await _pumpFrames(tester);
      await tester.tap(find.text('Never ask').first);
      await _pumpFrames(tester);
      await tester.ensureVisible(find.text('Full access (danger)').first);
      await _pumpFrames(tester);
      await tester.tap(find.text('Full access (danger)').first);
      await _pumpFrames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('create-session-prompt-field')),
        'Override the profile defaults.',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Start session'),
      );
      await _pumpFrames(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Start session'));
      await _pumpFrames(tester);

      expect(api.lastCreateRequest, isNotNull);
      expect(api.lastCreateRequest!.approvalPolicy, 'never');
      expect(api.lastCreateRequest!.sandboxMode, 'danger-full-access');
    },
  );

  testWidgets('Copilot approval controls only show supported policies', (
    tester,
  ) async {
    await CreateSessionDefaultsStore.instance.ensureLoaded();
    final api = _CapabilityFakeApi(
      _nodeForCapabilities(
        _copilotApprovalCapabilities,
        providerKind: 'copilot',
        providerName: 'GitHub Copilot',
        providerVersion: 'GitHub Copilot SDK 9.9.9',
        providerCommand: 'copilot',
        supportedProviders: const [
          ProviderDefinitionSummary(
            kind: 'copilot',
            displayName: 'GitHub Copilot',
            defaultCommand: 'copilot',
            commandEnvironmentVariables: ['SIDEMESH_COPILOT_BIN'],
            supportedApprovalPolicies: ['on-request', 'never'],
            capabilities: ProviderCapabilities(_copilotApprovalCapabilities),
            config: ProviderConfigSummary(kind: 'copilot', command: 'copilot'),
            version: 'GitHub Copilot SDK 9.9.9',
            isDefault: true,
          ),
        ],
      ),
    );

    await _pumpApp(
      tester,
      CreateSessionSheet(
        host: _host('create-copilot'),
        api: api,
        initialCwd: '/repo',
        presentation: CreateSessionPresentation.dialog,
      ),
      size: const Size(1600, 1100),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Session setup'));
    await _pumpFrames(tester);

    expect(find.text('Ask when requested'), findsWidgets);
    expect(find.text('Never ask'), findsWidgets);
    expect(find.text('Ask when untrusted'), findsNothing);
    expect(find.text('Ask only on failure'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Autopilot'), findsNothing);
  });

  testWidgets('host detail exposes provider contract metadata', (tester) async {
    final api = _CapabilityFakeApi(
      _nodeForCapabilities(
        _fullCapabilities,
        supportedProviders: const [
          ProviderDefinitionSummary(
            kind: 'codex',
            displayName: 'Codex',
            defaultCommand: 'codex',
            commandEnvironmentVariables: ['SIDEMESH_CODEX_BIN'],
            supportedApprovalPolicies: [
              'untrusted',
              'on-failure',
              'on-request',
              'never',
            ],
            capabilities: ProviderCapabilities(_minimalCapabilities),
            config: ProviderConfigSummary(kind: 'codex', command: 'codex'),
            version: 'codex-cli 0.125.0',
            isDefault: false,
          ),
          ProviderDefinitionSummary(
            kind: 'fake',
            displayName: 'Fake Test Provider',
            defaultCommand: 'builtin',
            commandEnvironmentVariables: ['SIDEMESH_FAKE_CAPABILITY_PROFILE'],
            supportedApprovalPolicies: [
              'untrusted',
              'on-failure',
              'on-request',
              'never',
            ],
            capabilities: ProviderCapabilities(_fullCapabilities),
            config: ProviderConfigSummary(kind: 'fake', command: 'builtin'),
            version: 'fake-provider 1.0.0',
            isDefault: true,
          ),
        ],
      ),
    );

    await _pumpApp(
      tester,
      HostDetailScreen(
        host: _host('host-contract'),
        api: api,
        onOpenSession: (_) {},
      ),
      size: const Size(900, 1000),
    );
    await _pumpFrames(tester);

    expect(find.text('Agents on this machine'), findsAtLeastNWidgets(1));
    expect(
      find.text('Fake Test Provider in use, 2 agents available'),
      findsOneWidget,
    );

    await tester.tap(find.text('Agents on this machine'));
    await _pumpFrames(tester);

    expect(find.text('Agents on this machine'), findsAtLeastNWidgets(1));
    expect(
      find.text('Fake Test Provider · fake-provider 1.0.0'),
      findsOneWidget,
    );
    expect(find.text('In use: Fake Test Provider'), findsOneWidget);
    expect(find.text('Fake Test Provider'), findsOneWidget);
    expect(find.text('In use'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Agent features'), findsOneWidget);
    expect(find.text('Session controls'), findsOneWidget);
    expect(find.text('web search'), findsOneWidget);
    expect(find.text('Machine features'), findsOneWidget);
    expect(find.text('git status'), findsOneWidget);

    await tester.tap(find.text('Codex'));
    await _pumpFrames(tester);

    expect(find.text('Codex · codex-cli 0.125.0'), findsOneWidget);
    expect(find.text('Viewing: Codex'), findsOneWidget);
    expect(find.text('Command: codex'), findsOneWidget);
    expect(find.text('Fake Test Provider'), findsOneWidget);
    expect(find.text('2/5'), findsOneWidget);
    expect(find.text('1/4'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget);
    expect(find.text('0/8'), findsOneWidget);
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpApp(
  WidgetTester tester,
  Widget child, {
  required Size size,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      home: Scaffold(body: child),
    ),
  );
}

HostProfile _host(String id) => HostProfile(
  id: 'capability-ui-$id',
  label: 'Fake Host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

SessionSummary _session(String id) {
  final now = DateTime(2026, 1, 1, 12);
  return SessionSummary(
    id: id,
    title: 'Fake session',
    preview: '',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'fake',
    provider: null,
    status: 'loaded',
    runtime: null,
    gitInfo: null,
  );
}

NodeInfo _nodeForCapabilities(
  Map<String, Object?> capabilities, {
  String providerKind = 'fake',
  String providerName = 'Fake Test Provider',
  String providerVersion = 'fake-provider 1.0.0',
  String providerCommand = 'builtin',
  List<ProviderDefinitionSummary> supportedProviders = const [],
  Map<String, Object?> hostWorkspaceCapabilities = const {
    'filesystem': true,
    'gitStatus': false,
    'gitDiff': false,
  },
}) => NodeInfo.fromJson({
  'label': 'fake-profile',
  'hostname': 'localhost',
  'platform': 'darwin',
  'codexVersion': providerVersion,
  'provider': providerKind,
  'providerName': providerName,
  'providerVersion': providerVersion,
  'providerConfig': {'kind': providerKind, 'command': providerCommand},
  'providerCapabilities': capabilities,
  'defaultProviderCapabilities': capabilities,
  'hostCapabilities': {'workspace': hostWorkspaceCapabilities},
  'supportedProviders': supportedProviders
      .map(
        (provider) => {
          'kind': provider.kind,
          'displayName': provider.displayName,
          'defaultCommand': provider.defaultCommand,
          'commandEnvironmentVariables': provider.commandEnvironmentVariables,
          'supportedApprovalPolicies': provider.supportedApprovalPolicies,
          'capabilities': provider.capabilities.values,
          'config': {
            'kind': provider.config.kind,
            'command': provider.config.command,
          },
          'version': provider.version,
          'isDefault': provider.isDefault,
        },
      )
      .toList(growable: false),
});

const Map<String, Object?> _fullCapabilities = {
  'sessions': {
    'create': true,
    'history': true,
    'interrupt': true,
    'rename': true,
    'archive': true,
  },
  'input': {'text': true, 'imageUrl': true, 'localImage': true, 'skills': true},
  'configuration': {'models': true, 'profiles': true, 'skills': true},
  'runtimeControls': {
    'model': true,
    'mode': true,
    'reasoningEffort': true,
    'fastMode': true,
    'approvalPolicy': true,
    'sandboxMode': true,
    'networkAccess': true,
    'webSearch': true,
  },
  'workspace': {'remoteGitDiff': true},
};

const Map<String, Object?> _minimalCapabilities = {
  'sessions': {
    'create': true,
    'history': true,
    'interrupt': false,
    'rename': false,
    'archive': false,
  },
  'input': {
    'text': true,
    'imageUrl': false,
    'localImage': false,
    'skills': false,
  },
  'configuration': {'models': false, 'profiles': false, 'skills': false},
  'runtimeControls': {
    'model': false,
    'mode': false,
    'reasoningEffort': false,
    'fastMode': false,
    'approvalPolicy': false,
    'sandboxMode': false,
    'networkAccess': false,
    'webSearch': false,
  },
  'workspace': {'remoteGitDiff': false},
};

const Map<String, Object?> _fileMentionCapabilities = {
  'sessions': {
    'create': true,
    'history': true,
    'interrupt': false,
    'rename': false,
    'archive': false,
  },
  'input': {
    'text': true,
    'imageUrl': false,
    'localImage': false,
    'skills': false,
    'fileMentions': true,
  },
  'configuration': {'models': false, 'profiles': false, 'skills': false},
  'runtimeControls': {
    'model': false,
    'mode': false,
    'reasoningEffort': false,
    'fastMode': false,
    'approvalPolicy': false,
    'sandboxMode': false,
    'networkAccess': false,
    'webSearch': false,
  },
  'workspace': {'remoteGitDiff': false},
};

const Map<String, Object?> _copilotApprovalCapabilities = {
  'sessions': {
    'create': true,
    'history': true,
    'interrupt': true,
    'rename': true,
    'archive': true,
  },
  'input': {'text': true, 'imageUrl': true, 'localImage': true, 'skills': true},
  'configuration': {'models': true, 'profiles': false, 'skills': true},
  'runtimeControls': {
    'model': true,
    'mode': true,
    'reasoningEffort': true,
    'fastMode': false,
    'approvalPolicy': true,
    'sandboxMode': false,
    'networkAccess': false,
    'webSearch': false,
  },
  'workspace': {'remoteGitDiff': false},
};

const _fakeModel = ModelCatalogEntry(
  id: 'fake-balanced',
  model: 'fake-balanced',
  displayName: 'Fake Balanced',
  description: 'A fake model used by capability UI tests.',
  defaultReasoningEffort: 'medium',
  supportedReasoningEfforts: [
    ModelReasoningEffortOption(
      reasoningEffort: 'low',
      description: 'Small fake reasoning pass.',
    ),
    ModelReasoningEffortOption(
      reasoningEffort: 'medium',
      description: 'Default fake reasoning pass.',
    ),
  ],
  reasoningEffortControl: 'client',
  supportsPersonality: true,
  additionalSpeedTiers: ['fast'],
  inputModalities: ['text', 'image'],
  isDefault: true,
  sortOrder: 0,
);

const _fakeProfile = ProviderProfileSummary(
  name: 'fake-default',
  isDefault: true,
  model: 'fake-balanced',
  reasoningEffort: 'medium',
);

const _codexProfile = ProviderProfileSummary(
  name: 'guardian',
  isDefault: true,
  model: 'fake-balanced',
  reasoningEffort: 'high',
  approvalPolicy: 'never',
  sandboxMode: 'danger-full-access',
  serviceTier: 'fast',
  webSearch: 'live',
);

class _CapturedCreateSessionRequest {
  const _CapturedCreateSessionRequest({
    required this.cwd,
    required this.prompt,
    required this.provider,
    required this.model,
    required this.mode,
    required this.reasoningEffort,
    required this.fastMode,
    required this.approvalPolicy,
    required this.sandboxMode,
    required this.webSearch,
    required this.profile,
  });

  final String cwd;
  final String prompt;
  final String? provider;
  final String? model;
  final String? mode;
  final String? reasoningEffort;
  final bool? fastMode;
  final String? approvalPolicy;
  final String? sandboxMode;
  final String? webSearch;
  final String? profile;
}

class _CapabilityFakeApi extends ApiClient {
  _CapabilityFakeApi(
    this.node, {
    this.models = const <ModelCatalogEntry>[],
    this.modes = const <ProviderModeSummary>[],
    this.profiles = const <ProviderProfileSummary>[],
  });

  final NodeInfo node;
  final List<ModelCatalogEntry> models;
  final List<ProviderModeSummary> modes;
  final List<ProviderProfileSummary> profiles;
  final _IdleWebSocketChannel _channel = _IdleWebSocketChannel();
  _CapturedCreateSessionRequest? lastCreateRequest;

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => node;

  @override
  Future<List<SessionSummary>> fetchSessions(
    HostProfile host, {
    int? limit,
  }) async => const [];

  @override
  Future<List<ModelCatalogEntry>> fetchModels(
    HostProfile host, {
    String? cwd,
    String? profile,
    String? agentProvider,
    String? provider,
  }) async => models;

  @override
  Future<ProviderProfileCatalog> fetchProfiles(
    HostProfile host, {
    String? cwd,
    String? agentProvider,
  }) async => ProviderProfileCatalog(
    defaultProfile: profiles.isEmpty ? null : profiles.first.name,
    profiles: profiles,
  );

  @override
  Future<ProviderModeCatalog> fetchModes(
    HostProfile host, {
    String? cwd,
    String? agentProvider,
  }) async => ProviderModeCatalog(defaultMode: null, modes: modes);

  @override
  Future<SessionSummary> createSession(
    HostProfile host, {
    required String cwd,
    required String prompt,
    String? provider,
    List<SessionInputItem>? input,
    String? model,
    String? mode,
    String? reasoningEffort,
    bool? fastMode,
    String? approvalPolicy,
    String? sandboxMode,
    String? webSearch,
    String? profile,
  }) async {
    lastCreateRequest = _CapturedCreateSessionRequest(
      cwd: cwd,
      prompt: prompt,
      provider: provider,
      model: model,
      mode: mode,
      reasoningEffort: reasoningEffort,
      fastMode: fastMode,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      webSearch: webSearch,
      profile: profile,
    );
    return _session('created-session');
  }

  @override
  Future<SkillCatalog> fetchSkills(
    HostProfile host, {
    required String cwd,
    bool forceReload = false,
    String? agentProvider,
  }) async => SkillCatalog(cwd: cwd, skills: const [], errors: const []);

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async => SessionLog(
    session: _session(sessionId),
    messages: const [],
    activities: const [],
    pendingAction: null,
    history: const SessionLogHistorySummary(
      isTruncated: false,
      totalMessages: 0,
      returnedMessages: 0,
      totalActivities: 0,
      returnedActivities: 0,
    ),
  );

  @override
  WebSocketChannel openLive(HostProfile host, String sessionId) => _channel;

  void dispose() => _channel.dispose();
}

class _FileSearchRaceApi extends _CapabilityFakeApi {
  _FileSearchRaceApi(super.node);

  final List<String> queries = <String>[];
  final Map<String, Completer<List<FsSearchResult>>> _pendingSearches =
      <String, Completer<List<FsSearchResult>>>{};

  Completer<List<FsSearchResult>> pendingSearch(String query) =>
      _pendingSearches.putIfAbsent(
        query,
        () => Completer<List<FsSearchResult>>(),
      );

  @override
  Future<List<FsSearchResult>> searchFiles(
    HostProfile host, {
    required String query,
    String? sessionId,
    int? limit,
  }) {
    queries.add(query);
    return pendingSearch(query).future;
  }
}

class _IdleWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _IdleWebSocketSink(_outgoing.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  void dispose() {
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
  }
}

class _IdleWebSocketSink implements WebSocketSink {
  _IdleWebSocketSink(this._delegate);

  final StreamSink<dynamic> _delegate;

  @override
  Future<void> addStream(Stream<dynamic> stream) => _delegate.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _delegate.close();

  @override
  Future<void> get done => _delegate.done;

  @override
  void add(dynamic data) => _delegate.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);
}
