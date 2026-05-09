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

String portForwardScreenTitle({
  required bool supportsBrowserPreview,
  required bool supportsPortForwarding,
}) {
  return 'Browser previews';
}

class PortForwardScreen extends StatelessWidget {
  const PortForwardScreen({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    required this.sessionId,
    required this.sessionTitle,
    required this.supportsBrowserPreview,
    required this.supportsPortForwarding,
    this.onBrowserPreviewOpened,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String sessionId;
  final String sessionTitle;
  final bool supportsBrowserPreview;
  final bool supportsPortForwarding;
  final PortForwardBrowserPreviewOpened? onBrowserPreviewOpened;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        title: const Text('Browser previews'),
      ),
      body: PortForwardPane(
        host: host,
        api: api,
        cwd: cwd,
        sessionId: sessionId,
        sessionTitle: sessionTitle,
        supportsBrowserPreview: supportsBrowserPreview,
        supportsPortForwarding: supportsPortForwarding,
        onBrowserPreviewOpened: onBrowserPreviewOpened,
      ),
    );
  }
}

typedef PortForwardBrowserPreviewOpened =
    void Function(HostBrowserPreviewInfo preview);

class PortForwardPane extends StatefulWidget {
  const PortForwardPane({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    required this.sessionId,
    required this.sessionTitle,
    required this.supportsBrowserPreview,
    required this.supportsPortForwarding,
    this.previewPresentation = PortForwardPreviewPresentation.route,
    this.onBrowserPreviewOpened,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String sessionId;
  final String sessionTitle;
  final bool supportsBrowserPreview;
  final bool supportsPortForwarding;
  final PortForwardPreviewPresentation previewPresentation;
  final PortForwardBrowserPreviewOpened? onBrowserPreviewOpened;

  @override
  State<PortForwardPane> createState() => _PortForwardPaneState();
}

class _PortForwardPaneState extends State<PortForwardPane> {
  final _portController = TextEditingController(text: '3000');
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _labelController = TextEditingController();

  List<HostBrowserPreviewInfo> _browserPreviews = const [];
  _ActiveBrowserPreview? _inlineBrowserPreview;
  bool _loading = true;
  bool _creatingPreview = false;
  bool _rememberBrowserLogins = true;
  String _scheme = 'http';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBrowserPreviews());
  }

  @override
  void dispose() {
    _portController.dispose();
    _hostController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _loadBrowserPreviews() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final browserPreviews = widget.supportsBrowserPreview
          ? await widget.api.fetchBrowserPreviews(widget.host)
          : const <HostBrowserPreviewInfo>[];
      if (!mounted) return;
      setState(() {
        _browserPreviews = browserPreviews
            .where(
              (preview) =>
                  preview.sessionId == null ||
                  preview.sessionId == widget.sessionId,
            )
            .toList(growable: false);
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

  Future<void> _createBrowserPreviewFromInputs() async {
    if (!widget.supportsBrowserPreview) {
      showAppSnackBar(context, 'This host does not expose browser previews.');
      return;
    }
    final targetPort = int.tryParse(_portController.text.trim());
    if (targetPort == null || targetPort < 1 || targetPort > 65535) {
      showAppSnackBar(context, 'Enter a valid port between 1 and 65535.');
      return;
    }
    final rawHost = _hostController.text.trim().isEmpty
        ? '127.0.0.1'
        : _hostController.text.trim();
    final targetHost = normalizeBrowserPreviewHost(rawHost);
    if (targetHost == null) {
      showAppSnackBar(
        context,
        'Browser previews only support localhost targets.',
      );
      return;
    }
    setState(() => _creatingPreview = true);
    try {
      final previews = await widget.api.fetchBrowserPreviews(widget.host);
      final candidate = BrowserPreviewTargetCandidate(
        host: targetHost,
        port: targetPort,
        scheme: _scheme == 'https' ? 'https' : 'http',
        sourceLabel: _labelController.text.trim().isEmpty
            ? 'Preview ${targetHost == '127.0.0.1' ? 'localhost' : targetHost}:$targetPort'
            : _labelController.text.trim(),
        cwd: widget.cwd,
      );
      final existing = findReusableBrowserPreview(
        previews,
        candidate,
        sessionId: widget.sessionId,
        cwd: widget.cwd,
        profileMode: _browserProfileMode,
      );
      if (!mounted) return;
      final viewport = MediaQuery.sizeOf(context);
      final preview = existing ??
          await widget.api.createBrowserPreview(
            widget.host,
            targetPort: targetPort,
            targetHost: targetHost,
            scheme: candidate.scheme,
            label: candidate.sourceLabel,
            cwd: widget.cwd,
            sessionId: widget.sessionId,
            width: viewport.width.round().clamp(320, 1200),
            height: viewport.height.round().clamp(480, 1400),
            profileMode: _browserProfileMode,
          );
      if (!mounted) return;
      setState(() {
        _creatingPreview = false;
        _browserPreviews = [
          preview,
          ...previews.where(
            (item) =>
                item.id != preview.id &&
                (item.sessionId == null || item.sessionId == widget.sessionId),
          ),
        ];
      });
      _openBrowserPreview(preview);
    } catch (error) {
      if (!mounted) return;
      setState(() => _creatingPreview = false);
      showAppSnackBar(
        context,
        'Could not open browser preview: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _openExistingBrowserPreview(HostBrowserPreviewInfo preview) async {
    _openBrowserPreview(preview);
  }

  void _openBrowserPreview(HostBrowserPreviewInfo preview) {
    final onBrowserPreviewOpened = widget.onBrowserPreviewOpened;
    if (onBrowserPreviewOpened != null) {
      onBrowserPreviewOpened(preview);
      return;
    }
    if (widget.previewPresentation == PortForwardPreviewPresentation.inline) {
      setState(() {
        _inlineBrowserPreview = _ActiveBrowserPreview(preview: preview);
      });
      return;
    }
    unawaited(() async {
      final stopped = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => BrowserPreviewScreen(
            host: widget.host,
            api: widget.api,
            preview: preview,
          ),
        ),
      );
      if (!mounted || !(stopped ?? false)) return;
      setState(() {
        _browserPreviews = _browserPreviews
            .where((item) => item.id != preview.id)
            .toList(growable: false);
      });
    }());
  }

  Future<void> _stopBrowserPreview(HostBrowserPreviewInfo preview) async {
    try {
      final stopped = await widget.api.stopBrowserPreview(widget.host, preview.id);
      if (!mounted) return;
      setState(() {
        _inlineBrowserPreview = null;
        _browserPreviews = _browserPreviews
            .where((item) => item.id != stopped.id)
            .toList(growable: false);
      });
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not stop browser preview: ${friendlyError(error)}',
      );
    }
  }

  String get _browserProfileMode =>
      _rememberBrowserLogins ? 'sidemesh' : 'temporary';

  @override
  Widget build(BuildContext context) {
    final inlineBrowserPreview = _inlineBrowserPreview;
    if (inlineBrowserPreview != null) {
      return BrowserPreviewPane(
        key: ValueKey('browser-preview:${inlineBrowserPreview.preview.id}'),
        host: widget.host,
        api: widget.api,
        preview: inlineBrowserPreview.preview,
        onBack: () => setState(() => _inlineBrowserPreview = null),
        onStopped: (stopped) {
          setState(() {
            _inlineBrowserPreview = null;
            _browserPreviews = _browserPreviews
                .where((item) => item.id != stopped.id)
                .toList(growable: false);
          });
        },
      );
    }

    final browserPreviews = _browserPreviews;
    final colors = context.colors;
    return RefreshIndicator(
      onRefresh: _loadBrowserPreviews,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (!widget.supportsBrowserPreview)
            const MeshEmptyState(
              icon: Icons.open_in_browser_rounded,
              title: 'Browser previews unavailable',
              body: 'This host does not expose browser preview support yet.',
            )
          else ...[
            MeshCard(
              tone: MeshCardTone.elevated,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.open_in_browser_rounded,
                        color: colors.accent,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Open browser preview',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: colors.textPrimary,
                            fontWeight: AppWeights.title,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Open a live preview for a localhost web app running on ${widget.host.label}.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            hintText: '3000',
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 150,
                        child: TextField(
                          controller: _hostController,
                          decoration: const InputDecoration(
                            labelText: 'Host',
                            hintText: '127.0.0.1',
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 120,
                        child: DropdownButtonFormField<String>(
                          initialValue: _scheme,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Scheme'),
                          items: const [
                            DropdownMenuItem(
                              value: 'http',
                              child: Text('HTTP'),
                            ),
                            DropdownMenuItem(
                              value: 'https',
                              child: Text('HTTPS'),
                            ),
                          ],
                          onChanged: (value) =>
                              setState(() => _scheme = value ?? 'http'),
                        ),
                      ),
                      SizedBox(
                        width: 180,
                        child: TextField(
                          controller: _labelController,
                          decoration: const InputDecoration(
                            labelText: 'Label',
                            hintText: 'Vite app',
                          ),
                        ),
                      ),
                      FilterChip(
                        selected: _rememberBrowserLogins,
                        avatar: Icon(
                          _rememberBrowserLogins
                              ? Icons.lock_clock_rounded
                              : Icons.lock_reset_rounded,
                          size: 17,
                        ),
                        label: const Text('Remember browser logins'),
                        onSelected: (selected) =>
                            setState(() => _rememberBrowserLogins = selected),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed:
                          _creatingPreview ? null : _createBrowserPreviewFromInputs,
                      icon: _creatingPreview
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.open_in_browser_rounded),
                      label: const Text('Open preview'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              MeshEmptyState(
                icon: Icons.warning_amber_rounded,
                title: 'Could not load browser previews',
                body: _error!,
              )
            else if (browserPreviews.isEmpty)
              MeshEmptyState(
                icon: Icons.open_in_browser_rounded,
                title: 'No active browser previews',
                body:
                    'Open a browser preview for a localhost app on ${widget.host.label}.',
              )
            else ...[
              const _SectionHeading(
                icon: Icons.open_in_browser_rounded,
                title: 'Active browser previews',
                subtitle: 'Live previews running for this session',
              ),
              for (final preview in browserPreviews)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _BrowserPreviewCard(
                    preview: preview,
                    onOpen: () => unawaited(_openExistingBrowserPreview(preview)),
                    onStop: () => unawaited(_stopBrowserPreview(preview)),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

enum PortForwardPreviewPresentation { route, inline }

class _ActiveBrowserPreview {
  const _ActiveBrowserPreview({required this.preview});

  final HostBrowserPreviewInfo preview;
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.title,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserPreviewCard extends StatelessWidget {
  const _BrowserPreviewCard({
    required this.preview,
    required this.onOpen,
    required this.onStop,
  });

  final HostBrowserPreviewInfo preview;
  final VoidCallback onOpen;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = preview.status == 'running' || preview.status == 'starting';
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: running ? colors.success.withValues(alpha: 0.5) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                running
                    ? Icons.open_in_browser_rounded
                    : Icons.stop_circle_rounded,
                color: running ? colors.success : colors.textSecondary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  preview.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.title,
                  ),
                ),
              ),
              MeshPill(
                label: running ? 'LIVE' : preview.status.toUpperCase(),
                tone: running ? MeshPillTone.success : MeshPillTone.neutral,
                mono: true,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${preview.targetHost}:${preview.targetPort}',
            style: monoStyle(color: colors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            preview.url,
            style: monoStyle(color: colors.textTertiary, fontSize: 11),
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
                  label: const Text('Open preview'),
                ),
              TextButton.icon(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_rounded),
                label: const Text('Stop'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
