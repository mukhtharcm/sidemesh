import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LiveActivityService {
  LiveActivityService._();

  static final LiveActivityService instance = LiveActivityService._();

  static const _channel = MethodChannel('dev.sidemesh/live_activity');
  static const _approvalActivityId = 'sidemesh.pendingApprovals';

  bool? _supported;
  String? _lastApprovalSignature;
  bool _sentEmptyApprovalEnd = false;

  Future<void> syncPendingApprovals({
    required int count,
    required String hostLabel,
    required String title,
    required String sessionTitle,
  }) async {
    if (!_isEligiblePlatform) return;
    if (count <= 0) {
      await endPendingApprovals();
      return;
    }
    _sentEmptyApprovalEnd = false;

    final headline = count == 1
        ? 'Approval needed'
        : '$count approvals waiting';
    final detail = title.trim().isEmpty
        ? 'Codex is waiting for permission.'
        : title.trim();
    final footnote = sessionTitle.trim();
    final signature = [
      count,
      hostLabel,
      headline,
      detail,
      footnote,
    ].join('\u001f');
    if (signature == _lastApprovalSignature) return;

    final supported = await _isSupported();
    if (!supported) return;

    try {
      final didSync = await _channel.invokeMethod<bool>('createOrUpdate', {
        'activityId': _approvalActivityId,
        'headline': headline,
        'detail': detail,
        'footnote': footnote,
        'status': 'approval',
        'host': hostLabel,
        'count': count,
        'updatedAtMillis': DateTime.now().millisecondsSinceEpoch.toDouble(),
      });
      if (didSync == true) {
        _lastApprovalSignature = signature;
      }
    } on MissingPluginException {
      _supported = false;
    } catch (error) {
      debugPrint('Failed to sync pending approval Live Activity: $error');
    }
  }

  Future<void> endPendingApprovals() async {
    if (!_isEligiblePlatform || _sentEmptyApprovalEnd) return;
    _lastApprovalSignature = null;
    _sentEmptyApprovalEnd = true;
    try {
      await _channel.invokeMethod<bool>('end', {
        'activityId': _approvalActivityId,
      });
    } on MissingPluginException {
      _supported = false;
    } catch (error) {
      debugPrint('Failed to end pending approval Live Activity: $error');
    }
  }

  bool get _isEligiblePlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<bool> _isSupported() async {
    final cached = _supported;
    if (cached != null) return cached;
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      _supported = supported ?? false;
    } on MissingPluginException {
      _supported = false;
    } catch (error) {
      debugPrint('Failed to check Live Activity support: $error');
      _supported = false;
    }
    return _supported ?? false;
  }
}
