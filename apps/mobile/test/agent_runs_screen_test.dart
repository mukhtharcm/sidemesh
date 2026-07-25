import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/agent_runs_screen.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

void main() {
  testWidgets('shows parent-owned agent runs and their state', (tester) async {
    final api = _AgentRunsApi([
      AgentRunSummary(
        id: 'child-active',
        parentSessionId: 'parent',
        title: 'Explorer',
        preview: 'Checking provider pagination and cache behavior.',
        cwd: '/repo',
        createdAt: DateTime(2026, 1, 1, 12),
        updatedAt: DateTime.now(),
        provider: 'codex',
        status: 'running',
        agentRole: 'explorer',
      ),
      AgentRunSummary(
        id: 'child-done',
        parentSessionId: 'parent',
        title: 'Review result',
        preview: 'No additional issues found.',
        cwd: '/repo',
        createdAt: DateTime(2026, 1, 1, 12),
        updatedAt: DateTime.now(),
        provider: 'codex',
        status: 'completed',
        agentNickname: 'reviewer',
      ),
    ]);
    final palette = ThemeVariant.codexAmber;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(palette.light),
        home: AgentRunsScreen(
          host: const HostProfile(
            id: 'host',
            label: 'Host',
            baseUrl: 'http://127.0.0.1:4099',
            token: 'token',
          ),
          session: _session(),
          api: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Agents'), findsOneWidget);
    expect(find.text('2 agents'), findsOneWidget);
    expect(find.text('1 active'), findsOneWidget);
    expect(find.text('1 done'), findsOneWidget);
    expect(find.text('explorer'), findsOneWidget);
    expect(find.text('reviewer'), findsOneWidget);
    expect(
      find.text('Checking provider pagination and cache behavior.'),
      findsOneWidget,
    );

    await tester.tap(find.text('explorer'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back to agents'), findsOneWidget);
    expect(find.text('Agent result from the delegated run.'), findsOneWidget);
  });
}

class _AgentRunsApi extends ApiClient {
  _AgentRunsApi(this.runs);

  final List<AgentRunSummary> runs;

  @override
  Future<List<AgentRunSummary>> fetchAgentRuns(
    HostProfile host,
    String parentSessionId, {
    int? limit,
  }) async => runs;

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async => SessionLog(
    session: _session(),
    messages: [
      SessionMessage(
        id: 'result',
        role: 'assistant',
        text: 'Agent result from the delegated run.',
        attachments: const [],
        createdAt: DateTime.now(),
        seq: 1,
      ),
    ],
    activities: const [],
    pendingAction: null,
    history: null,
  );
}

SessionSummary _session() {
  final now = DateTime(2026, 1, 1, 12);
  return SessionSummary(
    id: 'parent',
    title: 'Parent session',
    preview: '',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'codex',
    provider: 'codex',
    status: 'idle',
    runtime: null,
    gitInfo: null,
  );
}
