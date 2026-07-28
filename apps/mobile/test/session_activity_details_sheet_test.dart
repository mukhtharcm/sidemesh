import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/fs_models.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/file_browser_screen.dart';
import 'package:sidemesh_mobile/src/screens/file_viewer_screen.dart';
import 'package:sidemesh_mobile/src/screens/inspector/inspector_search.dart';
import 'package:sidemesh_mobile/src/screens/session_screen.dart';
import 'package:sidemesh_mobile/src/screens/terminal_screen.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/diff_view.dart';
import 'package:sidemesh_mobile/src/widgets/syntax_code_block.dart';
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
  });

  group('activity presentation', () {
    test('uses contextual labels only when a useful drill-down exists', () {
      expect(
        sessionActivityDetailActionLabel(
          _activity(
            type: 'file_change',
            changes: const [
              SessionActivityChange(
                path: '/repo/lib/app.dart',
                kind: 'update',
                diff: '@@ -1 +1 @@\n-old\n+new',
              ),
            ],
          ),
        ),
        'View changes',
      );
      expect(
        sessionActivityDetailActionLabel(
          _activity(
            type: 'web_search',
            query: 'calm transcript design',
            targetUrl: 'https://example.com/design',
          ),
        ),
        'View sources',
      );
      expect(
        sessionActivityDetailActionLabel(
          _activity(
            type: 'command',
            command: 'flutter test',
            output: 'All tests passed',
          ),
        ),
        'View results',
      );
      expect(
        sessionActivityDetailActionLabel(
          _activity(
            type: 'command',
            status: 'failed',
            command: 'flutter test',
            output: 'One test failed',
          ),
        ),
        'See what happened',
      );
      expect(
        sessionActivityDetailActionLabel(
          _activity(type: 'web_search', query: 'one simple query'),
        ),
        isNull,
      );
      expect(
        sessionActivityDetailActionLabel(
          _activity(
            type: 'tool',
            toolName: 'read_file',
            toolArgs: const {'path': '/repo/README.md'},
          ),
        ),
        isNull,
      );
    });

    test('never exposes raw image or search function names', () {
      final attachment = _activity(
        type: 'tool',
        toolName: 'wait',
        toolAttachments: const [
          SessionMessageAttachment(
            type: 'image',
            url: 'data:image/png;base64,AA==',
          ),
        ],
      );
      final viewImage = _activity(
        type: 'tool',
        toolName: 'view_image',
        toolArgs: const {'path': '/repo/screenshots/session.png'},
      );
      final search = _activity(
        type: 'tool',
        toolName: 'search_tool',
        toolArgs: const {
          'search_query': [
            {'q': 'Flutter bottom sheet accessibility'},
          ],
        },
      );
      final inverseSearchAlias = _activity(
        type: 'tool',
        toolName: 'tool_search',
        toolArgs: const {'query': 'Android tablet session details'},
      );

      expect(sessionToolActivityFallbackTitle(attachment), 'Viewed an image');
      expect(sessionToolActivityFallbackTitle(viewImage), 'Viewed session.png');
      expect(
        sessionToolActivityFallbackTitle(search),
        'Searched for "Flutter bottom sheet accessibility"',
      );
      expect(
        sessionToolActivityFallbackTitle(inverseSearchAlias),
        'Searched for "Android tablet session details"',
      );
      expect(sessionToolActivityFallbackTitle(attachment), isNot(contains('wait')));
      expect(
        sessionToolActivityFallbackTitle(viewImage),
        isNot(contains('view_image')),
      );
      expect(
        sessionToolActivityFallbackTitle(search),
        isNot(contains('search_tool')),
      );
      expect(
        sessionToolActivityFallbackTitle(inverseSearchAlias),
        isNot(contains('tool_search')),
      );
    });

    test('unknown tools use provider-neutral status copy', () {
      final completed = _activity(
        type: 'tool',
        toolName: 'mcp_internal_dispatch',
        toolTitle: 'provider.raw_function',
      );
      final running = _activity(
        type: 'tool',
        status: 'in_progress',
        toolName: 'mcp_internal_dispatch',
      );
      final failed = _activity(
        type: 'tool',
        status: 'failed',
        toolName: 'mcp_internal_dispatch',
      );

      expect(sessionToolActivityFallbackTitle(completed), 'Completed a step');
      expect(sessionToolActivityFallbackTitle(running), 'Working');
      expect(sessionToolActivityFallbackTitle(failed), 'Step failed');
    });

    test('noncontiguous file-change buckets receive distinct stable IDs', () {
      final firstBucket = _activity(
        id: 'edit-a-1',
        type: 'file_change',
        turnId: 'shared-turn',
      );
      final secondBucket = _activity(
        id: 'edit-b-1',
        type: 'file_change',
        turnId: 'shared-turn',
      );

      expect(
        sessionFileChangeGroupId(firstBucket),
        'file-change-group:shared-turn:edit-a-1',
      );
      expect(
        sessionFileChangeGroupId(secondBucket),
        'file-change-group:shared-turn:edit-b-1',
      );
      expect(
        sessionFileChangeGroupId(firstBucket),
        isNot(sessionFileChangeGroupId(secondBucket)),
      );
    });
  });

  testWidgets('search rows keep provider identifiers behind explicit details', (
    tester,
  ) async {
    final activity = _activity(
      id: 'search-image-tool',
      type: 'tool',
      toolName: 'view_image',
      toolTitle: 'provider.raw_image_reader',
      toolArgs: const {'path': '/repo/screenshots/session.png'},
    );
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    final palette = ThemeVariant.codexAmber;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(palette.light),
        darkTheme: buildDarkTheme(palette.dark),
        home: Scaffold(
          body: SearchPanel(
            controller: controller,
            focusNode: focusNode,
            records: [
              SearchRecord(
                id: activity.id,
                kind: SearchRecordKind.activity,
                createdAt: activity.createdAt,
                haystack: 'view_image provider.raw_image_reader session.png',
                title: sessionToolActivityFallbackTitle(activity)!,
                activity: activity,
                sessionCwd: '/repo',
              ),
            ],
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('Viewed session.png'), findsOneWidget);
    expect(
      find.textContaining('view_image', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining(
        'provider.raw_image_reader',
        findRichText: true,
      ),
      findsNothing,
    );

    await tester.tap(find.text('Viewed session.png'));
    await _pumpFrames(tester);

    expect(
      find.textContaining('view_image', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'provider.raw_image_reader',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('search previews prefer a human target over raw tool output', (
    tester,
  ) async {
    final activity = _activity(
      id: 'search-query-tool',
      type: 'tool',
      toolName: 'tool_search',
      toolArgs: const {'query': 'calm Android session details'},
      output: 'provider_internal_dispatch: raw response payload',
      toolSemantic: const SessionToolSemantic(
        category: 'network',
        action: 'search',
        targets: [
          SessionToolSemanticTarget(
            type: 'query',
            value: 'calm Android session details',
          ),
        ],
      ),
    );
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    final palette = ThemeVariant.codexAmber;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(palette.light),
        darkTheme: buildDarkTheme(palette.dark),
        home: Scaffold(
          body: SearchPanel(
            controller: controller,
            focusNode: focusNode,
            records: [
              SearchRecord(
                id: activity.id,
                kind: SearchRecordKind.activity,
                createdAt: activity.createdAt,
                haystack:
                    'tool_search calm Android session details raw response',
                title: sessionToolActivityFallbackTitle(activity)!,
                activity: activity,
                sessionCwd: '/repo',
              ),
            ],
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(find.textContaining('calm Android session details'), findsWidgets);
    expect(
      find.textContaining(
        'provider_internal_dispatch',
        findRichText: true,
      ),
      findsNothing,
    );

    await tester.tap(
      find.text('Searched for "calm Android session details"'),
    );
    await _pumpFrames(tester);

    expect(
      find.textContaining('Kind Action', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'provider_internal_dispatch',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'mobile opens changes in a sheet and preserves transcript geometry',
    (tester) async {
      final session = _session('mobile-activity-details');
      final api = _ActivityDetailsFakeApi(
        session: session,
        activities: [
          _activity(
            id: 'file-change',
            seq: 1,
            type: 'file_change',
            changes: const [
              SessionActivityChange(
                path: '/repo/lib/app.dart',
                kind: 'update',
                diff: '@@ -1 +1 @@\n-old\n+new',
              ),
            ],
          ),
          _activity(
            id: 'quiet-search',
            seq: 2,
            type: 'web_search',
            query: 'one simple query',
          ),
        ],
      );
      addTearDown(api.dispose);

      await _pumpSession(
        tester,
        api: api,
        session: session,
        size: const Size(390, 844),
      );

      expect(find.text('View changes'), findsOneWidget);
      expect(find.text('View details'), findsNothing);
      expect(find.text('View technical actions'), findsNothing);
      expect(find.byType(DiffView), findsNothing);
      final rowTopBefore = tester.getTopLeft(find.text('Edited 1 file')).dy;

      await tester.tap(find.text('View changes'));
      await _pumpFrames(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Changes'), findsOneWidget);
      expect(find.byType(DiffView), findsOneWidget);
      expect(
        tester.getSize(
          find.byKey(const ValueKey('activity-details-surface')),
        ).height,
        lessThan(844 * 0.7),
      );

      await tester.tap(find.byTooltip('Close details'));
      await _pumpFrames(tester);

      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getTopLeft(find.text('Edited 1 file')).dy,
        rowTopBefore,
      );
    },
  );

  for (final scenario in const [
    (width: 759.0, expectsDialog: false),
    (width: 760.0, expectsDialog: true),
  ]) {
    testWidgets(
      'Android adaptive details use ${scenario.expectsDialog ? 'a dialog' : 'a sheet'} at ${scenario.width.toInt()} px',
      (tester) async {
        final session = _session(
          'adaptive-activity-details-${scenario.width.toInt()}',
        );
        final api = _ActivityDetailsFakeApi(
          session: session,
          activities: [
            _activity(
              id: 'adaptive-command',
              type: 'command',
              command: 'flutter test',
              output: 'All tests passed',
            ),
          ],
        );
        addTearDown(api.dispose);

        await _pumpSession(
          tester,
          api: api,
          session: session,
          size: Size(scenario.width, 1024),
        );
        await tester.tap(find.text('View results'));
        await _pumpFrames(tester);

        expect(
          find.byType(Dialog),
          scenario.expectsDialog ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(BottomSheet),
          scenario.expectsDialog ? findsNothing : findsOneWidget,
        );
      },
    );
  }

  testWidgets('desktop opens command results in a constrained dialog', (
    tester,
  ) async {
    final session = _session('desktop-activity-details');
    final api = _ActivityDetailsFakeApi(
      session: session,
      activities: [
        _activity(
          id: 'command',
          type: 'command',
          command: 'flutter test',
          output: 'All tests passed',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(1180, 900),
      desktopMode: true,
    );

    expect(find.text('View results'), findsOneWidget);
    expect(find.text('Raw command'), findsNothing);

    await tester.tap(find.text('View results'));
    await _pumpFrames(tester);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Results'), findsOneWidget);
    expect(find.text('Raw command'), findsOneWidget);
    expect(find.text('All tests passed'), findsOneWidget);
  });

  testWidgets('unknown tool identifiers appear only inside details', (
    tester,
  ) async {
    final session = _session('unknown-tool-details');
    final api = _ActivityDetailsFakeApi(
      session: session,
      activities: [
        _activity(
          id: 'unknown-tool',
          type: 'tool',
          toolName: 'mcp_internal_dispatch',
          toolTitle: 'provider.raw_function',
          toolResult: const {'ok': true},
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(1180, 900),
      desktopMode: true,
    );

    expect(find.text('Completed a step'), findsOneWidget);
    expect(find.text('mcp_internal_dispatch'), findsNothing);
    expect(find.text('provider.raw_function'), findsNothing);

    await tester.tap(find.text('View results'));
    await _pumpFrames(tester);

    expect(find.textContaining('mcp_internal_dispatch'), findsOneWidget);
    expect(find.textContaining('provider.raw_function'), findsOneWidget);
  });

  testWidgets('context action dismisses details before opening its target', (
    tester,
  ) async {
    final session = _session('activity-action-handoff');
    final api = _ActivityDetailsFakeApi(
      session: session,
      supportsTerminal: true,
      activities: [
        _activity(
          id: 'command',
          type: 'command',
          command: 'flutter test',
          output: 'All tests passed',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(390, 844),
    );

    await tester.tap(find.text('View results'));
    await _pumpFrames(tester);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.tap(find.text('Open terminal'));
    await _pumpFrames(tester);

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('open details follow live activity output and status', (
    tester,
  ) async {
    final session = _session('live-activity-details');
    final initial = _activity(
      id: 'live-command',
      seq: 100,
      type: 'command',
      status: 'in_progress',
      command: 'flutter test',
      output: 'Running tests...',
    );
    final api = _ActivityDetailsFakeApi(
      session: session,
      activities: [
        for (var index = 1; index <= 36; index += 1)
          _activity(
            id: 'earlier-step-$index',
            seq: index,
            type: 'tool',
            toolName: 'earlier_provider_step',
          ),
        initial,
      ],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(1180, 900),
      desktopMode: true,
    );

    await tester.tap(find.text('View results'));
    await _pumpFrames(tester);
    expect(find.text('Running tests...'), findsOneWidget);

    final transcript = tester.widget<ListView>(
      find.byWidgetPredicate((widget) => widget is ListView && widget.reverse),
    );
    transcript.controller!.jumpTo(
      transcript.controller!.position.maxScrollExtent,
    );
    await tester.pump();

    api.emit({
      'type': 'activity_updated',
      'sessionId': session.id,
      'seq': 110,
      'activity': _activity(
        id: 'newer-step',
        seq: 110,
        type: 'tool',
        toolName: 'newer_provider_step',
      ).toJson(),
    });
    await _pumpFrames(tester);

    api.emit({
      'type': 'activity_updated',
      'sessionId': session.id,
      'seq': 111,
      'activity': _activity(
        id: 'live-command',
        seq: 101,
        type: 'command',
        status: 'completed',
        command: 'flutter test',
        output: 'All tests passed live.',
        createdAt: initial.createdAt,
      ).toJson(),
    });
    await _pumpFrames(tester);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('All tests passed live.'), findsOneWidget);
    expect(find.text('Running tests...'), findsNothing);
  });

  testWidgets('large command output is bounded before syntax layout', (
    tester,
  ) async {
    final session = _session('bounded-command-output');
    final output = List<String>.generate(
      320,
      (index) => 'command-output-line-$index',
    ).join('\n');
    final api = _ActivityDetailsFakeApi(
      session: session,
      activities: [
        _activity(
          id: 'large-command',
          type: 'command',
          command: 'flutter test',
          output: output,
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(1180, 900),
      desktopMode: true,
    );
    await tester.tap(find.text('View results'));
    await _pumpFrames(tester);

    final outputBlock = tester
        .widgetList<SyntaxCodeBlock>(find.byType(SyntaxCodeBlock))
        .singleWhere((block) => block.text.contains('command-output-line-319'));
    expect(outputBlock.text, isNot(contains('command-output-line-0')));
    expect(outputBlock.text.split('\n').length, lessThanOrEqualTo(241));
    expect(
      find.text(
        'Showing the latest part of this result. Earlier content was omitted.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('open file-change details stay live as the turn group grows', (
    tester,
  ) async {
    final session = _session('live-file-change-group');
    final first = _activity(
      id: 'edit-first',
      seq: 1,
      type: 'file_change',
      turnId: 'shared-edit-turn',
      changes: const [
        SessionActivityChange(
          path: '/repo/lib/first.dart',
          kind: 'update',
          diff: '@@ -1 +1 @@\n-old\n+new',
        ),
      ],
    );
    final api = _ActivityDetailsFakeApi(
      session: session,
      activities: [first],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(390, 844),
    );
    await tester.tap(find.text('View changes'));
    await _pumpFrames(tester);
    expect(find.text('lib/first.dart'), findsWidgets);

    api.emit({
      'type': 'activity_updated',
      'sessionId': session.id,
      'seq': 2,
      'activity': _activity(
        id: 'edit-second',
        seq: 2,
        type: 'file_change',
        turnId: 'shared-edit-turn',
        changes: const [
          SessionActivityChange(
            path: '/repo/lib/second.dart',
            kind: 'update',
            diff: '@@ -1 +1 @@\n-before\n+after',
          ),
        ],
      ).toJson(),
    });
    await _pumpFrames(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Edited 2 files'), findsWidgets);
    expect(find.text('lib/first.dart'), findsWidgets);
    expect(find.text('lib/second.dart'), findsWidgets);
  });

  testWidgets('filesystem reads keep a direct open-file action', (
    tester,
  ) async {
    final session = _session('filesystem-read-action');
    final api = _ActivityDetailsFakeApi(
      session: session,
      supportsFilesystem: true,
      activities: [
        _activity(
          id: 'read-file',
          type: 'tool',
          toolName: 'provider_read',
          toolSemantic: const SessionToolSemantic(
            category: 'filesystem',
            action: 'read',
            targets: [
              SessionToolSemanticTarget(
                type: 'file',
                path: '/repo/README.md',
              ),
            ],
          ),
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(600, 844),
    );

    expect(find.text('Read README.md'), findsOneWidget);
    expect(find.text('Open file'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.text('Open file'));
    await _pumpFrames(tester);

    expect(find.byType(FileViewerScreen), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('filesystem listings keep a direct browse-files action', (
    tester,
  ) async {
    final session = _session('filesystem-list-action');
    final api = _ActivityDetailsFakeApi(
      session: session,
      supportsFilesystem: true,
      activities: [
        _activity(
          id: 'list-files',
          type: 'tool',
          toolName: 'provider_list',
          toolSemantic: const SessionToolSemantic(
            category: 'filesystem',
            action: 'list',
            targets: [
              SessionToolSemanticTarget(type: 'file', path: '/repo/lib'),
            ],
          ),
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpSession(
      tester,
      api: api,
      session: session,
      size: const Size(600, 844),
    );

    expect(find.text('Listed lib'), findsOneWidget);
    expect(find.text('Browse files'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.text('Browse files'));
    await _pumpFrames(tester);

    final browser = tester.widget<FileBrowserScreen>(
      find.byType(FileBrowserScreen),
    );
    expect(browser.root, '/repo/lib/');
    expect(find.byType(BottomSheet), findsNothing);
  });
}

Future<void> _pumpSession(
  WidgetTester tester, {
  required _ActivityDetailsFakeApi api,
  required SessionSummary session,
  required Size size,
  bool desktopMode = false,
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
      home: Scaffold(
        body: SessionScreen(
          host: _host,
          session: session,
          api: api,
          desktopMode: desktopMode,
        ),
      ),
    ),
  );
  await _pumpFrames(tester);
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

const _host = HostProfile(
  id: 'activity-details-host',
  label: 'Fake host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

SessionSummary _session(String id) {
  final now = DateTime(2026, 1, 1, 12);
  return SessionSummary(
    id: id,
    title: 'Activity details',
    preview: '',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'fake',
    provider: null,
    status: 'idle',
    runtime: null,
    gitInfo: null,
  );
}

SessionActivity _activity({
  String id = 'activity',
  String type = 'tool',
  int seq = 1,
  String status = 'completed',
  String? turnId,
  String? command,
  String? output,
  String? toolName,
  String? toolTitle,
  Object? toolArgs,
  Object? toolResult,
  List<SessionMessageAttachment> toolAttachments = const [],
  bool? toolError,
  SessionToolSemantic? toolSemantic,
  List<SessionActivityChange> changes = const [],
  String? diff,
  String? query,
  List<String> queries = const [],
  String? targetUrl,
  String? pattern,
  DateTime? createdAt,
}) {
  return SessionActivity(
    id: id,
    type: type,
    createdAt:
        createdAt ??
        DateTime(2026, 1, 1, 12).add(Duration(minutes: seq)),
    seq: seq,
    status: status,
    turnId: turnId ?? 'turn-$seq',
    command: command,
    cwd: type == 'command' ? '/repo' : null,
    output: output,
    exitCode: null,
    durationMs: null,
    source: null,
    processId: null,
    commandActions: const [],
    terminalStatus: null,
    terminalInput: null,
    toolName: toolName,
    toolTitle: toolTitle,
    toolArgs: toolArgs,
    toolResult: toolResult,
    toolAttachments: toolAttachments,
    toolError: toolError,
    toolSemantic: toolSemantic,
    changes: changes,
    diff: diff,
    query: query,
    queries: queries,
    targetUrl: targetUrl,
    pattern: pattern,
    revisedPrompt: null,
    savedPath: null,
  );
}

NodeInfo _nodeInfo({
  bool supportsTerminal = false,
  bool supportsFilesystem = false,
}) => NodeInfo.fromJson({
  'label': 'fake-profile',
  'hostname': 'localhost',
  'platform': 'android',
  'codexVersion': 'fake-provider 1.0.0',
  'provider': 'fake',
  'providerName': 'Fake Test Provider',
  'providerVersion': 'fake-provider 1.0.0',
  'providerConfig': {'kind': 'fake', 'command': 'builtin'},
  'providerCapabilities': {
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
    'configuration': {'models': false, 'profiles': false, 'skills': false},
    'runtimeControls': {
      'model': false,
      'approvalPolicy': false,
      'sandboxMode': false,
      'networkAccess': false,
    },
  },
  'defaultProviderCapabilities': {
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
    'configuration': {'models': false, 'profiles': false, 'skills': false},
    'runtimeControls': {
      'model': false,
      'approvalPolicy': false,
      'sandboxMode': false,
      'networkAccess': false,
    },
  },
  'hostCapabilities': {
    'workspace': {
      'filesystem': supportsFilesystem,
      'gitStatus': false,
      'gitDiff': false,
      'browserPreview': false,
      'terminal': supportsTerminal,
    },
  },
  'supportedProviders': const [],
});

class _ActivityDetailsFakeApi extends ApiClient {
  _ActivityDetailsFakeApi({
    required this.session,
    required this.activities,
    this.supportsTerminal = false,
    this.supportsFilesystem = false,
  });

  final SessionSummary session;
  final List<SessionActivity> activities;
  final bool supportsTerminal;
  final bool supportsFilesystem;
  final _TestWebSocketChannel _channel = _TestWebSocketChannel();
  final _TestWebSocketChannel _terminalChannel = _TestWebSocketChannel();
  final _TestWebSocketChannel _fsChannel = _TestWebSocketChannel()
    ..autoAckFsSubscriptions();

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async =>
      _nodeInfo(
        supportsTerminal: supportsTerminal,
        supportsFilesystem: supportsFilesystem,
      );

  @override
  Future<FsFile> readFile(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
    String? basePath,
  }) async {
    return FsFile(
      path: path,
      size: 7,
      binary: false,
      truncated: false,
      modifiedAtMs: 0,
      mimeHint: 'text/plain',
      encoding: 'utf8',
      contents: 'Sidemesh',
    );
  }

  @override
  Future<FsListing> listDirectory(
    HostProfile host,
    String path, {
    String? agentProvider,
    String? sessionId,
  }) async {
    return FsListing(path: path, entries: const []);
  }

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async {
    return SessionLog(
      session: session,
      messages: const [],
      activities: activities,
      pendingAction: null,
      history: SessionLogHistorySummary(
        isTruncated: false,
        totalMessages: 0,
        returnedMessages: 0,
        totalActivities: activities.length,
        returnedActivities: activities.length,
      ),
      latestPlanUpdate: null,
    );
  }

  @override
  Future<SessionEventsDelta> fetchEvents(
    HostProfile host,
    String sessionId, {
    required int since,
    int? baseUpdatedAt,
  }) async {
    return SessionEventsDelta(
      sessionId: sessionId,
      since: since,
      nextSeq: since,
      messages: const [],
      activities: const [],
      latestPlanUpdate: null,
      pendingAction: null,
      session: null,
    );
  }

  @override
  Future<SessionStatus> fetchStatus(HostProfile host, String sessionId) async {
    return SessionStatus(
      sessionId: sessionId,
      status: session.status,
      isRunning: false,
      activeTurnId: null,
      pendingAction: null,
    );
  }

  @override
  Future<SkillCatalog> fetchSkills(
    HostProfile host, {
    required String cwd,
    bool forceReload = false,
    String? agentProvider,
  }) async {
    return SkillCatalog(cwd: cwd, skills: const [], errors: const []);
  }

  @override
  WebSocketChannel openLive(HostProfile host, String sessionId) => _channel;

  @override
  WebSocketChannel openFsLive(
    HostProfile host, {
    String? agentProvider,
    String? sessionId,
  }) => _fsChannel;

  @override
  Future<List<HostTerminalInfo>> fetchTerminals(HostProfile host) async =>
      const [];

  @override
  Future<HostTerminalInfo> createTerminal(
    HostProfile host, {
    required String cwd,
    String? sessionId,
    String? title,
    int? cols,
    int? rows,
    bool replaceExisting = false,
  }) async {
    return HostTerminalInfo(
      id: 'test-terminal',
      title: title ?? 'Terminal',
      cwd: cwd,
      sessionId: sessionId,
      status: 'running',
      backend: 'test',
      shell: '/bin/sh',
      rows: rows ?? 24,
      cols: cols ?? 80,
      createdAt: 0,
      updatedAt: 0,
      exitCode: null,
      signal: null,
      nextSeq: 0,
      clients: 0,
    );
  }

  @override
  WebSocketChannel openTerminalLive(
    HostProfile host,
    String terminalId, {
    int since = -1,
  }) => _terminalChannel;

  void emit(Map<String, Object?> event) {
    _channel.emit(jsonEncode(event));
  }

  void dispose() {
    _channel.dispose();
    _terminalChannel.dispose();
    _fsChannel.dispose();
  }
}

class _TestWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _TestWebSocketSink(_outgoing.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  void emit(String raw) {
    _incoming.add(raw);
  }

  void autoAckFsSubscriptions() {
    _outgoing.stream.listen((raw) {
      if (raw is! String) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['type'] != 'subscribe') return;
      final id = decoded['id']?.toString();
      if (id == null) return;
      emit(
        jsonEncode({
          'type': 'subscribed',
          'id': id,
          'watchId': 'watch-$id',
        }),
      );
    });
  }

  void dispose() {
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
  }
}

class _TestWebSocketSink implements WebSocketSink {
  _TestWebSocketSink(this.delegate);

  final StreamSink<dynamic> delegate;

  @override
  Future<void> addStream(Stream<dynamic> stream) => delegate.addStream(stream);

  @override
  void add(dynamic data) => delegate.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    delegate.addError(error, stackTrace);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) => delegate.close();

  @override
  Future<void> get done => delegate.done;
}
