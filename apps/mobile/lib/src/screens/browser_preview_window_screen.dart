import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../host_store.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../widgets/mesh_widgets.dart';
import '../windowing.dart';
import 'browser_preview_screen.dart';

class BrowserPreviewWindowScreen extends StatefulWidget {
  const BrowserPreviewWindowScreen({super.key, required this.arguments});

  final SidemeshWindowArguments arguments;

  @override
  State<BrowserPreviewWindowScreen> createState() =>
      _BrowserPreviewWindowScreenState();
}

class _BrowserPreviewWindowScreenState
    extends State<BrowserPreviewWindowScreen> {
  final HostStore _hostStore = HostStore();
  final ApiClient _api = ApiClient();

  HostProfile? _host;
  String? _error;
  bool _loading = true;

  HostBrowserPreviewInfo get _preview => widget.arguments.preview!;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHost());
  }

  Future<void> _loadHost() async {
    final hostId = widget.arguments.hostId;
    if ((hostId ?? '').isEmpty) {
      setState(() {
        _error = 'This window is missing the machine for this browser tab.';
        _loading = false;
      });
      return;
    }
    try {
      final hosts = await _hostStore.loadHosts();
      HostProfile? match;
      for (final host in hosts) {
        if (host.id == hostId) {
          match = host;
          break;
        }
      }
      if (!mounted) return;
      if (match == null) {
        setState(() {
          _error = 'This machine is no longer available in this app.';
          _loading = false;
        });
        return;
      }
      if (!match.enabled) {
        setState(() {
          _error =
              'This machine is turned off here. Re-enable it in the main window to continue.';
          _loading = false;
        });
        return;
      }
      setState(() {
        _host = match;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the machine for this browser tab: $error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (_loading) {
      return Scaffold(
        backgroundColor: colors.canvas,
        body: _BrowserPreviewWindowLoadingState(preview: _preview),
      );
    }
    final host = _host;
    if (host == null) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(title: Text(_preview.label)),
        body: MeshEmptyState(
          icon: Icons.open_in_browser_rounded,
          title: 'Browser unavailable',
          body: _error ?? 'This tab could not be reopened here.',
        ),
      );
    }
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: BrowserPreviewPane(
          host: host,
          api: _api,
          preview: _preview,
          autoResizeViewport: true,
        ),
      ),
    );
  }
}

class _BrowserPreviewWindowLoadingState extends StatelessWidget {
  const _BrowserPreviewWindowLoadingState({required this.preview});

  final HostBrowserPreviewInfo preview;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              children: [
                const MeshSkeleton(width: 28, height: 28, radius: 999),
                const SizedBox(width: 8),
                const MeshSkeleton(width: 28, height: 28, radius: 999),
                const SizedBox(width: 8),
                Expanded(
                  child: MeshSurface(
                    tone: MeshSurfaceTone.muted,
                    radius: 10,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      preview.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const MeshSkeleton(width: 28, height: 28, radius: 999),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MeshCard(
                tone: MeshCardTone.muted,
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MeshSectionHeadingSkeleton(
                      titleWidthFactor: 0.2,
                      subtitleWidthFactor: 0.34,
                    ),
                    const SizedBox(height: 16),
                    const MeshSkeleton(height: 12),
                    const SizedBox(height: 8),
                    const FractionallySizedBox(
                      widthFactor: 0.58,
                      alignment: Alignment.centerLeft,
                      child: MeshSkeleton(height: 12),
                    ),
                    const SizedBox(height: 16),
                    const Expanded(
                      child: MeshSkeleton(
                        width: double.infinity,
                        height: double.infinity,
                        radius: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
