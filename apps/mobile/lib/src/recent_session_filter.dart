import 'models.dart';
import 'provider_labels.dart';

bool recentSessionMatchesQuery(
  HostProfile host,
  SessionSummary session,
  String rawQuery,
) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) {
    return true;
  }
  final provider = agentProviderDisplayLabel(session.provider);
  return session.title.toLowerCase().contains(query) ||
      session.preview.toLowerCase().contains(query) ||
      session.cwd.toLowerCase().contains(query) ||
      (session.provider ?? '').toLowerCase().contains(query) ||
      (provider ?? '').toLowerCase().contains(query) ||
      host.label.toLowerCase().contains(query);
}
