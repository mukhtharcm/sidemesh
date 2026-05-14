import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../host_store.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../widgets/mesh_widgets.dart';
import '../windowing.dart';
import 'session_screen.dart';

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
      return Scaffold(backgroundColor: colors.canvas, body: const MeshLoader());
    }
    if (_archived) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(title: Text(_session.title)),
        body: const MeshEmptyState(
          icon: Icons.archive_rounded,
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
          icon: Icons.desktop_mac_rounded,
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
