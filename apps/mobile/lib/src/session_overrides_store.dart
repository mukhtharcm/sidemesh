import 'package:flutter/foundation.dart';

import 'models.dart';

/// In-memory overrides for [SessionSummary] fields that the user has
/// just mutated locally (rename, archive, etc.).
///
/// The recents and host detail screens poll session lists on a cadence,
/// so without this store a freshly-renamed session shows its old title
/// until the next fetch. Pushing an override here lets every list that
/// displays the session update immediately, and we keep applying the
/// override on top of subsequent fetches until the server catches up
/// (matched by updatedAt).
class SessionOverridesStore extends ChangeNotifier {
  SessionOverridesStore._();

  static final SessionOverridesStore instance = SessionOverridesStore._();

  final Map<String, SessionSummary> _overrides = <String, SessionSummary>{};

  String _keyFor(String hostId, String sessionId) => '$hostId:$sessionId';

  /// Record a locally-confirmed summary for the given host. Replaces any
  /// existing override and notifies listeners so lists repaint.
  void apply(String hostId, SessionSummary summary) {
    _overrides[_keyFor(hostId, summary.id)] = summary;
    notifyListeners();
  }

  /// Merge overrides on top of a freshly-fetched summary. If the server
  /// has caught up (its updatedAt is at or past the override), drop the
  /// override and return the server version.
  SessionSummary overlay(String hostId, SessionSummary incoming) {
    final key = _keyFor(hostId, incoming.id);
    final override = _overrides[key];
    if (override == null) return incoming;
    if (!incoming.updatedAt.isBefore(override.updatedAt)) {
      _overrides.remove(key);
      return incoming;
    }
    // Keep the server's updatedAt so ordering reflects real activity,
    // but apply the user's pending mutations (title, status).
    return SessionSummary(
      id: incoming.id,
      title: override.title,
      preview: incoming.preview,
      cwd: incoming.cwd,
      createdAt: incoming.createdAt,
      updatedAt: incoming.updatedAt,
      source: incoming.source,
      status: incoming.status,
      runtime: incoming.runtime,
    );
  }
}
