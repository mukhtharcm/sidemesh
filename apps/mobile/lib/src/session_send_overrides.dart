import 'models.dart';
import 'session_policy_store.dart';
import 'session_turn_config_store.dart';

class SessionSendOverrides {
  const SessionSendOverrides({required this.turnConfig, required this.policy});

  final SessionTurnConfig turnConfig;
  final SessionPolicy policy;

  String? get model => _trimmedOrNull(turnConfig.model);
  String? get mode => _trimmedOrNull(turnConfig.mode);
  String? get reasoningEffort => _trimmedOrNull(turnConfig.reasoningEffort);
  bool? get fastMode => turnConfig.fastMode;
  String? get approvalPolicy => policy.approval?.wire;
  String? get sandboxMode => policy.sandbox?.wire;
  bool? get networkAccess => policy.networkAccess;
}

SessionSendOverrides normalizeSessionSendOverrides({
  required SessionTurnConfig turnConfig,
  required SessionPolicy policy,
  required SessionRuntimeSummary? runtime,
  required NodeInfo? nodeInfo,
  required String? providerKind,
}) {
  final resolvedProviderKind = _trimmedOrNull(providerKind);
  final capabilities = nodeInfo?.capabilitiesForProvider(resolvedProviderKind);
  final providerSummary = nodeInfo?.providerSummary(resolvedProviderKind);
  final runtimeModel = _trimmedOrNull(runtime?.model);
  final runtimeMode = _trimmedOrNull(runtime?.mode);
  final runtimeReasoning = _trimmedOrNull(runtime?.reasoningEffort);
  final runtimeFastMode = runtime?.serviceTier == 'fast';
  final runtimeApproval = ApprovalPolicy.fromWire(runtime?.approvalPolicy);
  final runtimeSandbox = SandboxMode.fromWire(runtime?.sandboxMode);
  final runtimeNetworkAccess = runtime?.networkAccess;

  var model = _trimmedOrNull(turnConfig.model);
  var mode = _trimmedOrNull(turnConfig.mode);
  var reasoningEffort = _trimmedOrNull(turnConfig.reasoningEffort);
  var fastMode = turnConfig.fastMode;
  var approval = policy.approval;
  var sandbox = policy.sandbox;
  var networkAccess = policy.networkAccess;

  bool supports(String feature) =>
      capabilities == null || capabilities.supports('runtimeControls', feature);

  if (!supports('model')) {
    model = null;
  } else if (runtimeModel != null && model == runtimeModel) {
    model = null;
  }

  if (!supports('mode')) {
    mode = null;
  } else if (runtimeMode != null && mode == runtimeMode) {
    mode = null;
  }

  if (!supports('reasoningEffort')) {
    reasoningEffort = null;
  } else if (model == null &&
      runtimeReasoning != null &&
      reasoningEffort == runtimeReasoning) {
    reasoningEffort = null;
  }

  if (!supports('fastMode')) {
    fastMode = null;
  } else if (model == null && fastMode != null && fastMode == runtimeFastMode) {
    fastMode = null;
  }

  if (!supports('approvalPolicy')) {
    approval = null;
  } else {
    final supportedPolicies =
        providerSummary?.supportedApprovalPolicies ?? const <String>[];
    if (approval != null &&
        supportedPolicies.isNotEmpty &&
        !supportedPolicies.contains(approval.wire)) {
      approval = null;
    } else if (runtimeApproval != null && approval == runtimeApproval) {
      approval = null;
    }
  }

  if (!supports('sandboxMode')) {
    sandbox = null;
  } else if (runtimeSandbox != null && sandbox == runtimeSandbox) {
    sandbox = null;
  }

  final effectiveSandbox = sandbox ?? runtimeSandbox;
  if (!supports('networkAccess')) {
    networkAccess = null;
  } else if (effectiveSandbox == SandboxMode.dangerFullAccess) {
    networkAccess = null;
  } else if (runtimeNetworkAccess != null &&
      networkAccess == runtimeNetworkAccess) {
    networkAccess = null;
  }

  return SessionSendOverrides(
    turnConfig: SessionTurnConfig(
      model: model,
      mode: mode,
      reasoningEffort: reasoningEffort,
      fastMode: fastMode,
    ),
    policy: SessionPolicy(
      approval: approval,
      sandbox: sandbox,
      networkAccess: networkAccess,
    ),
  );
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
