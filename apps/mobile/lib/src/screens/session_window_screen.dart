import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../host_store.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../widgets/mesh_widgets.dart';
import '../windowing.dart';
import 'session_screen.dart';
import '../app_icons.dart';

class SessionWindowScreen extends StatefulWidget {
  const SessionWindowScreen({
    super.key,
    required this.arguments,
    this.windowId,
  });

  final SidemeshWindowArguments arguments;
  final String? windowId;

  @override
  State<SessionWindowScreen> createState() => _SessionWindowScreenState();
}

class _SessionWindowScreenState extends State<SessionWindowScreen> {
  final HostStore _hostStore = HostStore();
  final ApiClient _api = ApiClient();

  HostProfile? _host;
  String? _error;
  bool _loading = true;
  bool _archived = false;

  SessionSummary get _session => widget.arguments.session!;

  String get _screenAwakeSourceKey =>
      'window:${widget.windowId ?? 'session'}:${_session.id}';

  @override
  void initState() {
    super.initState();
    unawaited(_loadHost());
  }

  Future<void> _loadHost() async {
    final hostId = widget.arguments.hostId;
    if ((hostId ?? '').isEmpty) {
      setState(() {
        _error = 'This window is missing the machine for this session.';
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
        _error = 'Could not load the machine for this session: $error';
        _loading = false;
      });
    }
  }

  Future<void> _openSession(HostProfile host, SessionSummary session) async {
    final opened = await SidemeshSessionWindowManager.instance
        .openOrFocusSessionWindow(host: host, session: session);
    if (opened || !mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionScreen(
          host: host,
          session: session,
          api: _api,
          onArchived: _handleArchived,
          onOpenSession: (next) => unawaited(_openSession(host, next)),
          desktopMode: true,
          screenAwakeSourceKey: _screenAwakeSourceKey,
        ),
      ),
    );
  }

  void _handleArchived() {
    if (!mounted) {
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _archived = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (_loading) {
      return Scaffold(
        backgroundColor: colors.canvas,
        body: _SessionWindowLoadingState(sessionTitle: _session.title),
      );
    }
    if (_archived) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(title: Text(_session.title)),
        body: const MeshEmptyState(
          icon: AppIcons.archive_rounded,
          title: 'Session archived',
          body: 'This session was archived. You can close this window.',
        ),
      );
    }
    final host = _host;
    if (host == null) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(title: Text(_session.title)),
        body: MeshEmptyState(
          icon: AppIcons.desktop_mac_rounded,
          title: 'Session unavailable',
          body: _error ?? 'This session could not be reopened here.',
        ),
      );
    }
    return SessionScreen(
      host: host,
      session: _session,
      api: _api,
      onArchived: _handleArchived,
      onOpenSession: (session) => unawaited(_openSession(host, session)),
      desktopMode: true,
      screenAwakeSourceKey: _screenAwakeSourceKey,
    );
  }
}

class _SessionWindowLoadingState extends StatelessWidget {
  const _SessionWindowLoadingState({required this.sessionTitle});

  final String sessionTitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      bottom: false,
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          Text(
            sessionTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Loading session activity',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 18),
          const MeshCard(
            tone: MeshCardTone.muted,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MeshSectionHeadingSkeleton(
                  titleWidthFactor: 0.22,
                  subtitleWidthFactor: 0.46,
                ),
                SizedBox(height: 14),
                _SessionWindowBubbleSkeleton(widthFactor: 0.78),
                SizedBox(height: 10),
                _SessionWindowBubbleSkeleton(widthFactor: 0.56, alignEnd: true),
                SizedBox(height: 10),
                _SessionWindowBubbleSkeleton(widthFactor: 0.7),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionWindowBubbleSkeleton extends StatelessWidget {
  const _SessionWindowBubbleSkeleton({
    required this.widthFactor,
    this.alignEnd = false,
  });

  final double widthFactor;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: widthFactor,
        child: const MeshCard(
          padding: EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MeshSkeleton(height: 12),
              SizedBox(height: 8),
              MeshSkeleton(height: 12),
              SizedBox(height: 8),
              FractionallySizedBox(
                widthFactor: 0.62,
                alignment: Alignment.centerLeft,
                child: MeshSkeleton(height: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
