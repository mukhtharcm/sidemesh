import 'package:flutter/material.dart';

import '../models.dart'
    show
        ProviderModeSummary,
        kDefaultProviderModes,
        providerModeLabel;
import '../session_policy_store.dart';
import '../theme/app_tokens.dart';
import 'launch_controls.dart';

/// Immutable snapshot of the launch options the user has chosen.
///
/// All fields are nullable / optional so the same value object can describe
/// both the "new session defaults" case (a small subset) and the full
/// per-session configuration (provider, profile, model, reasoning, ...).
@immutable
class LaunchOptionsValue {
  const LaunchOptionsValue({
    this.approval = ApprovalPolicy.untrusted,
    this.sandbox = SandboxMode.workspaceWrite,
    this.fastMode = false,
    this.webSearch = false,
    this.sessionMode,
  });

  final ApprovalPolicy approval;
  final SandboxMode sandbox;
  final bool fastMode;
  final bool webSearch;

  /// One of the values in [kSessionModes] (`interactive`, `plan`,
  /// `autopilot`), or null for "provider default".
  final String? sessionMode;

  LaunchOptionsValue copyWith({
    ApprovalPolicy? approval,
    SandboxMode? sandbox,
    bool? fastMode,
    bool? webSearch,
    Object? sessionMode = _unset,
  }) {
    return LaunchOptionsValue(
      approval: approval ?? this.approval,
      sandbox: sandbox ?? this.sandbox,
      fastMode: fastMode ?? this.fastMode,
      webSearch: webSearch ?? this.webSearch,
      sessionMode: identical(sessionMode, _unset)
          ? this.sessionMode
          : sessionMode as String?,
    );
  }

  static const Object _unset = Object();
}

/// Capability flags describing which controls a given provider/host
/// supports. Controls whose flag is false are hidden, not disabled.
@immutable
class LaunchOptionsCapabilities {
  const LaunchOptionsCapabilities({
    this.supportsApprovalPolicy = true,
    this.supportsSandboxMode = true,
    this.supportsFastMode = false,
    this.supportsWebSearch = false,
    this.supportsSessionMode = false,
    this.approvalOptions = const <ApprovalPolicy>[
      ApprovalPolicy.untrusted,
      ApprovalPolicy.onFailure,
      ApprovalPolicy.onRequest,
      ApprovalPolicy.never,
    ],
  });

  final bool supportsApprovalPolicy;
  final bool supportsSandboxMode;
  final bool supportsFastMode;
  final bool supportsWebSearch;
  final bool supportsSessionMode;

  /// Subset of [ApprovalPolicy] values the provider exposes. Defaults to
  /// the full set.
  final List<ApprovalPolicy> approvalOptions;
}

/// Unified launch-options form used by the new-session defaults sheet,
/// the create-session sheet's advanced panel, and per-session overrides.
///
/// The form is intentionally **stateless and visual**: it owns no state.
/// Consumers pass a [LaunchOptionsValue] and a [ValueChanged] callback;
/// the form rebuilds with the new value on every change.
///
/// Provider-specific extensions (profile picker, model selector, reasoning
/// effort wrap) are injected via [brainExtras] so the same shell can host
/// progressively richer configurations without forcing every caller to
/// understand provider catalogs.
class LaunchOptionsForm extends StatelessWidget {
  const LaunchOptionsForm({
    super.key,
    required this.value,
    this.onChanged,
    this.onApprovalChanged,
    this.onSandboxChanged,
    this.onFastModeChanged,
    this.onWebSearchChanged,
    this.onSessionModeChanged,
    this.capabilities = const LaunchOptionsCapabilities(),
    this.sessionModes = kDefaultProviderModes,
    this.brainExtras,
    this.permissionsTrailing,
    this.dense = false,
  });

  final LaunchOptionsValue value;

  /// Convenience callback that fires whenever any field changes. Most
  /// consumers can use this alone. When a field-specific callback is
  /// also provided, both fire (the field-specific one fires first).
  final ValueChanged<LaunchOptionsValue>? onChanged;

  /// Field-specific callbacks. These fire on every tap, even when the
  /// new value matches the previously selected one — important for
  /// surfaces that need to track "user explicitly chose this" intent
  /// (e.g. profile-override touched flags in create-session).
  final ValueChanged<ApprovalPolicy>? onApprovalChanged;
  final ValueChanged<SandboxMode>? onSandboxChanged;
  final ValueChanged<bool>? onFastModeChanged;
  final ValueChanged<bool>? onWebSearchChanged;
  final ValueChanged<String?>? onSessionModeChanged;

  final LaunchOptionsCapabilities capabilities;
  final List<ProviderModeSummary> sessionModes;

  /// Optional widgets rendered above the [ApprovalPolicy] / [SandboxMode]
  /// controls. Used to inject provider profile / model / reasoning UI in
  /// surfaces where that data is available.
  final List<Widget>? brainExtras;

  /// Optional widget shown in the trailing slot of the Permissions group
  /// header — typically an "Autopilot" shortcut button.
  final Widget? permissionsTrailing;

  /// When true, internal vertical gaps shrink slightly. Used for tight
  /// surfaces like the create-session compact sheet.
  final bool dense;

  bool get _hasBrain =>
      capabilities.supportsSessionMode ||
      capabilities.supportsFastMode ||
      (brainExtras != null && brainExtras!.isNotEmpty);

  bool get _hasPermissions =>
      capabilities.supportsApprovalPolicy || capabilities.supportsSandboxMode;

  bool get _hasNetwork => capabilities.supportsWebSearch;

  double get _gap => dense ? AppSpacing.sm : AppSpacing.md;

  @override
  Widget build(BuildContext context) {
    final groups = <Widget>[
      if (_hasBrain) _buildBrainGroup(context),
      if (_hasPermissions) _buildPermissionsGroup(context),
      if (_hasNetwork) _buildNetworkGroup(context),
    ];
    if (groups.isEmpty) {
      return const SizedBox.shrink();
    }
    final children = <Widget>[];
    for (var i = 0; i < groups.length; i++) {
      if (i != 0) children.add(SizedBox(height: _gap));
      children.add(groups[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildBrainGroup(BuildContext context) {
    return LaunchControlGroup(
      icon: Icons.memory_rounded,
      title: 'Brain',
      children: [
        if (brainExtras != null) ...[
          for (var i = 0; i < brainExtras!.length; i++) ...[
            if (i != 0) const SizedBox(height: AppSpacing.sm),
            brainExtras![i],
          ],
        ],
        if (capabilities.supportsSessionMode) ...[
          if (brainExtras != null && brainExtras!.isNotEmpty)
            const SizedBox(height: AppSpacing.sm),
          LaunchChoiceWrap<String?>(
            icon: Icons.alt_route_rounded,
            label: 'Mode',
            value: value.sessionMode,
            options: <String?>[null, ...sessionModes.map((mode) => mode.id)],
            optionLabel: (mode) =>
                mode == null ? 'Default' : providerModeLabel(mode, sessionModes),
            isDefault: (mode) => mode == null,
            onChanged: (mode) {
              onSessionModeChanged?.call(mode);
              onChanged?.call(value.copyWith(sessionMode: mode));
            },
          ),
        ],
        if (capabilities.supportsFastMode) ...[
          if (capabilities.supportsSessionMode ||
              (brainExtras != null && brainExtras!.isNotEmpty))
            const SizedBox(height: AppSpacing.sm),
          LaunchSwitchRow(
            icon: Icons.bolt_rounded,
            title: 'Fast mode',
            subtitle: 'Ask for the fast service tier when supported.',
            value: value.fastMode,
            onChanged: (next) {
              onFastModeChanged?.call(next);
              onChanged?.call(value.copyWith(fastMode: next));
            },
          ),
        ],
      ],
    );
  }

  Widget _buildPermissionsGroup(BuildContext context) {
    return LaunchControlGroup(
      icon: Icons.verified_user_rounded,
      title: 'Permissions',
      trailing: permissionsTrailing,
      children: [
        if (capabilities.supportsApprovalPolicy)
          LaunchChoiceWrap<ApprovalPolicy>(
            icon: Icons.verified_user_rounded,
            label: 'Approval',
            value: value.approval,
            options: capabilities.approvalOptions,
            optionLabel: (policy) => policy.label,
            danger: (policy) => policy == ApprovalPolicy.never,
            onChanged: (policy) {
              onApprovalChanged?.call(policy);
              onChanged?.call(value.copyWith(approval: policy));
            },
          ),
        if (capabilities.supportsApprovalPolicy &&
            capabilities.supportsSandboxMode)
          const SizedBox(height: AppSpacing.sm),
        if (capabilities.supportsSandboxMode)
          LaunchChoiceWrap<SandboxMode>(
            icon: Icons.folder_special_rounded,
            label: 'Sandbox',
            value: value.sandbox,
            options: SandboxMode.values,
            optionLabel: (mode) => mode.label,
            danger: (mode) => mode == SandboxMode.dangerFullAccess,
            onChanged: (mode) {
              onSandboxChanged?.call(mode);
              onChanged?.call(value.copyWith(sandbox: mode));
            },
          ),
        const SizedBox(height: AppSpacing.sm),
        LaunchInfoLine(
          icon: Icons.info_outline_rounded,
          text: _permissionsDescription(),
        ),
      ],
    );
  }

  Widget _buildNetworkGroup(BuildContext context) {
    return LaunchControlGroup(
      icon: Icons.public_rounded,
      title: 'Network',
      children: [
        LaunchSwitchRow(
          icon: Icons.public_rounded,
          title: 'Live web search',
          subtitle: 'Starts the thread with web search enabled.',
          value: value.webSearch,
          onChanged: (next) {
            onWebSearchChanged?.call(next);
            onChanged?.call(value.copyWith(webSearch: next));
          },
        ),
      ],
    );
  }

  String _permissionsDescription() {
    final parts = <String>[
      if (capabilities.supportsApprovalPolicy) value.approval.description,
      if (capabilities.supportsSandboxMode) value.sandbox.description,
    ];
    return parts.join(' ');
  }
}
