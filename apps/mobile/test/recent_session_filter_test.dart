import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/recent_session_filter.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  test('matches recent sessions by provider kind and display label', () {
    final session = _summary(provider: 'copilot');

    expect(recentSessionMatchesQuery(host, session, 'copilot'), isTrue);
    expect(recentSessionMatchesQuery(host, session, 'GitHub'), isTrue);
    expect(recentSessionMatchesQuery(host, session, 'codex'), isFalse);
  });

  test('keeps existing title, preview, cwd, and host matching', () {
    final session = _summary(provider: 'codex');

    expect(recentSessionMatchesQuery(host, session, 'donation'), isTrue);
    expect(recentSessionMatchesQuery(host, session, 'preview'), isTrue);
    expect(recentSessionMatchesQuery(host, session, 'repo'), isTrue);
    expect(recentSessionMatchesQuery(host, session, 'macbook'), isTrue);
  });

  test('matches multi-term queries across combined fields', () {
    final session = _summary(provider: 'codex');

    expect(recentSessionMatchesQuery(host, session, 'donation repo'), isTrue);
    expect(recentSessionMatchesQuery(host, session, 'preview macbook'), isTrue);
    expect(recentSessionMatchesQuery(host, session, 'donation windows'), isFalse);
  });
}

SessionSummary _summary({required String provider}) {
  final now = DateTime(2026, 1, 1, 12);
  return SessionSummary(
    id: 'session-1',
    title: 'Donation system',
    preview: 'Preview text',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: provider,
    provider: provider,
    status: 'loaded',
    runtime: null,
    gitInfo: null,
  );
}
