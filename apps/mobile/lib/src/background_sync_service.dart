import 'dart:async';

import 'package:background_fetch/background_fetch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api_client.dart';
import 'approval_action_seen_store.dart';
import 'host_store.dart';
import 'live_activity_service.dart';
import 'local_notification_service.dart';
import 'models.dart';

class BackgroundSyncService {
  BackgroundSyncService._();

  static final BackgroundSyncService instance = BackgroundSyncService._();

  static const _fetchIntervalMinutes = 15;

  bool _initialized = false;

  bool get supportsBackgroundFetch => _supportsBackgroundFetch;

  Future<void> initialize() async {
    if (_initialized || kIsWeb || !_supportsBackgroundFetch) return;
    _initialized = true;

    try {
      await BackgroundFetch.configure(
        BackgroundFetchConfig(
          minimumFetchInterval: _fetchIntervalMinutes,
          stopOnTerminate: false,
          startOnBoot: true,
          enableHeadless: true,
          requiredNetworkType: NetworkType.ANY,
        ),
        _handleFetch,
        _handleTimeout,
      );
      await BackgroundFetch.registerHeadlessTask(
        sidemeshBackgroundFetchHeadlessTask,
      );
    } catch (error) {
      debugPrint('Failed to configure background sync: $error');
    }
  }

  Future<void> _handleFetch(String taskId) async {
    try {
      await ApprovalBackgroundPoller.instance.run();
    } catch (error) {
      debugPrint('Background sync failed: $error');
    } finally {
      await BackgroundFetch.finish(taskId);
    }
  }

  Future<void> _handleTimeout(String taskId) async {
    await BackgroundFetch.finish(taskId);
  }

  bool get _supportsBackgroundFetch {
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
  }
}

class ApprovalBackgroundPoller {
  ApprovalBackgroundPoller._();

  static final ApprovalBackgroundPoller instance = ApprovalBackgroundPoller._();

  static const _perHostTimeout = Duration(seconds: 8);

  Future<void> run() async {
    if (kIsWeb) return;
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.iOS && platform != TargetPlatform.android) {
      return;
    }

    final hosts = (await HostStore().loadHosts())
        .where((host) => host.enabled)
        .toList(growable: false);
    if (hosts.isEmpty) {
      await ApprovalActionSeenStore.instance.replace(<String>{});
      await LiveActivityService.instance.clearPrimarySessionContext();
      return;
    }

    final api = ApiClient();
    final entries = <_PendingApprovalEntry>[];
    await Future.wait(
      hosts.map((host) async {
        try {
          final actions = await api
              .fetchPendingActions(host)
              .timeout(_perHostTimeout);
          entries.addAll(
            actions.map((action) {
              return _PendingApprovalEntry(host: host, action: action);
            }),
          );
        } catch (error) {
          debugPrint(
            'Background approval poll failed for ${host.label}: $error',
          );
        }
      }),
    );

    entries.sort(
      (a, b) => b.action.requestedAt.compareTo(a.action.requestedAt),
    );

    await _syncPrimarySession(hosts, api);
    await _syncLiveActivity(entries);
    await _notifyForNewActions(entries);
  }

  Future<void> _syncPrimarySession(
    List<HostProfile> hosts,
    ApiClient api,
  ) async {
    final primary = await LiveActivityService.instance
        .loadPrimarySessionContext();
    if (primary == null) return;

    HostProfile? host;
    for (final item in hosts) {
      if (item.id == primary.hostId) {
        host = item;
        break;
      }
    }
    if (host == null) {
      await LiveActivityService.instance.clearPrimarySessionContext();
      return;
    }

    try {
      final status = await api
          .fetchStatus(host, primary.sessionId)
          .timeout(_perHostTimeout);
      await LiveActivityService.instance.syncPrimarySession(
        host: host,
        session: primary.toSessionSummary(isRunning: status.isRunning),
        isRunning: status.isRunning,
        isThinking: status.isRunning && status.pendingAction == null,
        isResponding: false,
        pendingAction: status.pendingAction,
        latestActivity: null,
      );
    } catch (error) {
      debugPrint('Background primary session sync failed: $error');
    }
  }

  Future<void> _syncLiveActivity(List<_PendingApprovalEntry> entries) async {
    if (entries.isEmpty) {
      await LiveActivityService.instance.endPendingApprovals();
      return;
    }

    final newest = entries.first;
    await LiveActivityService.instance.syncPendingApprovals(
      count: entries.length,
      hostLabel: newest.host.label,
      title: newest.action.title,
      sessionTitle: newest.action.sessionTitle ?? '',
    );
  }

  Future<void> _notifyForNewActions(List<_PendingApprovalEntry> entries) async {
    final seenStore = ApprovalActionSeenStore.instance;
    final snapshot = await seenStore.load();
    final nextKeys = entries
        .map((entry) => seenStore.keyFor(entry.host, entry.action))
        .toSet();

    if (snapshot.initialized) {
      for (final entry in entries) {
        final key = seenStore.keyFor(entry.host, entry.action);
        if (snapshot.keys.contains(key)) continue;
        await LocalNotificationService.instance.showPendingApproval(
          host: entry.host,
          action: entry.action,
          allowPermissionPrompt: false,
        );
      }
    }

    await seenStore.replace(nextKeys);
  }
}

@pragma('vm:entry-point')
void sidemeshBackgroundFetchHeadlessTask(HeadlessEvent event) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (event.timeout) {
    await BackgroundFetch.finish(event.taskId);
    return;
  }

  try {
    await ApprovalBackgroundPoller.instance.run();
  } catch (error) {
    debugPrint('Headless background sync failed: $error');
  } finally {
    await BackgroundFetch.finish(event.taskId);
  }
}

class _PendingApprovalEntry {
  const _PendingApprovalEntry({required this.host, required this.action});

  final HostProfile host;
  final PendingAction action;
}
