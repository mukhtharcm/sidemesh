import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_policy_store.dart';
import 'package:sidemesh_mobile/src/session_send_overrides.dart';
import 'package:sidemesh_mobile/src/session_turn_config_store.dart';

void main() {
  test('drops unsupported and redundant session send overrides', () {
    final overrides = normalizeSessionSendOverrides(
      turnConfig: const SessionTurnConfig(
        model: 'gpt-5',
        mode: 'autopilot',
        reasoningEffort: 'medium',
        fastMode: false,
      ),
      policy: const SessionPolicy(
        approval: ApprovalPolicy.onRequest,
        sandbox: SandboxMode.workspaceWrite,
        networkAccess: false,
      ),
      runtime: const SessionRuntimeSummary(
        model: 'gpt-5',
        mode: 'interactive',
        serviceTier: 'standard',
        reasoningEffort: 'medium',
        approvalPolicy: 'on-request',
        sandboxMode: 'workspace-write',
        networkAccess: false,
      ),
      nodeInfo: _nodeForProvider(
        kind: 'codex',
        supportedApprovalPolicies: const <String>[
          'untrusted',
          'on-request',
          'never',
        ],
        runtimeControls: const <String, bool>{
          'model': true,
          'mode': false,
          'reasoningEffort': true,
          'fastMode': true,
          'approvalPolicy': true,
          'sandboxMode': true,
          'networkAccess': true,
        },
      ),
      providerKind: 'codex',
    );

    expect(overrides.model, isNull);
    expect(overrides.mode, isNull);
    expect(overrides.reasoningEffort, isNull);
    expect(overrides.fastMode, isNull);
    expect(overrides.approvalPolicy, isNull);
    expect(overrides.sandboxMode, isNull);
    expect(overrides.networkAccess, isNull);
  });

  test(
    'preserves supported overrides but clears redundant network in full access',
    () {
      final overrides = normalizeSessionSendOverrides(
        turnConfig: const SessionTurnConfig(
          model: 'gpt-5.1',
          reasoningEffort: 'high',
          fastMode: true,
        ),
        policy: const SessionPolicy(
          approval: ApprovalPolicy.never,
          sandbox: SandboxMode.dangerFullAccess,
          networkAccess: true,
        ),
        runtime: const SessionRuntimeSummary(
          model: 'gpt-5',
          serviceTier: 'standard',
          reasoningEffort: 'medium',
          approvalPolicy: 'on-request',
          sandboxMode: 'workspace-write',
          networkAccess: false,
        ),
        nodeInfo: _nodeForProvider(
          kind: 'codex',
          supportedApprovalPolicies: const <String>[
            'untrusted',
            'on-request',
            'never',
          ],
          runtimeControls: const <String, bool>{
            'model': true,
            'mode': false,
            'reasoningEffort': true,
            'fastMode': true,
            'approvalPolicy': true,
            'sandboxMode': true,
            'networkAccess': true,
          },
        ),
        providerKind: 'codex',
      );

      expect(overrides.model, 'gpt-5.1');
      expect(overrides.reasoningEffort, 'high');
      expect(overrides.fastMode, isTrue);
      expect(overrides.approvalPolicy, 'never');
      expect(overrides.sandboxMode, 'danger-full-access');
      expect(overrides.networkAccess, isNull);
    },
  );

  test(
    'drops approval policies that the current provider does not advertise',
    () {
      final overrides = normalizeSessionSendOverrides(
        turnConfig: const SessionTurnConfig(mode: 'plan'),
        policy: const SessionPolicy(approval: ApprovalPolicy.untrusted),
        runtime: const SessionRuntimeSummary(
          mode: 'interactive',
          approvalPolicy: 'on-request',
        ),
        nodeInfo: _nodeForProvider(
          kind: 'copilot',
          supportedApprovalPolicies: const <String>['on-request', 'never'],
          runtimeControls: const <String, bool>{
            'model': true,
            'mode': true,
            'reasoningEffort': true,
            'fastMode': false,
            'approvalPolicy': true,
            'sandboxMode': false,
            'networkAccess': false,
          },
        ),
        providerKind: 'copilot',
      );

      expect(overrides.mode, 'plan');
      expect(overrides.approvalPolicy, isNull);
    },
  );

  test('does not treat runtime model provider as the agent provider', () {
    final overrides = normalizeSessionSendOverrides(
      turnConfig: const SessionTurnConfig(
        model: 'gpt-5.1',
        reasoningEffort: 'high',
      ),
      policy: const SessionPolicy(),
      runtime: const SessionRuntimeSummary(
        model: 'gpt-5',
        modelProvider: 'openai',
        reasoningEffort: 'medium',
      ),
      nodeInfo: _nodeForProvider(
        kind: 'codex',
        supportedApprovalPolicies: const <String>[
          'untrusted',
          'on-request',
          'never',
        ],
        runtimeControls: const <String, bool>{
          'model': true,
          'mode': false,
          'reasoningEffort': true,
          'fastMode': true,
          'approvalPolicy': true,
          'sandboxMode': true,
          'networkAccess': true,
        },
      ),
      providerKind: null,
    );

    expect(overrides.model, 'gpt-5.1');
    expect(overrides.reasoningEffort, 'high');
  });

  test('provider access modes replace legacy access overrides', () {
    final overrides = normalizeSessionSendOverrides(
      turnConfig: const SessionTurnConfig(),
      policy: const SessionPolicy(
        approval: ApprovalPolicy.never,
        sandbox: SandboxMode.dangerFullAccess,
        networkAccess: true,
        accessMode: 'unrestricted',
      ),
      runtime: const SessionRuntimeSummary(accessMode: 'guarded'),
      nodeInfo: _nodeForProvider(
        kind: 'codex',
        supportedApprovalPolicies: const <String>[
          'untrusted',
          'on-request',
          'never',
        ],
        runtimeControls: const <String, bool>{
          'approvalPolicy': true,
          'sandboxMode': true,
          'networkAccess': true,
          'accessMode': true,
        },
      ),
      providerKind: 'codex',
    );

    expect(overrides.accessMode, 'unrestricted');
    expect(overrides.approvalPolicy, isNull);
    expect(overrides.sandboxMode, isNull);
    expect(overrides.networkAccess, isNull);
  });
}

NodeInfo _nodeForProvider({
  required String kind,
  required List<String> supportedApprovalPolicies,
  required Map<String, bool> runtimeControls,
}) {
  final capabilities = ProviderCapabilities(<String, dynamic>{
    'runtimeControls': runtimeControls,
  });
  return NodeInfo(
    label: 'Test',
    hostname: 'localhost',
    platform: 'darwin',
    codexVersion: '0.0.0',
    provider: kind,
    providerName: kind,
    providerVersion: '0.0.0',
    providerConfig: ProviderConfigSummary(kind: kind, command: kind),
    providerCapabilities: capabilities,
    defaultProviderCapabilities: capabilities,
    hostCapabilities: capabilities,
    supportedProviders: <ProviderDefinitionSummary>[
      ProviderDefinitionSummary(
        kind: kind,
        displayName: kind,
        defaultCommand: kind,
        commandEnvironmentVariables: const <String>[],
        supportedApprovalPolicies: supportedApprovalPolicies,
        capabilities: capabilities,
        config: ProviderConfigSummary(kind: kind, command: kind),
        version: '0.0.0',
        isDefault: true,
      ),
    ],
  );
}
