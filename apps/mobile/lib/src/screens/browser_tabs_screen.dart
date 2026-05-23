import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_preview_candidates.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import 'browser_preview_screen.dart';

class BrowserTabsScreen extends StatelessWidget {
  const BrowserTabsScreen({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    required this.sessionId,
    this.onBrowserOpened,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String sessionId;
  final BrowserTabOpened? onBrowserOpened;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(backgroundColor: colors.canvas, title: const Text('Browser')),
      body: BrowserTabsPane(
        host: host,
        api: api,
        cwd: cwd,
        sessionId: sessionId,
        onBrowserOpened: onBrowserOpened,
      ),
    );
  }
}

typedef BrowserTabOpened = void Function(HostBrowserPreviewInfo preview);

enum BrowserTabsPresentation { route, inline }

class BrowserTabsPane extends StatefulWidget {
  const BrowserTabsPane({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    required this.sessionId,
    this.presentation = BrowserTabsPresentation.route,
    this.onBrowserOpened,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String sessionId;
  final BrowserTabsPresentation presentation;
  final BrowserTabOpened? onBrowserOpened;

  @override
  State<BrowserTabsPane> createState() => _BrowserTabsPaneState();
}

class _BrowserTabsPaneState extends State<BrowserTabsPane> {
  final _urlController = TextEditingController();

  List<HostBrowserPreviewInfo> _tabs = const [];
  HostBrowserPreviewInfo? _inlineTab;
  bool _loading = true;
  bool _opening = false;
  bool _showNewTabForm = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTabs());
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadTabs() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tabs = await widget.api.fetchBrowserPreviews(widget.host);
      if (!mounted) return;
      setState(() {
        _tabs = tabs
            .where(
              (tab) =>
                  tab.sessionId == null || tab.sessionId == widget.sessionId,
            )
            .toList(growable: false);
        _showNewTabForm = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(error);
      });
    }
  }

  Future<void> _openUrl({required bool newTab}) async {
    final parsed = parseBrowserPreviewTargetInput(_urlController.text);
    final candidate = parsed.candidate;
    if (candidate == null) {
      showAppSnackBar(context, parsed.error ?? 'Enter a valid URL.');
      return;
    }
    setState(() => _opening = true);
    try {
      final viewport = MediaQuery.sizeOf(context);
      final profileMode = browserPreviewProfileModeForTarget(candidate);
      HostBrowserPreviewInfo? existing;
      if (!newTab) {
        existing = findReusableBrowserPreview(
          _tabs,
          candidate,
          sessionId: widget.sessionId,
          cwd: widget.cwd,
          profileMode: profileMode,
        );
      }
      final tab =
          existing ??
          await widget.api.createBrowserPreview(
            widget.host,
            targetPort: candidate.port,
            targetHost: candidate.host,
            targetUrl: candidate.targetUrl,
            scheme: candidate.scheme,
            label: candidate.endpointLabel,
            cwd: candidate.cwd ?? widget.cwd,
            sessionId: widget.sessionId,
            width: viewport.width.round().clamp(320, 1200),
            height: viewport.height.round().clamp(480, 1400),
            profileMode: profileMode,
            reuseExisting: !newTab,
          );
      if (!mounted) return;
      setState(() {
        _opening = false;
        _showNewTabForm = false;
        _urlController.clear();
        _tabs = [
          tab,
          ..._tabs.where((item) => item.id != tab.id),
        ];
      });
      _openTab(tab);
    } catch (error) {
      if (!mounted) return;
      setState(() => _opening = false);
      showAppSnackBar(context, 'Could not open browser: ${friendlyError(error)}');
    }
  }

  void _openTab(HostBrowserPreviewInfo tab) {
    final onBrowserOpened = widget.onBrowserOpened;
    if (onBrowserOpened != null) {
      onBrowserOpened(tab);
      return;
    }
    if (widget.presentation == BrowserTabsPresentation.inline) {
      setState(() => _inlineTab = tab);
      return;
    }
    unawaited(() async {
      final stopped = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => BrowserPreviewScreen(
            host: widget.host,
            api: widget.api,
            preview: tab,
          ),
        ),
      );
      if (!mounted || !(stopped ?? false)) return;
      setState(() {
        _tabs = _tabs.where((item) => item.id != tab.id).toList(growable: false);
      });
    }());
  }

  Future<void> _closeTab(HostBrowserPreviewInfo tab) async {
    try {
      await widget.api.stopBrowserPreview(widget.host, tab.id);
      if (!mounted) return;
      setState(() {
        if (_inlineTab?.id == tab.id) {
          _inlineTab = null;
        }
        _tabs = _tabs
            .where((item) => item.id != tab.id)
            .toList(growable: false);
      });
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, 'Could not close tab: ${friendlyError(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final inlineTab = _inlineTab;
    if (inlineTab != null) {
      return BrowserPreviewPane(
        key: ValueKey('browser-tab:${inlineTab.id}'),
        host: widget.host,
        api: widget.api,
        preview: inlineTab,
        onBack: () => setState(() => _inlineTab = null),
        onStopped: (stopped) {
          setState(() {
            _inlineTab = null;
            _tabs = _tabs
                .where((item) => item.id != stopped.id)
                .toList(growable: false);
          });
        },
      );
    }

    final tabs = _tabs;
    return RefreshIndicator(
      onRefresh: _loadTabs,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (_loading)
            const _BrowserTabsLoadingState()
          else if (_error != null)
            MeshEmptyState(
              icon: Icons.warning_amber_rounded,
              title: 'Could not load browser',
              body: _error!,
            )
          else if (tabs.isEmpty)
            _BrowserUrlCard(
              controller: _urlController,
              opening: _opening,
              title: 'Open browser',
              onSubmit: () => _openUrl(newTab: true),
            )
          else ...[
            Row(
              children: [
                Icon(
                  Icons.tab_rounded,
                  size: 18,
                  color: context.colors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tabs',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: context.colors.textPrimary,
                      fontWeight: AppWeights.title,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _opening
                      ? null
                      : () => setState(() => _showNewTabForm = true),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('New tab'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_showNewTabForm) ...[
              _BrowserUrlCard(
                controller: _urlController,
                opening: _opening,
                title: 'New tab',
                onSubmit: () => _openUrl(newTab: true),
              ),
              const SizedBox(height: 12),
            ],
            for (final tab in tabs)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _BrowserTabCard(
                  tab: tab,
                  onOpen: () => _openTab(tab),
                  onClose: () => unawaited(_closeTab(tab)),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _BrowserUrlCard extends StatelessWidget {
  const _BrowserUrlCard({
    required this.controller,
    required this.opening,
    required this.title,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool opening;
  final String title;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.open_in_browser_rounded, color: colors.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.title,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => onSubmit(),
            decoration: const InputDecoration(
              labelText: 'URL',
              hintText: 'localhost:3000 or https://example.com',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: opening ? null : onSubmit,
              icon: opening
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded),
              label: const Text('Open'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserTabsLoadingState extends StatelessWidget {
  const _BrowserTabsLoadingState();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MeshCard(
          padding: const EdgeInsets.all(14),
          child: const MeshSectionHeadingSkeleton(
            titleWidthFactor: 0.28,
            subtitleWidthFactor: 0.54,
          ),
        ),
        const SizedBox(height: 10),
        MeshCard(
          padding: const EdgeInsets.all(14),
          child: const MeshSectionHeadingSkeleton(
            titleWidthFactor: 0.42,
            subtitleWidthFactor: 0.68,
          ),
        ),
      ],
    );
  }
}

class _BrowserTabCard extends StatelessWidget {
  const _BrowserTabCard({
    required this.tab,
    required this.onOpen,
    required this.onClose,
  });

  final HostBrowserPreviewInfo tab;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = tab.status == 'running' || tab.status == 'starting';
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: running ? colors.success.withValues(alpha: 0.5) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                running ? Icons.tab_rounded : Icons.close_rounded,
                color: running ? colors.success : colors.textSecondary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _tabTitle(tab),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.title,
                  ),
                ),
              ),
              MeshPill(
                label: running ? 'Open' : _tabStatusLabel(tab.status),
                tone: running ? MeshPillTone.success : MeshPillTone.neutral,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tab.url,
            style: monoStyle(color: colors.textSecondary, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (running)
                FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Open'),
                ),
              TextButton.icon(
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
                label: const Text('Close tab'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _tabTitle(HostBrowserPreviewInfo tab) {
  final label = tab.label.trim();
  if (label.isNotEmpty) return label;
  final uri = Uri.tryParse(tab.url);
  if (uri != null && uri.host.isNotEmpty) {
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }
  return 'Browser tab';
}

String _tabStatusLabel(String status) {
  return switch (status) {
    'starting' => 'Starting',
    'running' => 'Open',
    'stopped' => 'Closed',
    'failed' => 'Failed',
    _ =>
      status.isEmpty
          ? 'Unknown'
          : status[0].toUpperCase() + status.substring(1),
  };
}
