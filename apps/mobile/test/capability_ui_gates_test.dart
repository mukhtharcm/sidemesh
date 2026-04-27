import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/create_session_defaults_store.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/create_session_sheet.dart';
import 'package:sidemesh_mobile/src/screens/host_detail_screen.dart';
import 'package:sidemesh_mobile/src/screens/session_screen.dart';
import 'package:sidemesh_mobile/src/session_policy_store.dart';
import 'package:sidemesh_mobile/src/session_turn_config_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  setUp(() {
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

    expect(find.text('Browse files'), findsNothing);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Archive'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

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

    expect(find.text('No adjustable controls'), findsOneWidget);
    expect(
      find.text(
        'Fake Test Provider does not advertise runtime controls for existing sessions.',
      ),
      findsOneWidget,
    );
    expect(find.text('Model & thinking'), findsNothing);
    expect(find.text('Approval policy'), findsNothing);
    expect(find.text('Sandbox'), findsNothing);
    expect(find.text('Network'), findsNothing);
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

    expect(find.text('Model & thinking'), findsOneWidget);
    expect(find.text('Approval policy'), findsOneWidget);
    expect(find.text('Sandbox'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
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

    await tester.tap(find.text('Tune launch'));
    await _pumpFrames(tester);

    expect(
      find.text(
        'Fake Test Provider does not advertise profile or model controls.',
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

    await tester.tap(find.text('Tune launch'));
    await _pumpFrames(tester);

    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Fast mode'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Live web search'), findsOneWidget);
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
          ),
          ProviderDefinitionSummary(
            kind: 'fake',
            displayName: 'Fake Test Provider',
            defaultCommand: 'builtin',
            commandEnvironmentVariables: ['SIDEMESH_FAKE_CAPABILITY_PROFILE'],
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

    expect(find.text('Provider contract'), findsOneWidget);
    expect(
      find.text('Fake Test Provider - fake-provider 1.0.0'),
      findsOneWidget,
    );

    await tester.tap(find.text('Provider contract'));
    await _pumpFrames(tester);

    expect(find.text('active: fake'), findsOneWidget);
    expect(find.text('Fake Test Provider active'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Provider-owned capabilities'), findsOneWidget);
    expect(find.text('Runtime controls'), findsOneWidget);
    expect(find.text('web search'), findsOneWidget);
    expect(find.text('Host-owned capabilities'), findsOneWidget);
    expect(find.text('git status'), findsOneWidget);
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
    status: 'loaded',
    runtime: null,
    gitInfo: null,
  );
}

NodeInfo _nodeForCapabilities(
  Map<String, Object?> capabilities, {
  List<ProviderDefinitionSummary> supportedProviders = const [],
}) => NodeInfo.fromJson({
  'label': 'fake-profile',
  'hostname': 'localhost',
  'platform': 'darwin',
  'codexVersion': 'fake-provider 1.0.0',
  'provider': 'fake',
  'providerName': 'Fake Test Provider',
  'providerVersion': 'fake-provider 1.0.0',
  'providerConfig': {'kind': 'fake', 'command': 'builtin'},
  'providerCapabilities': capabilities,
  'hostCapabilities': {
    'workspace': {'gitStatus': false, 'gitDiff': false},
  },
  'supportedProviders': supportedProviders
      .map(
        (provider) => {
          'kind': provider.kind,
          'displayName': provider.displayName,
          'defaultCommand': provider.defaultCommand,
          'commandEnvironmentVariables': provider.commandEnvironmentVariables,
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
    'reasoningEffort': true,
    'fastMode': true,
    'approvalPolicy': true,
    'sandboxMode': true,
    'networkAccess': true,
    'webSearch': true,
  },
  'workspace': {'filesystem': true, 'remoteGitDiff': true},
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
    'reasoningEffort': false,
    'fastMode': false,
    'approvalPolicy': false,
    'sandboxMode': false,
    'networkAccess': false,
    'webSearch': false,
  },
  'workspace': {'filesystem': false, 'remoteGitDiff': false},
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

class _CapabilityFakeApi extends ApiClient {
  _CapabilityFakeApi(
    this.node, {
    this.models = const <ModelCatalogEntry>[],
    this.profiles = const <ProviderProfileSummary>[],
  });

  final NodeInfo node;
  final List<ModelCatalogEntry> models;
  final List<ProviderProfileSummary> profiles;
  final _IdleWebSocketChannel _channel = _IdleWebSocketChannel();

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
    String? provider,
  }) async => models;

  @override
  Future<ProviderProfileCatalog> fetchProfiles(
    HostProfile host, {
    String? cwd,
  }) async => ProviderProfileCatalog(
    defaultProfile: profiles.isEmpty ? null : profiles.first.name,
    profiles: profiles,
  );

  @override
  Future<SkillCatalog> fetchSkills(
    HostProfile host, {
    required String cwd,
    bool forceReload = false,
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
