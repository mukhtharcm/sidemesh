import 'models.dart';
import 'provider_labels.dart';
import 'search_query.dart';

bool recentSessionMatchesQuery(
  HostProfile host,
  SessionSummary session,
  String rawQuery,
) {
  final provider = agentProviderDisplayLabel(session.provider);
  final haystack = [
    session.title,
    session.preview,
    session.cwd,
    session.provider ?? '',
    provider ?? '',
    host.label,
  ].join('\n');
  return matchesSearchQuery(haystack, rawQuery);
}
