import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_turn_config_store.dart';
import '../theme/app_tokens.dart';
import 'app_menu.dart';
import 'app_primitives.dart';
import 'mesh_widgets.dart';

class SessionConfigurationControls extends StatefulWidget {
  const SessionConfigurationControls({super.key, required this.api, required this.host,
    required this.session, required this.onClose});
  final ApiClient api;
  final HostProfile host;
  final SessionSummary session;
  final VoidCallback onClose;

  @override
  State<SessionConfigurationControls> createState() => _SessionConfigurationControlsState();
}

class _SessionConfigurationControlsState extends State<SessionConfigurationControls> {
  List<SessionConfigurationOption> _options = [];
  final Map<String, Object> _changes = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final runtime = await widget.api.fetchSessionConfiguration(widget.host, widget.session.id);
      if (!mounted) return;
      setState(() { _options = runtime.configurationOptions; });
    } catch (error) {
      if (mounted) setState(() { _error = friendlyError(error); });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  void _change(SessionConfigurationOption option, Object value) {
    setState(() {
      if (value == option.value) {
        _changes.remove(option.id);
      } else {
        _changes[option.id] = value;
      }
    });
  }

  Future<void> _apply() async {
    setState(() { _saving = true; _error = null; });
    try {
      for (final entry in _changes.entries.toList()) {
        final option = _options.where((option) => option.id == entry.key).firstOrNull;
        if (option == null) throw StateError('This setting is no longer available. Reload the settings.');
        final runtime = await widget.api.setSessionConfiguration(widget.host, widget.session.id, entry.key, entry.value);
        if (!mounted) return;
        setState(() { _options = runtime.configurationOptions; _changes.remove(entry.key); });
        // An old next-reply override must not undo a provider setting just applied.
        final store = SessionTurnConfigStore.instance;
        await store.ensureLoaded();
        final config = store.configFor(widget.host, widget.session.id);
        if (option.category == 'model' || option.category == 'mode' || option.category == 'thought_level') {
          await store.setConfig(widget.host, widget.session.id, config.copyWith(
            model: option.category == 'model' ? null : config.model,
            mode: option.category == 'mode' ? null : config.mode,
            reasoningEffort: option.category == 'thought_level' ? null : config.reasoningEffort,
          ));
        }
      }
      if (mounted) widget.onClose();
    } catch (error) {
      if (mounted) setState(() { _error = friendlyError(error); });
    } finally {
      if (mounted) setState(() { _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(children: [
      Flexible(child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) const MeshLoader(label: 'Loading settings'),
          if (_error != null) Padding(padding: AppPadding.mobilePage, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(_error!), TextButton(onPressed: _saving ? null : _load, child: const Text('Reload settings'))],
          )),
          if (!_loading && _error == null && _options.isEmpty)
            const MeshEmptyState.compact(icon: Icons.tune_rounded, title: 'No settings available',
              body: 'This agent has no settings for this session.'),
          for (final option in _options) AppSettingsRow(
            key: ValueKey('session-configuration-${option.id}'),
            icon: null, title: option.label, subtitle: option.description,
            trailing: option.value is bool ? Semantics(label: option.label, child: Switch(
              value: (_changes[option.id] ?? option.value) as bool,
              onChanged: _loading || _saving ? null : (value) => _change(option, value),
            )) : null,
            footer: option.value is String ? AppSelect<String>(
              value: (_changes[option.id] ?? option.value) as String,
              values: {...option.options.map((choice) => choice.value), option.value as String}.toList(),
              label: (value) {
                final choice = option.options.where((choice) => choice.value == value).firstOrNull;
                return choice == null ? value : choice.group == null ? choice.label : '${choice.group} / ${choice.label}';
              },
              expanded: true,
              onChanged: _loading || _saving || option.options.isEmpty ? null : (value) => _change(option, value),
            ) : null,
          ),
        ],
      ))),
      const Divider(height: AppStrokes.border),
      Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(onPressed: _saving ? null : widget.onClose, child: const Text('Cancel')),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(onPressed: _loading || _saving || _changes.isEmpty ? null : _apply,
            child: Text(_saving ? 'Applying…' : 'Apply')),
        ],
      )),
    ]),
  );
}
