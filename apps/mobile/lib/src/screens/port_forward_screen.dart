import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api_client.dart';
import '../models.dart';
import '../port_forward_bridge.dart';
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
  if (supportsBrowserPreview && supportsPortForwarding) {
    return 'Previews & tunnels';
  }
  if (supportsBrowserPreview) {
    return 'Browser previews';
  }
  return 'Connections';
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
        title: Text(
          portForwardScreenTitle(
            supportsBrowserPreview: supportsBrowserPreview,
            supportsPortForwarding: supportsPortForwarding,
          ),
        ),
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
  final Map<String, PortForwardBridge> _bridges = {};

  List<HostPortForwardInfo> _ports = const [];
  List<HostBrowserPreviewInfo> _browserPreviews = const [];
  _ActivePortPreview? _inlinePreview;
  _ActiveBrowserPreview? _inlineBrowserPreview;
  final Set<String> _startingBrowserPreviews = {};
  bool _loading = true;
  bool _creating = false;
  bool _creatingPreview = false;
  bool _rememberBrowserLogins = true;
  String _scheme = 'http';
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.supportsPortForwarding) {
      _scheme = 'http';
    }
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
      var ports = const <HostPortForwardInfo>[];
      if (widget.supportsPortForwarding) {
        ports = await widget.api.fetchPortForwards(widget.host);
      }
      var browserPreviews = const <HostBrowserPreviewInfo>[];
      if (widget.supportsBrowserPreview) {
        browserPreviews = await widget.api.fetchBrowserPreviews(widget.host);
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
    if (!widget.supportsPortForwarding) {
      showAppSnackBar(context, 'This host does not expose TCP tunnels.');
      return;
    }
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
      showAppSnackBar(
        context,
        _scheme == 'tcp'
            ? 'Opened TCP tunnel for ${forward.target} at $uri'
            : 'Created local URL bridge for ${forward.target} at $uri',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _creating = false);
      showAppSnackBar(
        context,
        'Could not create tunnel: ${friendlyError(error)}',
      );
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
        if (_inlineBrowserPreview?.sourceForwardId == stopped.id) {
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
      showAppSnackBar(context, 'TCP tunnels do not have browser previews.');
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
      _openBrowserPreview(preview, sourceForwardId: forward.id);
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

  Future<void> _openExistingBrowserPreview(HostBrowserPreviewInfo preview) async {
    _openBrowserPreview(preview);
  }

  void _openBrowserPreview(
    HostBrowserPreviewInfo preview, {
    String? sourceForwardId,
  }) {
    final onBrowserPreviewOpened = widget.onBrowserPreviewOpened;
    if (onBrowserPreviewOpened != null) {
      onBrowserPreviewOpened(preview);
      return;
    }
    if (widget.previewPresentation == PortForwardPreviewPresentation.inline) {
      setState(() {
        _inlinePreview = null;
        _inlineBrowserPreview = _ActiveBrowserPreview(
          preview: preview,
          sourceForwardId: sourceForwardId,
        );
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
    return normalizeBrowserPreviewHost(preview.targetHost) ==
            normalizeBrowserPreviewHost(forward.targetHost) &&
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
    final browserPreviews = _browserPreviews;
    final tcpTunnels = _ports
        .where((port) => port.scheme == 'tcp')
        .toList(growable: false);
    final localUrlBridges = _ports
        .where((port) => port.scheme != 'tcp')
        .toList(growable: false);
    final hasAnyConnections = browserPreviews.isNotEmpty ||
        tcpTunnels.isNotEmpty ||
        localUrlBridges.isNotEmpty;
    final formTitle = _scheme == 'tcp'
        ? 'Tunnel a TCP service'
        : widget.supportsBrowserPreview
        ? 'Preview a localhost web app'
        : 'Create a local URL bridge';
    final formBody = _scheme == 'tcp'
        ? 'Open a raw tunnel to a service like Redis, Postgres, or any other localhost TCP port on ${widget.host.label}.'
        : widget.supportsBrowserPreview && widget.supportsPortForwarding
        ? 'Remote browser previews are the fastest way to inspect modern dev servers from ${widget.host.label}. Local URL bridges stay available as an advanced fallback.'
        : widget.supportsBrowserPreview
        ? 'Open a remote browser preview for a localhost app on ${widget.host.label}. Browser rendering stays on the host, so modern dev servers remain responsive.'
        : 'Create a local HTTP or HTTPS URL for a localhost service on ${widget.host.label}. Use TCP mode for raw socket services like Redis or Postgres.';
    final emptyTitle = widget.supportsBrowserPreview && widget.supportsPortForwarding
        ? 'No active previews or tunnels'
        : widget.supportsBrowserPreview
        ? 'No active browser previews'
        : 'No active connections';
    final emptyBody = widget.supportsBrowserPreview && widget.supportsPortForwarding
        ? 'Open a browser preview for your localhost app or create a tunnel for an advanced service.'
        : widget.supportsBrowserPreview
        ? 'Open a browser preview for a localhost app on ${widget.host.label}.'
        : 'Create a local URL bridge or TCP tunnel for a localhost service on ${widget.host.label}.';

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
                    Icon(
                      _scheme == 'tcp'
                          ? Icons.settings_ethernet_rounded
                          : Icons.open_in_browser_rounded,
                      color: colors.accent,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        formTitle,
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
                  formBody,
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
                        decoration: InputDecoration(
                          labelText: _scheme == 'tcp' ? 'TCP port' : 'Web port',
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
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Type'),
                        items: [
                          const DropdownMenuItem(
                            value: 'http',
                            child: Text('HTTP'),
                          ),
                          const DropdownMenuItem(
                            value: 'https',
                            child: Text('HTTPS'),
                          ),
                          if (widget.supportsPortForwarding)
                            const DropdownMenuItem(
                              value: 'tcp',
                              child: Text('TCP'),
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
                        decoration: InputDecoration(
                          labelText: 'Label',
                          hintText: _scheme == 'tcp' ? 'Redis' : 'Vite',
                        ),
                      ),
                    ),
                    if (_scheme != 'tcp' && widget.supportsBrowserPreview)
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
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (_scheme != 'tcp' && widget.supportsBrowserPreview)
                      FilledButton.icon(
                        onPressed: _creatingPreview ? null : _createBrowserPreviewFromInputs,
                        icon: _creatingPreview
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.open_in_browser_rounded),
                        label: const Text('Open preview'),
                      ),
                    if (widget.supportsPortForwarding)
                      OutlinedButton.icon(
                        onPressed: _creating ? null : _createForward,
                        icon: _creating
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _scheme == 'tcp'
                                    ? Icons.settings_ethernet_rounded
                                    : Icons.link_rounded,
                              ),
                        label: Text(
                          _scheme == 'tcp' ? 'Start tunnel' : 'Get local URL',
                        ),
                      ),
                  ],
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
              title: 'Could not load connections',
              body: _error!,
            )
          else if (!hasAnyConnections)
            MeshEmptyState(
              icon: widget.supportsBrowserPreview
                  ? Icons.open_in_browser_rounded
                  : Icons.settings_ethernet_rounded,
              title: emptyTitle,
              body: emptyBody,
            )
          else ...[
            if (browserPreviews.isNotEmpty) ...[
              _SectionHeading(
                icon: Icons.open_in_browser_rounded,
                title: 'Browser previews',
                subtitle: 'Remote Chromium sessions running on ${widget.host.label}',
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
              const SizedBox(height: 8),
            ],
            if (tcpTunnels.isNotEmpty) ...[
              const _SectionHeading(
                icon: Icons.settings_ethernet_rounded,
                title: 'TCP tunnels',
                subtitle: 'Raw service tunnels for databases and other socket services',
              ),
              for (final port in tcpTunnels)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildPortForwardCard(port),
                ),
              const SizedBox(height: 8),
            ],
            if (localUrlBridges.isNotEmpty) ...[
              const _SectionHeading(
                icon: Icons.link_rounded,
                title: 'Local URL bridges',
                subtitle: 'Advanced local HTTP/HTTPS bridges for native browser debugging',
              ),
              for (final port in localUrlBridges)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildPortForwardCard(port),
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildPortForwardCard(HostPortForwardInfo port) {
    final bridge = _bridges[port.id];
    final uri = bridge?.localUri;
    final browserPreview = _firstMatchingPreview(
      _browserPreviews,
      port,
    );
    return _PortForwardCard(
      port: port,
      localUri: uri,
      hasBrowserPreview: browserPreview != null,
      startingBrowserPreview: _startingBrowserPreviews.contains(port.id),
      onConnect: () => unawaited(_connectLocal(port)),
      onPreview: uri == null ? null : () => _openPreview(port, uri),
      onRemoteBrowserPreview: widget.supportsBrowserPreview && port.scheme != 'tcp'
          ? () => unawaited(_openRemoteBrowserPreview(port))
          : null,
      onExternal: uri == null ? null : () => unawaited(_openExternal(uri)),
      onCopy: uri == null ? null : () => unawaited(_copy(uri)),
      onStop: () => unawaited(_stopForward(port)),
    );
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
}

enum PortForwardPreviewPresentation { route, inline }

class _ActivePortPreview {
  const _ActivePortPreview({required this.forward, required this.uri});

  final HostPortForwardInfo forward;
  final Uri uri;
}

class _ActiveBrowserPreview {
  const _ActiveBrowserPreview({
    required this.preview,
    this.sourceForwardId,
  });

  final HostBrowserPreviewInfo preview;
  final String? sourceForwardId;
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
  final VoidCallback? onRemoteBrowserPreview;
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
                running ? Icons.lan_rounded : Icons.stop_circle_rounded,
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
                    fontWeight: AppWeights.title,
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
                  label: const Text('Connect local URL'),
                ),
              if (running && localUri != null && port.scheme != 'tcp')
                FilledButton.icon(
                  onPressed: onPreview,
                  icon: const Icon(Icons.preview_rounded),
                  label: const Text('Open local preview'),
                ),
              if (running && port.scheme != 'tcp' && onRemoteBrowserPreview != null)
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
                    hasBrowserPreview ? 'Open preview' : 'Start preview',
                  ),
                ),
              if (running && localUri != null)
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy URL'),
                ),
              if (running && localUri != null && port.scheme != 'tcp')
                OutlinedButton.icon(
                  onPressed: onExternal,
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Native browser'),
                ),
              if (running)
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
      accentStrip: running ? colors.success : colors.textTertiary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                running ? Icons.open_in_browser_rounded : Icons.stop_circle_rounded,
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
                          fontWeight: AppWeights.title,
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
