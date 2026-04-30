import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api_client.dart';
import '../models.dart';
import '../port_forward_bridge.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import 'browser_preview_screen.dart';

class PortForwardScreen extends StatelessWidget {
  const PortForwardScreen({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    required this.sessionId,
    required this.sessionTitle,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String sessionId;
  final String sessionTitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        title: const Text('Ports'),
      ),
      body: PortForwardPane(
        host: host,
        api: api,
        cwd: cwd,
        sessionId: sessionId,
        sessionTitle: sessionTitle,
      ),
    );
  }
}

class PortForwardPane extends StatefulWidget {
  const PortForwardPane({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    required this.sessionId,
    required this.sessionTitle,
    this.previewPresentation = PortForwardPreviewPresentation.route,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String sessionId;
  final String sessionTitle;
  final PortForwardPreviewPresentation previewPresentation;

  @override
  State<PortForwardPane> createState() => _PortForwardPaneState();
}

class _PortForwardPaneState extends State<PortForwardPane> {
  final _portController = TextEditingController(text: '3000');
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _labelController = TextEditingController();
  final Map<String, PortForwardBridge> _bridges = {};

  List<HostPortForwardInfo> _ports = const [];
  List<HostBrowserPreviewInfo> _browserPreviews = const [];
  _ActivePortPreview? _inlinePreview;
  _ActiveBrowserPreview? _inlineBrowserPreview;
  final Set<String> _startingBrowserPreviews = {};
  bool _loading = true;
  bool _creating = false;
  bool _rememberBrowserLogins = true;
  String _scheme = 'http';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPorts());
  }

  @override
  void dispose() {
    _portController.dispose();
    _hostController.dispose();
    _labelController.dispose();
    for (final bridge in _bridges.values) {
      unawaited(bridge.dispose());
    }
    _bridges.clear();
    super.dispose();
  }

  Future<void> _loadPorts() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ports = await widget.api.fetchPortForwards(widget.host);
      var browserPreviews = const <HostBrowserPreviewInfo>[];
      try {
        browserPreviews = await widget.api.fetchBrowserPreviews(widget.host);
      } catch (_) {
        // Older daemons may support port forwarding but not browser previews.
      }
      if (!mounted) return;
      setState(() {
        _ports = ports
            .where(
              (port) =>
                  port.sessionId == null || port.sessionId == widget.sessionId,
            )
            .toList(growable: false);
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

  Future<void> _createForward() async {
    final targetPort = int.tryParse(_portController.text.trim());
    if (targetPort == null || targetPort < 1 || targetPort > 65535) {
      showAppSnackBar(context, 'Enter a valid port between 1 and 65535.');
      return;
    }
    setState(() => _creating = true);
    try {
      final forward = await widget.api.createPortForward(
        widget.host,
        targetPort: targetPort,
        targetHost: _hostController.text.trim().isEmpty
            ? '127.0.0.1'
            : _hostController.text.trim(),
        scheme: _scheme,
        label: _labelController.text.trim(),
        cwd: widget.cwd,
        sessionId: widget.sessionId,
      );
      final uri = await _startLocalBridge(forward);
      if (!mounted) return;
      setState(() {
        _ports = [forward, ..._ports.where((item) => item.id != forward.id)];
        _creating = false;
      });
      showAppSnackBar(context, 'Forwarded ${forward.target} to $uri');
    } catch (error) {
      if (!mounted) return;
      setState(() => _creating = false);
      showAppSnackBar(
        context,
        'Could not forward port: ${friendlyError(error)}',
      );
    }
  }

  Future<Uri> _startLocalBridge(HostPortForwardInfo forward) async {
    final existing = _bridges[forward.id];
    if (existing != null) {
      final uri = existing.localUri ?? await existing.start();
      return uri;
    }
    final bridge = PortForwardBridge(
      host: widget.host,
      api: widget.api,
      portForward: forward,
    );
    _bridges[forward.id] = bridge;
    return bridge.start();
  }

  Future<void> _connectLocal(HostPortForwardInfo forward) async {
    try {
      final uri = await _startLocalBridge(forward);
      if (!mounted) return;
      setState(() {});
      showAppSnackBar(context, 'Local preview ready at $uri');
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not start local preview: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _stopForward(HostPortForwardInfo forward) async {
    try {
      final bridge = _bridges.remove(forward.id);
      if (bridge != null) {
        await bridge.dispose();
      }
      final stopped = await widget.api.stopPortForward(widget.host, forward.id);
      final matchingPreviews = _browserPreviews
          .where((preview) => _matchesForward(preview, forward))
          .toList(growable: false);
      for (final preview in matchingPreviews) {
        try {
          await widget.api.stopBrowserPreview(widget.host, preview.id);
        } catch (_) {
          // The preview may already have been cleaned up by the daemon.
        }
      }
      if (!mounted) return;
      setState(() {
        if (_inlinePreview?.forward.id == stopped.id) {
          _inlinePreview = null;
        }
        if (_inlineBrowserPreview?.forward.id == stopped.id) {
          _inlineBrowserPreview = null;
        }
        _ports = _ports
            .map((item) => item.id == stopped.id ? stopped : item)
            .toList(growable: false);
        _browserPreviews = _browserPreviews
            .where(
              (preview) =>
                  !matchingPreviews.any((item) => item.id == preview.id),
            )
            .toList(growable: false);
      });
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not stop forward: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _openRemoteBrowserPreview(HostPortForwardInfo forward) async {
    if (forward.scheme == 'tcp') {
      showAppSnackBar(context, 'TCP forwards do not have browser previews.');
      return;
    }
    final viewport = MediaQuery.sizeOf(context);
    setState(() => _startingBrowserPreviews.add(forward.id));
    try {
      final previews = await widget.api.fetchBrowserPreviews(widget.host);
      final profileMode = _browserProfileMode;
      final existing = _firstMatchingPreview(
        previews,
        forward,
        profileMode: profileMode,
      );
      final preview =
          existing ??
          await widget.api.createBrowserPreview(
            widget.host,
            targetPort: forward.targetPort,
            targetHost: forward.targetHost,
            scheme: forward.scheme,
            label: forward.label,
            cwd: forward.cwd ?? widget.cwd,
            sessionId: forward.sessionId ?? widget.sessionId,
            width: viewport.width.round().clamp(320, 1200),
            height: viewport.height.round().clamp(480, 1400),
            profileMode: profileMode,
          );
      if (!mounted) return;
      setState(() {
        _browserPreviews = [
          preview,
          ...previews.where(
            (item) =>
                item.id != preview.id &&
                (item.sessionId == null || item.sessionId == widget.sessionId),
          ),
        ];
      });
      if (widget.previewPresentation == PortForwardPreviewPresentation.inline) {
        setState(() {
          _inlinePreview = null;
          _inlineBrowserPreview = _ActiveBrowserPreview(
            forward: forward,
            preview: preview,
          );
        });
        return;
      }
      final stopped = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => BrowserPreviewScreen(
            host: widget.host,
            api: widget.api,
            preview: preview,
          ),
        ),
      );
      if (!mounted) return;
      if (stopped ?? false) {
        setState(() {
          _browserPreviews = _browserPreviews
              .where((item) => item.id != preview.id)
              .toList(growable: false);
        });
      }
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not start remote browser: ${friendlyError(error)}',
      );
    } finally {
      if (mounted) {
        setState(() => _startingBrowserPreviews.remove(forward.id));
      }
    }
  }

  Future<void> _copy(Uri uri) async {
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (!mounted) return;
    showAppSnackBar(context, 'Copied ${uri.toString()}');
  }

  void _openPreview(HostPortForwardInfo forward, Uri uri) {
    if (forward.scheme == 'tcp') {
      showAppSnackBar(context, 'TCP forwards do not have a browser preview.');
      return;
    }
    if (!_supportsEmbeddedPreview) {
      unawaited(_openExternal(uri));
      return;
    }
    if (widget.previewPresentation == PortForwardPreviewPresentation.inline) {
      setState(() {
        _inlinePreview = _ActivePortPreview(forward: forward, uri: uri);
      });
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PortForwardPreviewScreen(title: forward.label, uri: uri),
      ),
    );
  }

  String get _browserProfileMode =>
      _rememberBrowserLogins ? 'sidemesh' : 'temporary';

  bool _matchesForward(
    HostBrowserPreviewInfo preview,
    HostPortForwardInfo forward, {
    String? profileMode,
  }) {
    return preview.targetHost == forward.targetHost &&
        preview.targetPort == forward.targetPort &&
        preview.scheme == forward.scheme &&
        preview.cwd == (forward.cwd ?? widget.cwd) &&
        preview.sessionId == (forward.sessionId ?? widget.sessionId) &&
        (profileMode == null || preview.profileMode == profileMode);
  }

  HostBrowserPreviewInfo? _firstMatchingPreview(
    Iterable<HostBrowserPreviewInfo> previews,
    HostPortForwardInfo forward, {
    String? profileMode,
  }) {
    for (final preview in previews) {
      if (_matchesForward(preview, forward, profileMode: profileMode) &&
          (preview.status == 'running' || preview.status == 'starting')) {
        return preview;
      }
    }
    return null;
  }

  Future<void> _openExternal(Uri uri) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || opened) return;
    showAppSnackBar(context, 'Could not open $uri');
  }

  @override
  Widget build(BuildContext context) {
    final inlinePreview = _inlinePreview;
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
    if (inlinePreview != null) {
      return _InlinePortForwardPreview(
        title: inlinePreview.forward.label,
        uri: inlinePreview.uri,
        onBack: () => setState(() => _inlinePreview = null),
      );
    }

    final colors = context.colors;
    return RefreshIndicator(
      onRefresh: _loadPorts,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          MeshCard(
            tone: MeshCardTone.elevated,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.cable_rounded, color: colors.accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Forward a dev server',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Bridge a localhost port from ${widget.host.label} into this device for previews.',
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
                          labelText: 'Target host',
                          hintText: '127.0.0.1',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: DropdownButtonFormField<String>(
                        initialValue: _scheme,
                        decoration: const InputDecoration(labelText: 'Type'),
                        items: const [
                          DropdownMenuItem(value: 'http', child: Text('HTTP')),
                          DropdownMenuItem(
                            value: 'https',
                            child: Text('HTTPS'),
                          ),
                          DropdownMenuItem(value: 'tcp', child: Text('TCP')),
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
                          hintText: 'Vite',
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
                      onSelected: _scheme == 'tcp'
                          ? null
                          : (selected) => setState(
                              () => _rememberBrowserLogins = selected,
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _creating ? null : _createForward,
                    icon: _creating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start forward'),
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
              title: 'Could not load ports',
              body: _error!,
            )
          else if (_ports.isEmpty)
            const MeshEmptyState(
              icon: Icons.cable_rounded,
              title: 'No forwarded ports',
              body:
                  'Start your dev server in the terminal, then forward its localhost port here.',
            )
          else
            ..._ports.map((port) {
              final bridge = _bridges[port.id];
              final uri = bridge?.localUri;
              final browserPreview = _firstMatchingPreview(
                _browserPreviews,
                port,
              );
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PortForwardCard(
                  port: port,
                  localUri: uri,
                  hasBrowserPreview: browserPreview != null,
                  startingBrowserPreview: _startingBrowserPreviews.contains(
                    port.id,
                  ),
                  onConnect: () => unawaited(_connectLocal(port)),
                  onPreview: uri == null ? null : () => _openPreview(port, uri),
                  onRemoteBrowserPreview: () =>
                      unawaited(_openRemoteBrowserPreview(port)),
                  onExternal: uri == null
                      ? null
                      : () => unawaited(_openExternal(uri)),
                  onCopy: uri == null ? null : () => unawaited(_copy(uri)),
                  onStop: () => unawaited(_stopForward(port)),
                ),
              );
            }),
        ],
      ),
    );
  }
}

enum PortForwardPreviewPresentation { route, inline }

class _ActivePortPreview {
  const _ActivePortPreview({required this.forward, required this.uri});

  final HostPortForwardInfo forward;
  final Uri uri;
}

class _ActiveBrowserPreview {
  const _ActiveBrowserPreview({required this.forward, required this.preview});

  final HostPortForwardInfo forward;
  final HostBrowserPreviewInfo preview;
}

bool get _supportsEmbeddedPreview =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

class _PortForwardCard extends StatelessWidget {
  const _PortForwardCard({
    required this.port,
    required this.localUri,
    required this.hasBrowserPreview,
    required this.startingBrowserPreview,
    required this.onConnect,
    required this.onPreview,
    required this.onRemoteBrowserPreview,
    required this.onExternal,
    required this.onCopy,
    required this.onStop,
  });

  final HostPortForwardInfo port;
  final Uri? localUri;
  final bool hasBrowserPreview;
  final bool startingBrowserPreview;
  final VoidCallback onConnect;
  final VoidCallback? onPreview;
  final VoidCallback onRemoteBrowserPreview;
  final VoidCallback? onExternal;
  final VoidCallback? onCopy;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = port.isRunning;
    return MeshCard(
      tone: MeshCardTone.surface,
      accentStrip: running ? colors.success : colors.textTertiary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                running ? Icons.lan_rounded : Icons.stop_circle_outlined,
                color: running ? colors.success : colors.textSecondary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  port.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              MeshPill(
                label: port.scheme.toUpperCase(),
                tone: running ? MeshPillTone.success : MeshPillTone.neutral,
                mono: true,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Remote ${port.target}',
            style: monoStyle(color: colors.textSecondary, fontSize: 12),
          ),
          if (localUri != null) ...[
            const SizedBox(height: 5),
            Text(
              'Local $localUri',
              style: monoStyle(color: colors.accent, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (running && localUri == null)
                OutlinedButton.icon(
                  onPressed: onConnect,
                  icon: const Icon(Icons.link_rounded),
                  label: const Text('Connect locally'),
                ),
              if (running && localUri != null && port.scheme != 'tcp')
                FilledButton.icon(
                  onPressed: onPreview,
                  icon: const Icon(Icons.preview_rounded),
                  label: const Text('Preview'),
                ),
              if (running && port.scheme != 'tcp')
                OutlinedButton.icon(
                  onPressed: startingBrowserPreview
                      ? null
                      : onRemoteBrowserPreview,
                  icon: startingBrowserPreview
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cast_connected_rounded),
                  label: Text(
                    hasBrowserPreview ? 'Open stream' : 'Stream pixels',
                  ),
                ),
              if (running && localUri != null)
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                ),
              if (running && localUri != null && port.scheme != 'tcp')
                OutlinedButton.icon(
                  onPressed: onExternal,
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Browser'),
                ),
              if (running)
                TextButton.icon(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class PortForwardPreviewScreen extends StatefulWidget {
  const PortForwardPreviewScreen({
    super.key,
    required this.title,
    required this.uri,
  });

  final String title;
  final Uri uri;

  @override
  State<PortForwardPreviewScreen> createState() =>
      _PortForwardPreviewScreenState();
}

class _InlinePortForwardPreview extends StatefulWidget {
  const _InlinePortForwardPreview({
    required this.title,
    required this.uri,
    required this.onBack,
  });

  final String title;
  final Uri uri;
  final VoidCallback onBack;

  @override
  State<_InlinePortForwardPreview> createState() =>
      _InlinePortForwardPreviewState();
}

class _InlinePortForwardPreviewState extends State<_InlinePortForwardPreview> {
  late final WebViewController _controller;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress);
          },
        ),
      )
      ..loadRequest(widget.uri);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.uri.toString()));
    if (!mounted) return;
    showAppSnackBar(context, 'Copied ${widget.uri.toString()}');
  }

  Future<void> _openExternal() async {
    final opened = await launchUrl(
      widget.uri,
      mode: LaunchMode.externalApplication,
    );
    if (!mounted || opened) return;
    showAppSnackBar(context, 'Could not open ${widget.uri}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: MeshCard(
            tone: MeshCardTone.surface,
            child: Row(
              children: [
                MeshIconButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back to ports',
                  onTap: widget.onBack,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.uri.toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                MeshIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Reload preview',
                  onTap: () => _controller.reload(),
                ),
                const SizedBox(width: 6),
                MeshIconButton(
                  icon: Icons.copy_rounded,
                  tooltip: 'Copy preview URL',
                  onTap: () => unawaited(_copy()),
                ),
                const SizedBox(width: 6),
                MeshIconButton(
                  icon: Icons.open_in_browser_rounded,
                  tooltip: 'Open in browser',
                  onTap: () => unawaited(_openExternal()),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_progress > 0 && _progress < 100)
                LinearProgressIndicator(value: _progress / 100),
            ],
          ),
        ),
      ],
    );
  }
}

class _PortForwardPreviewScreenState extends State<PortForwardPreviewScreen> {
  late final WebViewController _controller;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress);
          },
        ),
      )
      ..loadRequest(widget.uri);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              widget.uri.toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textSecondary, fontSize: 11),
            ),
          ],
        ),
        actions: [
          MeshIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Reload preview',
            onTap: () => _controller.reload(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_progress > 0 && _progress < 100)
            LinearProgressIndicator(value: _progress / 100),
        ],
      ),
    );
  }
}
