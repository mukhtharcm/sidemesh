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
      'Codex approval requests from Sidemesh hosts';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

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

    final sessionTitle = action.sessionTitle?.trim();
    final approvalTitle = action.title.trim();
    final bodyParts = [
      host.label,
      if (sessionTitle != null && sessionTitle.isNotEmpty) sessionTitle,
      if (approvalTitle.isNotEmpty) approvalTitle,
    ];

    try {
      await _plugin.show(
        id: _notificationId(host.id, action.id),
        title: 'Codex approval needed',
        body: bodyParts.join(' · '),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _approvalChannelId,
            _approvalChannelName,
            channelDescription: _approvalChannelDescription,
            icon: 'sidemesh_notification',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: true,
            presentBadge: true,
            threadIdentifier: _approvalChannelId,
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: true,
            presentBadge: true,
            threadIdentifier: _approvalChannelId,
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  bool get _isForeground => _lifecycleState == AppLifecycleState.resumed;

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

  Future<bool> _checkPermissions() async {
    if (_permissionsRequested) return _notificationsAllowed;
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
    debugPrint('Sidemesh notification tapped: ${response.payload}');
  }

  int _notificationId(String hostId, String actionId) {
    var hash = 0;
    for (final unit in '$hostId:$actionId'.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }
}
