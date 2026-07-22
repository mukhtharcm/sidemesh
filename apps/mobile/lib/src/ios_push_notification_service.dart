import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'host_store.dart';
import 'local_notification_service.dart';
import 'models.dart';

const _pushRelayUrl = String.fromEnvironment(
  'SIDEMESH_PUSH_RELAY_URL',
  defaultValue: 'https://push.sidemesh.com',
);

class IosPushNotificationService {
  IosPushNotificationService._();

  static final IosPushNotificationService instance =
      IosPushNotificationService._();

  static const _channel = MethodChannel('dev.sidemesh.mobile/apns');
  static const _credentialsKey = 'sidemesh_ios_push_credentials_v1';
  static const _requestTimeout = Duration(seconds: 10);

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  final http.Client _http = http.Client();
  final ApiClient _api = ApiClient();
  bool _initialized = false;
  Future<void>? _syncing;

  bool get isAvailable =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      _pushRelayUrl.isNotEmpty;

  Future<void> initialize() async {
    if (_initialized || !isAvailable) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final registration = _registrationFromNative(
        await _channel.invokeMapMethod<String, dynamic>('initialize'),
      );
      if (registration != null) {
        await _synchronize(registration);
      }
    } catch (error) {
      debugPrint('Failed to initialize iOS push notifications: $error');
    }
  }

  Future<void> synchronizeHosts(List<HostProfile> hosts) async {
    if (!isAvailable) return;
    final credentials = await _loadCredentials();
    if (credentials == null) return;
    await _syncHosts(
      hosts.where((host) => host.enabled).toList(growable: false),
      credentials,
    );
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'tokenChanged':
        final registration = _registrationFromNative(call.arguments);
        if (registration != null) {
          await _synchronize(registration);
        }
      case 'notificationTapped':
        final payload = call.arguments;
        if (payload is Map) {
          LocalNotificationService.instance.routeRemoteNotification(
            payload.cast<String, dynamic>(),
          );
        }
      case 'registrationFailed':
        debugPrint('APNs registration failed: ${call.arguments}');
    }
  }

  Future<void> _synchronize(_IosApnsRegistration registration) async {
    final existing = _syncing;
    if (existing != null) {
      await existing;
    }
    final operation = _synchronizeNow(registration);
    _syncing = operation;
    try {
      await operation;
    } finally {
      if (identical(_syncing, operation)) {
        _syncing = null;
      }
    }
  }

  Future<void> _synchronizeNow(_IosApnsRegistration registration) async {
    var credentials = await _loadCredentials();
    if (credentials == null || credentials.bundleId != registration.bundleId) {
      credentials = await _createInstallation(registration);
    } else {
      final updated = await _updateInstallation(credentials, registration);
      if (!updated) {
        credentials = await _createInstallation(registration);
      }
    }
    await _saveCredentials(credentials);
    await _syncHosts(
      (await HostStore().loadHosts())
          .where((host) => host.enabled)
          .toList(growable: false),
      credentials,
    );
  }

  Future<_PushCredentials> _createInstallation(
    _IosApnsRegistration registration,
  ) async {
    final response = await _http
        .post(
          Uri.parse('$_pushRelayUrl/v1/installations'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(registration.toJson()),
        )
        .timeout(_requestTimeout);
    final json = _decodeRelayResponse(response);
    return _PushCredentials(
      installationId: json['installationId'] as String,
      publishToken: json['publishToken'] as String,
      managementToken: json['managementToken'] as String,
      bundleId: registration.bundleId,
    );
  }

  Future<bool> _updateInstallation(
    _PushCredentials credentials,
    _IosApnsRegistration registration,
  ) async {
    try {
      final response = await _http
          .put(
            Uri.parse(
              '$_pushRelayUrl/v1/installations/${credentials.installationId}',
            ),
            headers: {
              'authorization': 'Bearer ${credentials.managementToken}',
              'content-type': 'application/json',
            },
            body: jsonEncode(registration.toJson()),
          )
          .timeout(_requestTimeout);
      if (response.statusCode == 401 || response.statusCode == 404) {
        return false;
      }
      _decodeRelayResponse(response);
      return true;
    } catch (error) {
      debugPrint('Failed to update APNs relay registration: $error');
      rethrow;
    }
  }

  Future<void> _syncHosts(
    List<HostProfile> hosts,
    _PushCredentials credentials,
  ) async {
    await Future.wait(
      hosts.map((host) async {
        try {
          await _api.registerPushSubscription(
            host,
            installationId: credentials.installationId,
            hostId: host.id,
            relayUrl: _pushRelayUrl,
            publishToken: credentials.publishToken,
          );
        } catch (error) {
          debugPrint('Failed to register push notifications with ${host.label}: $error');
        }
      }),
    );
  }

  _IosApnsRegistration? _registrationFromNative(dynamic value) {
    if (value is! Map) return null;
    final typed = value.cast<dynamic, dynamic>();
    final deviceToken = typed['deviceToken']?.toString() ?? '';
    final bundleId = typed['bundleId']?.toString() ?? '';
    final environment = typed['environment']?.toString() ?? '';
    if (deviceToken.isEmpty ||
        bundleId.isEmpty ||
        (environment != 'development' && environment != 'production')) {
      return null;
    }
    return _IosApnsRegistration(
      deviceToken: deviceToken,
      bundleId: bundleId,
      environment: environment,
    );
  }

  Map<String, dynamic> _decodeRelayResponse(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['error']?.toString() : null;
      throw StateError(message ?? 'Push relay returned ${response.statusCode}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Push relay returned invalid JSON');
    }
    return decoded;
  }

  Future<_PushCredentials?> _loadCredentials() async {
    try {
      final raw = await _storage.read(key: _credentialsKey);
      if (raw == null) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return _PushCredentials.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCredentials(_PushCredentials credentials) {
    return _storage.write(
      key: _credentialsKey,
      value: jsonEncode(credentials.toJson()),
    );
  }
}

class _IosApnsRegistration {
  const _IosApnsRegistration({
    required this.deviceToken,
    required this.bundleId,
    required this.environment,
  });

  final String deviceToken;
  final String bundleId;
  final String environment;

  Map<String, dynamic> toJson() => {
    'deviceToken': deviceToken,
    'bundleId': bundleId,
    'environment': environment,
  };
}

class _PushCredentials {
  const _PushCredentials({
    required this.installationId,
    required this.publishToken,
    required this.managementToken,
    required this.bundleId,
  });

  final String installationId;
  final String publishToken;
  final String managementToken;
  final String bundleId;

  factory _PushCredentials.fromJson(Map<String, dynamic> json) {
    return _PushCredentials(
      installationId: json['installationId'] as String,
      publishToken: json['publishToken'] as String,
      managementToken: json['managementToken'] as String,
      bundleId: json['bundleId'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'installationId': installationId,
    'publishToken': publishToken,
    'managementToken': managementToken,
    'bundleId': bundleId,
  };
}
