import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_preview_candidates.dart';

void main() {
  test('collectBrowserPreviewCandidates prefers latest unique localhost targets', () {
    final activities = [
      _activity(
        seq: 1,
        command: 'npm run dev',
        output: 'Local: http://localhost:3000\nNetwork: http://192.168.1.2:3000',
      ),
      _activity(
        seq: 2,
        command: 'pnpm preview',
        output: 'Ready on http://127.0.0.1:4173',
      ),
      _activity(
        seq: 3,
        command: 'npm run dev',
        output: 'Server ready on 0.0.0.0:3000',
      ),
    ];

    final candidates = collectBrowserPreviewCandidates(activities);

    expect(
      candidates.map((item) => item.endpointLabel).toList(),
      ['localhost:3000', 'localhost:4173'],
    );
    expect(candidates.first.scheme, 'http');
  });

  test('browserPreviewCandidatesForActivity keeps https loopback URLs', () {
    final activity = _activity(
      seq: 7,
      command: 'npm run secure-preview',
      output: 'Secure preview ready at https://localhost:8443/',
    );

    final candidates = browserPreviewCandidatesForActivity(activity);

    expect(candidates, hasLength(1));
    expect(candidates.first.host, '127.0.0.1');
    expect(candidates.first.port, 8443);
    expect(candidates.first.scheme, 'https');
    expect(candidates.first.previewLabel, 'Preview :8443');
  });

  test('findReusableBrowserPreview matches preview by session cwd and profile', () {
    const candidate = BrowserPreviewTargetCandidate(
      host: '127.0.0.1',
      port: 3000,
      scheme: 'http',
      sourceLabel: 'npm run dev',
      cwd: '/repo/app',
    );
    final previews = [
      HostBrowserPreviewInfo(
        id: 'preview-1',
        label: 'App preview',
        url: 'http://127.0.0.1:3000/',
        targetHost: '127.0.0.1',
        targetPort: 3000,
        scheme: 'http',
        cwd: '/repo/app',
        sessionId: 'session-1',
        profileMode: 'sidemesh',
        status: 'running',
        width: 390,
        height: 844,
        clients: 1,
        createdAt: 1,
        updatedAt: 2,
        lastClientAt: 2,
        lastFrameAt: 2,
        lastError: null,
      ),
      HostBrowserPreviewInfo(
        id: 'preview-2',
        label: 'Wrong profile',
        url: 'http://127.0.0.1:3000/',
        targetHost: '127.0.0.1',
        targetPort: 3000,
        scheme: 'http',
        cwd: '/repo/app',
        sessionId: 'session-1',
        profileMode: 'temporary',
        status: 'running',
        width: 390,
        height: 844,
        clients: 1,
        createdAt: 1,
        updatedAt: 2,
        lastClientAt: 2,
        lastFrameAt: 2,
        lastError: null,
      ),
    ];

    final reused = findReusableBrowserPreview(
      previews,
      candidate,
      sessionId: 'session-1',
      cwd: '/repo/app',
    );

    expect(reused?.id, 'preview-1');
  });
}

SessionActivity _activity({
  required int seq,
  String? command,
  String? output,
}) {
  return SessionActivity(
    id: 'activity-$seq',
    type: 'command',
    createdAt: DateTime.fromMillisecondsSinceEpoch(seq),
    seq: seq,
    status: 'completed',
    turnId: 'turn-$seq',
    command: command,
    cwd: '/repo',
    output: output,
    exitCode: 0,
    durationMs: 10,
    source: 'test',
    processId: 'pid-$seq',
    commandActions: const [],
    terminalStatus: null,
    terminalInput: null,
    toolName: null,
    toolTitle: null,
    toolArgs: null,
    toolResult: null,
    toolError: null,
    toolSemantic: null,
    changes: const [],
    diff: null,
    query: null,
    queries: const [],
    targetUrl: null,
    pattern: null,
    revisedPrompt: null,
    savedPath: null,
  );
}
