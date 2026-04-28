import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';

class LocalNotificationService with WidgetsBindingObserver {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();

  static const _approvalChannelId = 'sidemesh_approvals';
  static const _approvalChannelName = 'Approvals';
  static const _approvalChannelDescription =
      'Agent approval requests from Sidemesh hosts';
  static const _approvalAccent = Color(0xFFD69E2E);

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final ValueNotifier<NotificationRouteIntent?> routeIntent =
      ValueNotifier<NotificationRouteIntent?>(null);

  bool _initialized = false;
  bool _observingLifecycle = false;
  bool _permissionsRequested = false;
  bool _notificationsAllowed = false;
  AppLifecycleState? _lifecycleState;

  Future<void> initialize() async {
    if (_initialized || kIsWeb || !_isSupportedPlatform) return;

    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }

    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      defaultPresentAlert: false,
      defaultPresentBanner: false,
      defaultPresentList: false,
      defaultPresentSound: false,
      defaultPresentBadge: false,
    );

    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('sidemesh_notification'),
          iOS: darwinSettings,
          macOS: darwinSettings,
        ),
        onDidReceiveNotificationResponse: _handleNotificationResponse,
      );
      _initialized = true;
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      final launchResponse = launchDetails?.notificationResponse;
      if (launchDetails?.didNotificationLaunchApp == true &&
          launchResponse != null) {
        _handleNotificationResponse(launchResponse);
      }
    } catch (error) {
      debugPrint('Failed to initialize local notifications: $error');
    }
  }

  Future<void> showPendingApproval({
    required HostProfile host,
    required PendingAction action,
    bool allowPermissionPrompt = true,
  }) async {
    if (kIsWeb || !_isSupportedPlatform) return;
    await initialize();
    if (!_initialized || _isForeground) return;

    final hasPermission = allowPermissionPrompt
        ? await _ensurePermissions()
        : await _checkPermissions();
    if (!hasPermission) return;

    final copy = _approvalCopy(host: host, action: action);

    try {
      await _plugin.show(
        id: _notificationId(host.id, action.id),
        title: copy.title,
        body: copy.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _approvalChannelId,
            _approvalChannelName,
            channelDescription: _approvalChannelDescription,
            icon: 'sidemesh_notification',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            color: _approvalAccent,
            subText: copy.subtitle,
            ticker: copy.title,
            groupKey: _approvalChannelId,
            visibility: NotificationVisibility.private,
            when: action.requestedAt.millisecondsSinceEpoch,
            styleInformation: BigTextStyleInformation(
              copy.expandedBody,
              contentTitle: copy.title,
              summaryText: copy.subtitle,
            ),
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: true,
            presentBadge: true,
            subtitle: copy.subtitle,
            threadIdentifier: _approvalChannelId,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: true,
            presentBadge: true,
            subtitle: copy.subtitle,
            threadIdentifier: _approvalChannelId,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
        payload: jsonEncode({
          'type': 'approval',
          'hostId': host.id,
          'sessionId': action.sessionId,
          'actionId': action.id,
        }),
      );
    } catch (error) {
      debugPrint('Failed to show approval notification: $error');
    }
  }

  Future<bool> requestPermissions() async {
    if (kIsWeb || !_isSupportedPlatform) return false;
    await initialize();
    if (!_initialized) return false;
    return _ensurePermissions();
  }

  Future<bool> checkPermissions() async {
    if (kIsWeb || !_isSupportedPlatform) return false;
    await initialize();
    if (!_initialized) return false;
    return _checkPermissions(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  bool get _isForeground => _lifecycleState == AppLifecycleState.resumed;

  bool get isSupported => !kIsWeb && _isSupportedPlatform;

  bool get _isSupportedPlatform {
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  Future<bool> _ensurePermissions() async {
    if (_permissionsRequested) return _notificationsAllowed;
    _permissionsRequested = true;

    final bool granted;
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          granted =
              await _plugin
                  .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin
                  >()
                  ?.requestNotificationsPermission() ??
              true;
          break;
        case TargetPlatform.iOS:
          granted =
              await _plugin
                  .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin
                  >()
                  ?.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
          break;
        case TargetPlatform.macOS:
          granted =
              await _plugin
                  .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin
                  >()
                  ?.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
          break;
        case TargetPlatform.fuchsia:
        case TargetPlatform.linux:
        case TargetPlatform.windows:
          granted = false;
          break;
      }
    } catch (error) {
      debugPrint('Failed to request notification permissions: $error');
      _permissionsRequested = false;
      return false;
    }
    _notificationsAllowed = granted;
    return granted;
  }

  Future<bool> _checkPermissions({bool force = false}) async {
    if (!force && _permissionsRequested) return _notificationsAllowed;
    try {
      final bool granted;
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          granted =
              await _plugin
                  .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin
                  >()
                  ?.areNotificationsEnabled() ??
              false;
          break;
        case TargetPlatform.iOS:
          granted =
              await _plugin
                  .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin
                  >()
                  ?.checkPermissions()
                  .then((value) => value?.isEnabled ?? false) ??
              false;
          break;
        case TargetPlatform.macOS:
          granted =
              await _plugin
                  .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin
                  >()
                  ?.checkPermissions()
                  .then((value) => value?.isEnabled ?? false) ??
              false;
          break;
        case TargetPlatform.fuchsia:
        case TargetPlatform.linux:
        case TargetPlatform.windows:
          granted = false;
          break;
      }
      _notificationsAllowed = granted;
      if (granted) {
        _permissionsRequested = true;
      }
      return granted;
    } catch (error) {
      debugPrint('Failed to check notification permissions: $error');
      return false;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final intent = NotificationRouteIntent.fromPayload(response.payload);
    if (intent == null) {
      debugPrint('Sidemesh notification tapped: ${response.payload}');
      return;
    }
    routeIntent.value = intent;
  }

  void markRouteIntentHandled(NotificationRouteIntent intent) {
    if (routeIntent.value == intent) {
      routeIntent.value = null;
    }
  }

  int _notificationId(String hostId, String actionId) {
    var hash = 0;
    for (final unit in '$hostId:$actionId'.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }

  _ApprovalNotificationCopy _approvalCopy({
    required HostProfile host,
    required PendingAction action,
  }) {
    final hostLabel = _cleanLine(host.label);
    final sessionTitle = _cleanLine(action.sessionTitle ?? '');
    final kindLabel = _actionKindLabel(action.kind);
    final title = action.isApproval
        ? 'Approval waiting on $hostLabel'
        : 'Agent needs input on $hostLabel';
    final subtitle = sessionTitle.isNotEmpty ? sessionTitle : kindLabel;
    final actionTitle = _cleanLine(action.title);
    final detail = _cleanText(action.detail);
    final body = detail.isNotEmpty
        ? _compact(detail, 180)
        : actionTitle.isNotEmpty
        ? actionTitle
        : kindLabel;
    final expandedLines = <String>[
      if (actionTitle.isNotEmpty) actionTitle,
      if (detail.isNotEmpty && detail != actionTitle) detail,
      if ((action.cwd ?? '').trim().isNotEmpty) 'cwd: ${action.cwd!.trim()}',
    ];
    return _ApprovalNotificationCopy(
      title: title,
      subtitle: subtitle,
      body: body,
      expandedBody: expandedLines.isEmpty ? body : expandedLines.join('\n\n'),
    );
  }

  String _actionKindLabel(String kind) {
    return switch (kind) {
      'command' => 'Command approval',
      'tool' => 'Tool approval',
      'file_change' => 'File change approval',
      'permissions' => 'Permission request',
      'user_input' => 'Agent question',
      'elicitation' => 'Structured input request',
      '' => 'Agent request',
      _ => kind.replaceAll('_', ' '),
    };
  }

  String _cleanLine(String value) {
    return _compact(_cleanText(value).replaceAll('\n', ' '), 72);
  }

  String _cleanText(String value) {
    return value.trim().replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }

  String _compact(String value, int maxLength) {
    final trimmed = value.trim();
    if (trimmed.length <= maxLength) return trimmed;
    return '${trimmed.substring(0, maxLength - 1).trimRight()}…';
  }
}

class NotificationRouteIntent {
  const NotificationRouteIntent.approval({
    required this.hostId,
    required this.sessionId,
    required this.actionId,
  }) : type = 'approval';

  final String type;
  final String hostId;
  final String sessionId;
  final String actionId;

  static NotificationRouteIntent? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return null;
      if (json['type'] != 'approval') return null;
      final hostId = json['hostId'] as String?;
      final sessionId = json['sessionId'] as String?;
      final actionId = json['actionId'] as String?;
      if (hostId == null ||
          hostId.isEmpty ||
          sessionId == null ||
          sessionId.isEmpty ||
          actionId == null ||
          actionId.isEmpty) {
        return null;
      }
      return NotificationRouteIntent.approval(
        hostId: hostId,
        sessionId: sessionId,
        actionId: actionId,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is NotificationRouteIntent &&
        other.type == type &&
        other.hostId == hostId &&
        other.sessionId == sessionId &&
        other.actionId == actionId;
  }

  @override
  int get hashCode => Object.hash(type, hostId, sessionId, actionId);
}

class _ApprovalNotificationCopy {
  const _ApprovalNotificationCopy({
    required this.title,
    required this.subtitle,
    required this.body,
    required this.expandedBody,
  });

  final String title;
  final String subtitle;
  final String body;
  final String expandedBody;
}
