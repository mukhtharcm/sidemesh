import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import '../host_status_store.dart';
import '../image_blob_cache_store.dart';
import '../live_activity_service.dart';
import '../message_text_styles.dart';
import '../models.dart';
import '../fs_models.dart';
import '../pending_send_recovery.dart';
import '../provider_labels.dart';
import '../search_query.dart';
import 'browser_preview_screen.dart';
import 'create_session_sheet.dart';
import 'file_browser_screen.dart';
import 'file_viewer_screen.dart';
import 'image_viewer_screen.dart';
import 'terminal_screen.dart';
import 'inspector/inspector_browser_preview.dart';
import 'inspector/inspector_controller.dart';
import 'inspector/inspector_file_browser.dart';
import 'inspector/inspector_persistence.dart';
import 'inspector/inspector_pinned.dart';
import 'inspector/inspector_ports.dart';
import 'inspector/inspector_resources.dart';
import 'inspector/inspector_search.dart';
import 'inspector/inspector_session_hub.dart';
import 'inspector/inspector_terminal.dart';
import 'port_forward_screen.dart';
import '../session_message_seed_store.dart';
import '../session_overrides_store.dart';
import '../session_pins_store.dart';
import '../session_policy_store.dart';
import '../session_read_store.dart';
import '../session_send_outbox_store.dart';
import '../session_send_outbox_worker.dart';
import '../session_local_store.dart';
import '../session_send_overrides.dart';
import '../session_turn_config_store.dart';
import '../session_preview_candidates.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../windowing.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_sheets.dart';
import '../widgets/composer_paste_text_action.dart';
import '../widgets/markdown_content.dart';
import '../widgets/diff_view.dart';
import '../widgets/mesh_widgets.dart';
import 'package:sidemesh_mobile/src/host_reconnect_scheduler.dart';
import '../widgets/provider_badge.dart';
import '../relative_time_ticker.dart';
import '../widgets/syntax_code_block.dart';

part 'session_screen_header.dart';
part 'session_screen_composer.dart';
part 'session_screen_timeline.dart';
part 'session_screen_controls.dart';
part 'session_screen_preview.dart';

enum _TranscriptFreshnessMode { cached, reconnecting, offline }

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.host,
    required this.session,
    required this.api,
    this.onOpenSession,
    this.onArchived,
    this.initialComposerSeed,
    this.topPadding,
    this.desktopMode = false,
    this.screenAwakeSourceKey,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;
  final ValueChanged<SessionSummary>? onOpenSession;
  final VoidCallback? onArchived;
  final SessionComposerSeed? initialComposerSeed;
  // Extra top padding for embedded desktop use (to avoid overlapping the
  // transparent macOS titlebar). When null, SafeArea handles insets.
  final double? topPadding;
  final bool desktopMode;
  final String? screenAwakeSourceKey;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class SessionComposerSeed {
  const SessionComposerSeed({
    required this.text,
    this.inputItems = const <SessionInputItem>[],
  });

  final String text;
  final List<SessionInputItem> inputItems;
}

class _DockedBrowserPreview {
  const _DockedBrowserPreview({required this.preview, this.expanded = true});

  final HostBrowserPreviewInfo preview;
  final bool expanded;

  String get target => '${preview.targetHost}:${preview.targetPort}';

  _DockedBrowserPreview copyWith({
    HostBrowserPreviewInfo? preview,
    bool? expanded,
  }) {
    return _DockedBrowserPreview(
      preview: preview ?? this.preview,
      expanded: expanded ?? this.expanded,
    );
  }
}

class _DesktopSessionTitle extends StatelessWidget {
  const _DesktopSessionTitle({
    required this.session,
    required this.running,
    required this.canRename,
    required this.onRename,
  });

  final SessionSummary session;
  final bool running;
  final bool canRename;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colors.textPrimary,
              fontWeight: AppWeights.title,
              letterSpacing: AppLetterSpacing.headline,
            ),
          ),
        ),
        if (canRename) ...[
          const SizedBox(width: 5),
          Icon(Icons.edit_rounded, size: 13, color: colors.textTertiary),
        ],
      ],
    );

    final titleContent = canRename
        ? Tooltip(
            message: 'Rename session',
            child: Semantics(
              button: true,
              label: 'Rename session',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: AppShapes.badge,
                  onTap: onRename,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: title,
                  ),
                ),
              ),
            ),
          )
        : title;

    return Row(
      children: [
        if (running) ...[const LivePulse(), const SizedBox(width: 9)],
        Expanded(child: titleContent),
        const SizedBox(width: 8),
        if (session.provider != null) ...[
          AgentProviderBadge(providerKind: session.provider, compact: true),
          const SizedBox(width: 8),
        ],
        _DesktopSessionStatusBadge(running: running),
      ],
    );
  }
}

class _DesktopSessionCommandBar extends StatelessWidget {
  const _DesktopSessionCommandBar({
    required this.running,
    required this.canStop,
    required this.onStop,
    required this.onNewSession,
    required this.onMore,
  });

  final bool running;
  final bool canStop;
  final VoidCallback onStop;
  final VoidCallback onNewSession;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (running && canStop) ...[
          MeshIconButton(
            icon: Icons.stop_circle_rounded,
            tooltip: 'Stop agent',
            color: colors.danger,
            onTap: onStop,
            semanticLabel: 'Stop agent',
          ),
          const SizedBox(width: 6),
        ],
        _DesktopHeaderTextButton(
          icon: Icons.add_rounded,
          label: 'New session',
          onTap: onNewSession,
        ),
        const SizedBox(width: 6),
        MeshIconButton(
          icon: Icons.more_horiz_rounded,
          tooltip: running
              ? 'Session actions (agent running)'
              : 'Session actions',
          color: colors.textSecondary,
          onTap: onMore,
        ),
      ],
    );
  }
}

class _DesktopHeaderTextButton extends StatelessWidget {
  const _DesktopHeaderTextButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: MeshSurface(
          onTap: onTap,
          radius: AppRadii.control,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          child: SizedBox(
            height: 44,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: colors.textSecondary),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.title,
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSessionStatusBadge extends StatelessWidget {
  const _DesktopSessionStatusBadge({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = running ? colors.success : colors.textSecondary;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: running ? 0.1 : 0.06),
        borderRadius: AppShapes.badge,
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeaderStatusDot(color: color),
          const SizedBox(width: 5),
          Text(
            running ? 'running' : 'idle',
            style: monoStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopSessionHeaderDivider extends StatelessWidget
    implements PreferredSizeWidget {
  const _DesktopSessionHeaderDivider();

  @override
  Size get preferredSize => const Size.fromHeight(1);

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: context.colors.border);
  }
}

class _SessionBrowserPreviewDock extends StatelessWidget {
  const _SessionBrowserPreviewDock({
    required this.host,
    required this.api,
    required this.dockedPreview,
    required this.onExpand,
    required this.onMinimize,
    required this.onFullPage,
    required this.onClose,
    required this.onStop,
    required this.onStopped,
  });

  final HostProfile host;
  final ApiClient api;
  final _DockedBrowserPreview dockedPreview;
  final VoidCallback onExpand;
  final VoidCallback onMinimize;
  final VoidCallback onFullPage;
  final VoidCallback onClose;
  final VoidCallback onStop;
  final void Function(HostBrowserPreviewInfo preview) onStopped;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final target = dockedPreview.target;
    if (!dockedPreview.expanded) {
      return _BrowserDockShell(
        compact: true,
        onTap: onExpand,
        child: Row(
          children: [
            _BrowserDockGlyph(colors: colors, compact: true),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          dockedPreview.preview.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.15,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      MeshPill(
                        label: 'paused',
                        tone: MeshPillTone.warning,
                        icon: Icons.pause_rounded,
                        mono: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Tap to reopen · $target',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _BrowserDockCloseButton(
              icon: Icons.close_rounded,
              tooltip: 'Hide preview',
              onTap: onClose,
            ),
          ],
        ),
      );
    }

    final screenHeight = MediaQuery.sizeOf(context).height;
    final dockHeight = math.min(math.max(screenHeight * 0.48, 330.0), 520.0);
    return _BrowserDockShell(
      height: dockHeight,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 9),
            child: Row(
              children: [
                _BrowserDockGlyph(colors: colors),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Browser preview',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: colors.textSecondary,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.35,
                                ),
                          ),
                          const SizedBox(width: 8),
                          MeshPill(
                            label: 'open',
                            tone: MeshPillTone.success,
                            icon: Icons.bolt_rounded,
                            mono: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        dockedPreview.preview.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.35,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _BrowserDockAction(
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: 'Minimize',
                  onTap: onMinimize,
                ),
                const SizedBox(width: 6),
                _BrowserDockAction(
                  icon: Icons.fullscreen_rounded,
                  tooltip: 'Full page',
                  color: colors.accent,
                  onTap: onFullPage,
                ),
                const SizedBox(width: 6),
                _BrowserDockAction(
                  icon: Icons.stop_circle_rounded,
                  tooltip: 'Stop remote browser',
                  color: colors.danger,
                  onTap: onStop,
                ),
              ],
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(24),
              ),
              child: BrowserPreviewPane(
                key: ValueKey(
                  'session-browser-preview:${dockedPreview.preview.id}',
                ),
                host: host,
                api: api,
                preview: dockedPreview.preview,
                showHeader: false,
                onStopped: onStopped,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserDockShell extends StatelessWidget {
  const _BrowserDockShell({
    required this.child,
    this.height,
    this.compact = false,
    this.onTap,
  });

  final Widget child;
  final double? height;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(compact ? 22 : 28);
    final content = Container(
      height: height,
      margin: EdgeInsets.fromLTRB(10, compact ? 6 : 4, 10, 8),
      padding: compact ? const EdgeInsets.fromLTRB(11, 10, 8, 10) : null,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: colors.borderStrong.withValues(alpha: 0.7)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surfaceElevated,
            colors.surfaceMuted.withValues(alpha: 0.96),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: colors.accent.withValues(alpha: 0.10),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -42,
            top: -54,
            child: IgnorePointer(
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.accent.withValues(alpha: 0.07),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: radius, onTap: onTap, child: content),
    );
  }
}

class _BrowserDockGlyph extends StatelessWidget {
  const _BrowserDockGlyph({required this.colors, this.compact = false});

  final AppColors colors;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 38.0 : 44.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(compact ? 14 : 16),
        border: Border.all(color: colors.accent.withValues(alpha: 0.28)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: compact ? 18 : 22,
            height: compact ? 18 : 22,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: colors.accent, width: 1.5),
            ),
          ),
          Positioned(
            right: compact ? 8 : 9,
            top: compact ? 8 : 9,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.success,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserDockAction extends StatelessWidget {
  const _BrowserDockAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = color ?? colors.textSecondary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: fg.withValues(alpha: 0.20)),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: fg),
          ),
        ),
      ),
    );
  }
}

class _BrowserDockCloseButton extends StatelessWidget {
  const _BrowserDockCloseButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(icon, size: 17, color: colors.textTertiary),
          ),
        ),
      ),
    );
  }
}

enum _ActivityMergeMode { incremental, snapshot }

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  static const _initialMessageLimit = 120;
  static const _initialActivityLimit = 80;
  static const _messagePageSize = 120;
  static const _activityPageSize = 80;
  static const _liveUpdateFlushInterval = Duration(milliseconds: 48);
  static const _sessionCacheWriteDebounce = Duration(milliseconds: 900);
  static const _failedSendRetryWindow = Duration(minutes: 10);
  static const _maxDraftImageCount = 4;
  static const _maxDraftImageBytes = 5 * 1024 * 1024;
  static const _maxDraftPayloadBytes = 9 * 1024 * 1024;
  static const _maxDecodedDraftImageBytes = 18 * 1024 * 1024;
  static const List<FileFormat> _clipboardImageFormats = <FileFormat>[
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.gif,
    Formats.bmp,
    Formats.heic,
    Formats.heif,
  ];

  final _composerController = TextEditingController();
  final _searchController = TextEditingController();
  final _composerFocusNode = FocusNode(debugLabel: 'session_composer');
  final _searchFocusNode = FocusNode(debugLabel: 'session_search');
  final _scrollController = ScrollController();
  final SessionLocalStore _localStore = SessionLocalStore.instance;
  final SessionPinsStore _pinsStore = SessionPinsStore.instance;
  final SessionPolicyStore _policyStore = SessionPolicyStore.instance;
  final SessionReadStore _readStore = SessionReadStore.instance;
  final SessionSendOutboxStore _sendOutbox = SessionSendOutboxStore.instance;
  final SessionTurnConfigStore _turnConfigStore =
      SessionTurnConfigStore.instance;
  final StringBuffer _assistantDeltaBuffer = StringBuffer();
  final StringBuffer _reasoningDeltaBuffer = StringBuffer();
  final Map<String, SessionActivity> _pendingActivityUpdates =
      <String, SessionActivity>{};

  // Live-streaming state is held in notifiers so that mid-stream deltas only
  // rebuild the tiny widgets that display them, not the whole Scaffold/list.
  final ValueNotifier<_LiveAssistantMessageState?> _liveAssistantNotifier =
      ValueNotifier<_LiveAssistantMessageState?>(null);
  final ValueNotifier<bool> _thinkingNotifier = ValueNotifier<bool>(false);

  SessionSummary? _session;
  List<SessionMessage> _messages = const [];
  List<SessionMessage> _optimisticMessages = const [];
  List<SessionActivity> _activities = const [];
  List<_ComposerImageAttachment> _draftAttachments =
      const <_ComposerImageAttachment>[];
  List<_ComposerSkillMention> _draftSkillMentions =
      const <_ComposerSkillMention>[];
  List<_ComposerFileMention> _draftFileMentions =
      const <_ComposerFileMention>[];
  List<PendingSessionSend> _pendingSends = const <PendingSessionSend>[];
  List<SkillSummary> _skills = const <SkillSummary>[];
  List<FsSearchResult> _fileSuggestions = const <FsSearchResult>[];
  NodeInfo? _nodeInfo;
  _ActiveComposerSkillQuery? _activeSkillQuery;
  _ActiveComposerFileQuery? _activeFileQuery;
  SessionLogHistorySummary? _history;
  PendingAction? _pendingAction;
  List<_TimelineLiveEventRecord> _timelineLiveEvents =
      const <_TimelineLiveEventRecord>[];
  LiveEvent? _latestThreadStatus;
  LiveEvent? _latestQueueUpdate;
  LiveEvent? _latestAutoRetryUpdate;
  _DockedBrowserPreview? _dockedBrowserPreview;
  String? _activeInspectorBrowserPreviewId;
  int _messageLimit = _initialMessageLimit;
  int _activityLimit = _initialActivityLimit;
  bool _running = false;
  bool _composerFocused = false;
  bool _loading = true;
  bool _loadingOlderHistory = false;
  bool _sending = false;
  bool _awaitingAssistantReply = false;
  bool _loadingSkills = false;
  bool _loadingFileSearch = false;
  bool _loadingNodeInfo = false;
  bool _showingCachedSnapshot = false;
  bool _snapshotRefreshing = false;
  bool _showingPossiblyStaleSnapshot = false;
  bool _resumeSyncing = false;
  bool _resumeSyncFailed = false;
  String _searchQuery = '';
  String? _skillsError;
  String? _fileSearchError;
  String? _failedSendRetryClientMessageId;
  String? _failedSendRetrySignature;
  DateTime? _failedSendRetryExpiresAt;
  DateTime? _lastComposerBlurAt;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _liveFlushTimer;
  Timer? _sessionCachePersistTimer;
  Timer? _pendingSendRetryTimer;
  bool _disposed = false;
  bool _retryingPendingSend = false;
  final Set<String> _completedPendingSendIds = <String>{};
  bool _initialDesktopComposerFocusQueued = false;
  bool _restoreComposerFocusOnResume = false;
  bool _keepSessionUnread = false;
  int? _lastEventSeq;
  // Incremented whenever a fresh snapshot is requested so in-flight responses
  // from older requests can be discarded.
  int _snapshotRequestId = 0;
  // Buffer live events that arrive while a snapshot is in flight so we can
  // replay them after the snapshot's setState runs — prevents a stale
  // snapshot from clobbering an already-delivered action_opened / activity.
  final List<LiveEvent> _pendingLiveEvents = <LiveEvent>[];
  int? _snapshotInFlightRequestId;
  int _skillsRequestId = 0;
  int _fileSearchRequestId = 0;
  int _nodeInfoRequestId = 0;

  // Memoized timeline entries so rebuilds that don't change list inputs skip
  // the list+sort work.
  List<SessionMessage>? _entriesMessagesRef;
  List<SessionMessage>? _entriesOptimisticRef;
  List<SessionActivity>? _entriesActivitiesRef;
  List<_TimelineLiveEventRecord>? _entriesTimelineEventsRef;
  String? _entriesLiveAssistantId;
  List<_TimelineEntry> _cachedEntries = const [];

  _LiveAssistantMessageState? get _liveAssistantMessage =>
      _liveAssistantNotifier.value;

  String get _liveAssistantText => _liveAssistantMessage?.text ?? '';
  _TranscriptFreshnessMode? get _transcriptFreshnessMode {
    if (_showingCachedSnapshot) {
      return _TranscriptFreshnessMode.cached;
    }
    if (!_showingPossiblyStaleSnapshot) {
      return null;
    }
    return _resumeSyncFailed
        ? _TranscriptFreshnessMode.offline
        : _TranscriptFreshnessMode.reconnecting;
  }

  String? get _lastConnectedLabel {
    final status = HostStatusStore.instance.statusFor(widget.host.id);
    final last = status.lastEventAt ?? status.lastOnlineAt;
    if (last == null) {
      return null;
    }
    final elapsed = DateTime.now().difference(last);
    if (elapsed.inSeconds < 5) {
      return 'just now';
    }
    if (elapsed.inMinutes < 1) {
      return '${elapsed.inSeconds}s';
    }
    if (elapsed.inHours < 1) {
      return '${elapsed.inMinutes}m';
    }
    return '${elapsed.inHours}h';
  }

  // Surfaces a "↓ New" pill when the user has scrolled away from the
  // bottom of the transcript so they can jump back to the live area.
  final ValueNotifier<bool> _showJumpToLatest = ValueNotifier<bool>(false);

  // Tracks which old-snapshot history banners the user has dismissed
  // this session. Reset whenever a brand-new snapshot arrives so the
  // banner can reappear if the truncation window changes.
  bool _historyBannerDismissed = false;
  SessionGitStatus? _gitStatus;
  bool _gitStatusLoading = false;
  String? _gitStatusError;
  int _gitStatusRequestId = 0;

  bool get _snapshotInFlight => _snapshotInFlightRequestId != null;

  bool _supportsProviderCapability(String section, String feature) {
    final node = _nodeInfo;
    if (node == null) return true;
    return node
        .capabilitiesForProvider(widget.session.provider)
        .supports(section, feature);
  }

  bool _supportsHostCapability(String section, String feature) {
    final node = _nodeInfo;
    if (node == null) return true;
    return node.supportsHostCapability(section, feature);
  }

  bool get _supportsImageInput =>
      _supportsProviderCapability('input', 'imageUrl');

  bool get _supportsSkillInput =>
      _supportsProviderCapability('input', 'skills') &&
      _supportsProviderCapability('configuration', 'skills');

  bool get _supportsFileMentions =>
      _supportsProviderCapability('input', 'fileMentions');

  bool get _supportsSessionResources =>
      _supportsProviderCapability('sessions', 'history');

  bool get _supportsSessionInterrupt =>
      _supportsProviderCapability('sessions', 'interrupt');

  bool get _supportsSessionRename =>
      _supportsProviderCapability('sessions', 'rename');

  bool get _supportsSessionArchive =>
      _supportsProviderCapability('sessions', 'archive');

  bool get _supportsSessionCompact =>
      _supportsProviderCapability('sessions', 'compact');

  bool get _supportsFilesystem =>
      _supportsHostCapability('workspace', 'filesystem');

  bool get _supportsGitStatus =>
      _supportsHostCapability('workspace', 'gitStatus');

  bool get _supportsTerminal =>
      _supportsHostCapability('workspace', 'terminal');

  bool get _supportsPortForwarding =>
      _supportsHostCapability('workspace', 'portForwarding');

  bool get _supportsBrowserPreview =>
      _supportsHostCapability('workspace', 'browserPreview');

  // TCP / local tunnel UI is intentionally hidden for now. Keep the server
  // capability intact, but only surface the browser-preview path in the app.
  bool get _supportsConnections => _supportsBrowserPreview;

  bool get _supportsProviderRestart =>
      _supportsProviderCapability('lifecycle', 'restart');

  bool get _supportsComposerModelPicker =>
      _supportsProviderCapability('configuration', 'models') &&
      _supportsProviderCapability('runtimeControls', 'model');

  bool get _supportsComposerThinkingPicker =>
      _supportsComposerModelPicker &&
      _supportsProviderCapability('runtimeControls', 'reasoningEffort');

  bool _supportsGitDiffKind(String kind) {
    if (kind == 'remote') {
      return _supportsProviderCapability('workspace', 'remoteGitDiff');
    }
    return _supportsHostCapability('workspace', 'gitDiff');
  }

  // Inspector (desktop pane-3) lifecycle tracking. Resolved in
  // [didChangeDependencies] so we can addListener/removeListener around
  // the same controller instance exposed by the shell's InspectorScope.
  InspectorController? _inspectorController;
  bool _inspectorRestoreAttempted = false;
  bool _inspectorSawOurSurface = false;
  InspectorSurfaceKind? _lastInspectorSurfaceKind;

  // Ticks whenever the timeline inputs change so pane-3 surfaces
  // (currently the search panel) can rebuild with fresh records. A
  // simple ValueNotifier<int> is the lightest way to bridge the
  // session screen's state into a sibling pane.
  final ValueNotifier<int> _timelineRevision = ValueNotifier<int>(0);

  void _clearLiveAssistantMessage() {
    _liveAssistantNotifier.value = null;
    _reasoningDeltaBuffer.clear();
  }

  String get _screenAwakeSourceKey =>
      widget.screenAwakeSourceKey ??
      'session:${widget.host.id}:${widget.session.id}';

  String get _reconnectSlotId => 'session-live:${widget.session.id}';

  void _syncScreenAwakeSource() {
    WindowScreenAwakeCoordinator.instance.setSourceActive(
      _screenAwakeSourceKey,
      _running,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pinsStore.ensureLoaded();
    _pinsStore.addListener(_handlePinsChanged);
    _sendOutbox.addListener(_handleSendOutboxChanged);
    _policyStore.ensureLoaded();
    unawaited(
      _turnConfigStore.ensureLoaded().then((_) {
        if (mounted && !_disposed) {
          setState(() {});
        }
      }),
    );
    _readStore.ensureLoaded();
    _composerController.addListener(_handleComposerChanged);
    _composerFocusNode.addListener(_handleComposerFocusChanged);
    _searchController.addListener(_handleSearchChanged);
    _session = widget.session;
    _applyInitialComposerSeed();
    _optimisticMessages = SessionMessageSeedStore.instance.take(
      widget.host,
      widget.session.id,
    );
    _scrollController.addListener(_onTranscriptScroll);
    _scheduleMarkCurrentSessionSeen();
    unawaited(_loadPendingSends());
    unawaited(_bootstrapSnapshot());
    unawaited(_loadNodeInfo());
    HostReconnectScheduler.instance.registerSlot(
      widget.host.id,
      _reconnectSlotId,
      ReconnectPriority.foregroundSession,
      () {
        unawaited(_refreshSessionFreshness(scrollToBottom: false));
        _connectLive();
      },
    );
    _connectLive();
  }

  Future<void> _bootstrapSnapshot() async {
    final loadedCache = await _loadCachedSnapshot();
    if (!mounted || _disposed) {
      return;
    }
    if (loadedCache) {
      _queueInitialDesktopComposerFocus();
      unawaited(_refreshSessionFreshness());
      return;
    }
    await _loadSnapshot();
    _queueInitialDesktopComposerFocus();
  }

  Future<void> _loadNodeInfo() async {
    if (_loadingNodeInfo) return;
    final requestId = ++_nodeInfoRequestId;
    setState(() {
      _loadingNodeInfo = true;
    });

    try {
      final node = await widget.api.fetchNode(widget.host);
      if (!mounted || requestId != _nodeInfoRequestId) {
        return;
      }
      setState(() {
        _nodeInfo = node;
        _loadingNodeInfo = false;
        _coerceDraftsForProviderCapabilities();
      });
      _closeUnsupportedInspectorSurface();
      _loadProviderBackedSessionData(forceSkills: true);
    } catch (_) {
      if (!mounted || requestId != _nodeInfoRequestId) {
        return;
      }
      setState(() {
        _loadingNodeInfo = false;
      });
      // Older or temporarily failing hosts should keep the previous Codex-first
      // behavior instead of disabling affordances because /api/node failed.
      _loadProviderBackedSessionData(forceSkills: true);
    }
  }

  void _loadProviderBackedSessionData({bool forceSkills = false}) {
    if (_supportsSkillInput) {
      unawaited(_loadSkills(forceReload: forceSkills));
    }
    if (_supportsGitStatus) {
      unawaited(_loadGitStatus(silent: true));
    }
  }

  void _coerceDraftsForProviderCapabilities() {
    if (!_supportsImageInput) {
      _draftAttachments = const <_ComposerImageAttachment>[];
    }
    if (!_supportsSkillInput) {
      _draftSkillMentions = const <_ComposerSkillMention>[];
      _activeSkillQuery = null;
      _skills = const <SkillSummary>[];
      _skillsError = null;
      _loadingSkills = false;
      _skillsRequestId++;
    }
    if (!_supportsGitStatus) {
      _gitStatus = null;
      _gitStatusError = null;
      _gitStatusLoading = false;
      _gitStatusRequestId++;
    }
  }

  void _closeUnsupportedInspectorSurface() {
    final controller = _inspectorController;
    final current = controller?.current;
    if (controller == null ||
        current == null ||
        current.ownerKey != _inspectorOwnerKey()) {
      return;
    }
    final unsupportedResources =
        current.kind == InspectorSurfaceKind.resources &&
        !_supportsSessionResources;
    final unsupportedFiles =
        current.kind == InspectorSurfaceKind.fileBrowser &&
        !_supportsFilesystem;
    final unsupportedTerminal =
        current.kind == InspectorSurfaceKind.terminal && !_supportsTerminal;
    final unsupportedPorts =
        current.kind == InspectorSurfaceKind.ports && !_supportsConnections;
    if (unsupportedResources ||
        unsupportedFiles ||
        unsupportedTerminal ||
        unsupportedPorts) {
      controller.closeForOwner(current.ownerKey);
    }
  }

  void _applyInitialComposerSeed() {
    final seed = widget.initialComposerSeed;
    if (seed == null) {
      return;
    }
    _applyComposerSeed(seed);
  }

  void _applyComposerSeed(SessionComposerSeed seed) {
    final draftAttachments = <_ComposerImageAttachment>[];
    final draftSkillMentions = <_ComposerSkillMention>[];
    final draftFileMentions = <_ComposerFileMention>[];
    var attachmentIndex = 0;
    for (final item in seed.inputItems) {
      switch (item.type) {
        case 'image':
          final dataUrl = item.url?.trim();
          if (dataUrl == null ||
              dataUrl.isEmpty ||
              !_isInlineImageDataUrl(dataUrl)) {
            continue;
          }
          final bytes = _decodeInlineImageDataUrl(dataUrl);
          if (bytes == null) {
            continue;
          }
          final mimeType = _inlineImageMimeType(dataUrl) ?? 'image/png';
          draftAttachments.add(
            _ComposerImageAttachment(
              id: 'seed-image-$attachmentIndex',
              name:
                  'attachment-${attachmentIndex + 1}${_imageExtensionForMimeType(mimeType)}',
              mimeType: mimeType,
              bytes: bytes,
              dataUrl: dataUrl,
            ),
          );
          attachmentIndex += 1;
        case 'skill':
          final name = item.name?.trim() ?? '';
          final path = item.path?.trim() ?? '';
          if (name.isEmpty || path.isEmpty) {
            continue;
          }
          final skill = SkillSummary(
            name: name,
            description: '',
            path: path,
            scope: 'repo',
            enabled: true,
          );
          draftSkillMentions.add(
            _ComposerSkillMention(skill: skill, tokenText: skill.mentionToken),
          );
        case 'file':
          final path = item.path?.trim() ?? '';
          if (path.isEmpty) {
            continue;
          }
          final file = FsSearchResult(
            path: path,
            name: path.split('/').last,
            isDirectory: item.isDirectory == true,
            score: 0,
          );
          draftFileMentions.add(
            _ComposerFileMention(file: file, tokenText: _fileMentionToken(file)),
          );
        default:
          continue;
      }
    }

    _draftAttachments = draftAttachments;
    _draftSkillMentions = draftSkillMentions
        .where((item) => seed.text.contains(item.tokenText))
        .toList(growable: false);
    _draftFileMentions = draftFileMentions
        .where((item) => seed.text.contains(item.tokenText))
        .toList(growable: false);
    _composerController.value = TextEditingValue(
      text: seed.text,
      selection: TextSelection.collapsed(offset: seed.text.length),
      composing: TextRange.empty,
    );
    _restoreComposerFocusOnResume = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) {
        return;
      }
      _composerFocusNode.requestFocus();
      _scrollToBottomFast(force: true);
    });
  }

  void _markCurrentSessionSeen() {
    if (_keepSessionUnread) {
      return;
    }
    final session = _session ?? widget.session;
    _readStore.markSeen(widget.host, session.id, session.updatedAt);
  }

  void _scheduleMarkCurrentSessionSeen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) {
        return;
      }
      _markCurrentSessionSeen();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = InspectorScope.maybeOf(context);
    if (!identical(controller, _inspectorController)) {
      _inspectorController?.removeListener(_onInspectorChanged);
      _inspectorController = controller;
      _inspectorController?.addListener(_onInspectorChanged);
    }
    if (!_inspectorRestoreAttempted && controller != null) {
      _inspectorRestoreAttempted = true;
      unawaited(_restoreInspectorSurface());
    }
  }

  Future<void> _restoreInspectorSurface() async {
    final controller = _inspectorController;
    if (controller == null) return;
    // Pane 3 only materializes on wide shells; skip restoration on phones
    // so we don't surprise users with an unexpected sheet-equivalent on
    // resize-back to a small window.
    final width = MediaQuery.of(context).size.width;
    if (width < 900) return;
    final ownerKey = _inspectorOwnerKey();
    final kind = await InspectorPersistence.load(ownerKey);
    if (!mounted || _disposed) return;
    final cur = controller.current;
    // If a previous session's surface is still mounted in the pane, close
    // it now that our owner is active — otherwise we'd be inspecting the
    // wrong session.
    void closeOrphan() {
      final lingering = controller.current;
      if (lingering != null && lingering.ownerKey != ownerKey) {
        controller.closeForOwner(lingering.ownerKey);
      }
    }

    if (kind == null) {
      closeOrphan();
      // No saved surface — open the hub so pane 3 is immediately useful
      // rather than blank. The hub itself is never persisted, so next open
      // will again check for a real saved surface first.
      _openDefaultInspectorHub(controller, ownerKey);
      return;
    }
    // If something else has already opened a surface for this owner
    // (e.g. the shell's debug shortcut) don't stomp it.
    if (cur != null && cur.ownerKey == ownerKey) return;
    switch (kind) {
      case InspectorSurfaceKind.search:
        controller.show(
          buildInspectorSearchSurface(
            ownerKey: ownerKey,
            controller: _searchController,
            focusNode: _searchFocusNode,
            recordsBuilder: _buildSearchRecords,
            refresh: _timelineRevision,
          ),
        );
        break;
      case InspectorSurfaceKind.resources:
        if (!_supportsSessionResources) return;
        controller.show(
          buildInspectorResourcesSurface(
            ownerKey: ownerKey,
            host: widget.host,
            session: _session ?? widget.session,
            api: widget.api,
            onOpenFile: _openWorkspaceFile,
          ),
        );
        break;
      case InspectorSurfaceKind.fileBrowser:
        if (!_supportsFilesystem) return;
        final session = _session ?? widget.session;
        controller.show(
          buildInspectorWorkspaceBrowserSurface(
            ownerKey: ownerKey,
            host: widget.host,
            api: widget.api,
            root: session.cwd,
            agentProvider: session.provider,
            sessionId: session.id,
          ),
        );
        break;
      case InspectorSurfaceKind.pinned:
        controller.show(
          buildInspectorPinnedSurface(
            ownerKey: ownerKey,
            pinsBuilder: _currentPins,
            onOpen: _showPinnedMessage,
            onUnpin: _unpinMessage,
            refresh: _pinsStore,
          ),
        );
        break;
      case InspectorSurfaceKind.terminal:
        if (!_supportsTerminal) return;
        controller.show(
          buildInspectorTerminalSurface(
            ownerKey: ownerKey,
            host: widget.host,
            api: widget.api,
            session: _session ?? widget.session,
          ),
        );
        break;
      case InspectorSurfaceKind.ports:
        if (!_supportsConnections) return;
        controller.show(
          buildInspectorPortsSurface(
            ownerKey: ownerKey,
            host: widget.host,
            api: widget.api,
            session: _session ?? widget.session,
            supportsBrowserPreview: _supportsBrowserPreview,
            supportsPortForwarding: _supportsPortForwarding,
            onBrowserPreviewOpened: (preview) {
              unawaited(_showDockedBrowserPreview(preview: preview));
            },
          ),
        );
        break;
      case InspectorSurfaceKind.browserPreview:
      case InspectorSurfaceKind.debug:
      case InspectorSurfaceKind.gitDetails:
      case InspectorSurfaceKind.sessionDetails:
        // Not persisted / not owned by the session screen yet.
        break;
      case InspectorSurfaceKind.sessionHub:
        // Hub is the default; treat a persisted hub as if nothing was saved.
        closeOrphan();
        _openDefaultInspectorHub(controller, ownerKey);
        break;
    }
  }

  /// Opens the inspector hub for this session.
  ///
  /// Each callback handles its own capability check and shows a snackbar when
  /// the tool is not available on the current host, so the hub doesn't need
  /// to know about capability flags at construction time.
  void _openDefaultInspectorHub(
    InspectorController controller,
    String ownerKey,
  ) {
    final session = _session ?? widget.session;
    controller.show(
      buildInspectorSessionHubSurface(
        ownerKey: ownerKey,
        onOpenSearch: _toggleSearchPanel,
        onOpenPinned: _openPinnedPanel,
        onOpenFiles: () {
          if (!_supportsFilesystem) {
            showAppSnackBar(
              context,
              'File browser not available on this host.',
            );
            return;
          }
          _browseWorkspacePath(session.cwd);
        },
        onOpenTerminal: () {
          if (!_supportsTerminal) {
            showAppSnackBar(context, 'Terminal not available on this host.');
            return;
          }
          unawaited(_openTerminal());
        },
        onOpenPorts: () {
          if (!_supportsConnections) {
            showAppSnackBar(
              context,
              'Browser previews are not available on this host.',
            );
            return;
          }
          unawaited(_openConnections());
        },
        onOpenResources: _openResourcesPanel,
      ),
    );
  }

  void _onInspectorChanged() {
    if (!mounted || _disposed) return;
    final controller = _inspectorController;
    if (controller == null) return;
    final ownerKey = _inspectorOwnerKey();
    final cur = controller.current;
    if (cur != null && cur.ownerKey == ownerKey) {
      _inspectorSawOurSurface = true;
      _lastInspectorSurfaceKind = cur.kind;
      // Don't persist the hub — it's the default, not a deliberate user
      // choice. A real surface opened next will replace it in persistence.
      if (cur.kind != InspectorSurfaceKind.sessionHub) {
        unawaited(InspectorPersistence.save(ownerKey, cur.kind));
      }
      return;
    }
    // cur is null or belongs to a different owner. We only persist "closed"
    // when the user actively dismissed OUR surface — a shell-driven
    // closeForOwner (session switch) leaves the saved state alone so we
    // can restore it next time the session becomes active again.
    if (cur == null &&
        _inspectorSawOurSurface &&
        controller.lastCloseWasUserInitiated) {
      final lastKind = _lastInspectorSurfaceKind;
      unawaited(InspectorPersistence.save(ownerKey, null));
      if (lastKind != null &&
          lastKind != InspectorSurfaceKind.sessionHub &&
          MediaQuery.of(context).size.width >= 900) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _disposed) return;
          final nextController = _inspectorController;
          if (nextController == null || nextController.current != null) return;
          _openDefaultInspectorHub(nextController, ownerKey);
        });
      }
    }
    _inspectorSawOurSurface = false;
    if (cur == null) {
      _lastInspectorSurfaceKind = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WindowScreenAwakeCoordinator.instance.clearSource(_screenAwakeSourceKey);
    _inspectorController?.removeListener(_onInspectorChanged);
    _inspectorController = null;
    // Stamp the most recent session state as seen before we unmount so
    // anything that streamed in during the last turn counts as read on
    // the way out.
    _markCurrentSessionSeen();
    _persistCurrentSessionLog();
    unawaited(_readStore.flush());
    WidgetsBinding.instance.removeObserver(this);
    HostReconnectScheduler.instance.unregisterSlot(
      widget.host.id,
      _reconnectSlotId,
    );
    _sessionCachePersistTimer?.cancel();
    _pendingSendRetryTimer?.cancel();
    _composerController.removeListener(_handleComposerChanged);
    _composerFocusNode.removeListener(_handleComposerFocusChanged);
    _searchController.removeListener(_handleSearchChanged);
    _pinsStore.removeListener(_handlePinsChanged);
    _sendOutbox.removeListener(_handleSendOutboxChanged);
    _composerController.dispose();
    _searchController.dispose();
    _composerFocusNode.dispose();
    _searchFocusNode.dispose();
    _scrollController.removeListener(_onTranscriptScroll);
    _scrollController.dispose();
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _liveFlushTimer?.cancel();
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _liveAssistantNotifier.dispose();
    _thinkingNotifier.dispose();
    _showJumpToLatest.dispose();
    _timelineRevision.dispose();
    super.dispose();
  }

  void _handlePinsChanged() {
    if (!mounted || _disposed) return;
    setState(() {});
  }

  void _handleSendOutboxChanged() {
    if (!mounted || _disposed) return;
    unawaited(_loadPendingSends());
  }

  void _handleSearchChanged() {
    final query = _searchController.text;
    if (query == _searchQuery) return;
    setState(() => _searchQuery = query);
  }

  void _openSearchPanel() {
    final width = MediaQuery.of(context).size.width;
    final scope = InspectorScope.maybeOf(context);
    if (width >= 900 && scope != null) {
      scope.toggle(
        buildInspectorSearchSurface(
          ownerKey: _inspectorOwnerKey(),
          controller: _searchController,
          focusNode: _searchFocusNode,
          recordsBuilder: _buildSearchRecords,
          refresh: _timelineRevision,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _disposed) return;
        if (_isSearchInspectorOpen(scope)) {
          _searchFocusNode.requestFocus();
        }
      });
      return;
    }
    final records = _buildSearchRecords();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
        return MeshBottomSheetScaffold(
          icon: Icons.search_rounded,
          title: 'Search this session',
          description:
              'Look through messages, activities, and tool results without leaving the session.',
          maxWidth: 760,
          maxHeightFactor: 0.88,
          padding: EdgeInsets.fromLTRB(14, 10, 14, 14 + bottomInset),
          child: SearchPanel(
            controller: _searchController,
            focusNode: _searchFocusNode,
            records: records,
            onClose: () => Navigator.of(sheetContext).maybePop(),
            showDragHandle: false,
            showCloseButton: false,
          ),
        );
      },
    );
  }

  String _inspectorOwnerKey() {
    final s = _session ?? widget.session;
    return '${widget.host.id}|${s.id}';
  }

  bool _isSearchInspectorOpen(InspectorController scope) {
    final cur = scope.current;
    return cur != null &&
        cur.kind == InspectorSurfaceKind.search &&
        cur.ownerKey == _inspectorOwnerKey();
  }

  bool _isPinnedInspectorOpen(InspectorController? scope) {
    if (scope == null) return false;
    final cur = scope.current;
    return cur != null &&
        cur.kind == InspectorSurfaceKind.pinned &&
        cur.ownerKey == _inspectorOwnerKey();
  }

  bool _isResourcesInspectorOpen(InspectorController? scope) {
    if (scope == null) return false;
    final cur = scope.current;
    return cur != null &&
        cur.kind == InspectorSurfaceKind.resources &&
        cur.ownerKey == _inspectorOwnerKey();
  }

  bool _isTerminalInspectorOpen(InspectorController? scope) {
    if (scope == null) return false;
    final cur = scope.current;
    return cur != null &&
        cur.kind == InspectorSurfaceKind.terminal &&
        cur.ownerKey == _inspectorOwnerKey();
  }

  bool _isPortsInspectorOpen(InspectorController? scope) {
    if (scope == null) return false;
    final cur = scope.current;
    return cur != null &&
        cur.kind == InspectorSurfaceKind.ports &&
        cur.ownerKey == _inspectorOwnerKey();
  }

  List<PinnedSessionMessage> _currentPins() {
    return _pinsStore.pinsFor(widget.host, (_session ?? widget.session).id);
  }

  void _openPinnedPanel() {
    final width = MediaQuery.of(context).size.width;
    final scope = InspectorScope.maybeOf(context);
    if (width >= 900 && scope != null) {
      scope.toggle(
        buildInspectorPinnedSurface(
          ownerKey: _inspectorOwnerKey(),
          pinsBuilder: _currentPins,
          onOpen: _showPinnedMessage,
          onUnpin: _unpinMessage,
          refresh: _pinsStore,
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _PinnedListSheet(
        pinsBuilder: _currentPins,
        refresh: _pinsStore,
        onOpen: (pin) {
          Navigator.of(sheetContext).maybePop();
          _showPinnedMessage(pin);
        },
        onUnpin: _unpinMessage,
      ),
    );
  }

  void _openResourcesPanel() {
    if (!_supportsSessionResources) {
      showAppSnackBar(context, 'This session does not have a resources view.');
      return;
    }
    final width = MediaQuery.of(context).size.width;
    final scope = InspectorScope.maybeOf(context);
    final session = _session ?? widget.session;
    if (width >= 900 && scope != null) {
      scope.toggle(
        buildInspectorResourcesSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          session: session,
          api: widget.api,
          onOpenFile: _openWorkspaceFile,
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => MeshBottomSheetScaffold(
        icon: Icons.perm_media_rounded,
        title: 'Session resources',
        description:
            'Review files, images, and links saved from this session in one place.',
        maxWidth: 900,
        maxHeightFactor: 0.84,
        child: SessionResourcesPanel(
          host: widget.host,
          session: session,
          api: widget.api,
          showDragHandle: false,
          onClose: () => Navigator.of(sheetContext).maybePop(),
          onOpenFile: (path) {
            Navigator.of(sheetContext).maybePop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _disposed) return;
              _openWorkspaceFile(path);
            });
          },
        ),
      ),
    );
  }

  void _toggleSearchPanel() {
    _openSearchPanel();
  }

  void _onTranscriptScroll() {
    if (!_scrollController.hasClients) return;
    // Reverse ListView: offset > 0 means the user has scrolled up away
    // from the newest message.
    final shouldShow = _scrollController.offset > 240;
    if (shouldShow != _showJumpToLatest.value) {
      _showJumpToLatest.value = shouldShow;
    }
  }

  Future<void> _loadSkills({bool forceReload = false}) async {
    if (!_supportsSkillInput) {
      if (mounted) {
        setState(() {
          _skills = const <SkillSummary>[];
          _skillsError = null;
          _loadingSkills = false;
        });
      } else {
        _skills = const <SkillSummary>[];
        _skillsError = null;
        _loadingSkills = false;
      }
      return;
    }
    final requestId = ++_skillsRequestId;
    if (mounted) {
      setState(() {
        _loadingSkills = true;
        _skillsError = null;
      });
    } else {
      _loadingSkills = true;
      _skillsError = null;
    }

    try {
      final catalog = await widget.api.fetchSkills(
        widget.host,
        cwd: (_session ?? widget.session).cwd,
        forceReload: forceReload,
        agentProvider: (_session ?? widget.session).provider,
      );
      if (!mounted || requestId != _skillsRequestId) {
        return;
      }
      setState(() {
        _skills = catalog.skills;
        _skillsError = catalog.errors.isEmpty
            ? null
            : catalog.errors.map((item) => item.message).join('\n');
        _loadingSkills = false;
      });
    } catch (error) {
      if (!mounted || requestId != _skillsRequestId) {
        return;
      }
      setState(() {
        _loadingSkills = false;
        _skillsError = friendlyError(error);
      });
    }
  }

  Future<void> _loadFileSuggestions() async {
    final activeQuery = _activeFileQuery?.query.trim() ?? '';
    if (activeQuery.isEmpty) {
      _fileSearchRequestId += 1;
      if (mounted) {
        setState(() {
          _fileSuggestions = const <FsSearchResult>[];
          _loadingFileSearch = false;
          _fileSearchError = null;
        });
      } else {
        _fileSuggestions = const <FsSearchResult>[];
        _loadingFileSearch = false;
        _fileSearchError = null;
      }
      return;
    }

    final requestId = ++_fileSearchRequestId;
    if (mounted) {
      setState(() {
        _loadingFileSearch = true;
        _fileSearchError = null;
      });
    } else {
      _loadingFileSearch = true;
      _fileSearchError = null;
    }

    try {
      final results = await widget.api.searchFiles(
        widget.host,
        query: activeQuery,
        sessionId: widget.session.id,
      );
      if (!mounted || requestId != _fileSearchRequestId) {
        return;
      }
      setState(() {
        _fileSuggestions = results;
        _loadingFileSearch = false;
      });
    } catch (error) {
      if (!mounted || requestId != _fileSearchRequestId) {
        return;
      }
      setState(() {
        _loadingFileSearch = false;
        _fileSearchError = friendlyError(error);
      });
    }
  }

  Future<void> _loadGitStatus({bool silent = false}) async {
    if (!_supportsGitStatus) {
      if (mounted) {
        setState(() {
          _gitStatus = null;
          _gitStatusLoading = false;
          _gitStatusError = null;
        });
      } else {
        _gitStatus = null;
        _gitStatusLoading = false;
        _gitStatusError = null;
      }
      return;
    }
    final requestId = ++_gitStatusRequestId;
    if (!silent && mounted) {
      setState(() {
        _gitStatusLoading = true;
        _gitStatusError = null;
      });
    }

    try {
      final status = await widget.api.fetchGitStatus(
        widget.host,
        widget.session.id,
      );
      if (!mounted || requestId != _gitStatusRequestId) {
        return;
      }
      setState(() {
        _gitStatus = status;
        _gitStatusLoading = false;
        _gitStatusError = status.error;
      });
    } catch (error) {
      if (!mounted || requestId != _gitStatusRequestId) {
        return;
      }
      setState(() {
        _gitStatusLoading = false;
        _gitStatusError = friendlyError(error);
      });
    }
  }

  void _handleComposerChanged() {
    final nextSkillQuery = _supportsSkillInput
        ? _extractActiveSkillQuery(_composerController.value)
        : null;
    final nextDraftSkillMentions = _supportsSkillInput
        ? _draftSkillMentions
              .where(
                (item) => _composerController.text.contains(item.tokenText),
              )
              .toList(growable: false)
        : const <_ComposerSkillMention>[];
    final skillQueryChanged =
        nextSkillQuery?.start != _activeSkillQuery?.start ||
        nextSkillQuery?.end != _activeSkillQuery?.end ||
        nextSkillQuery?.query != _activeSkillQuery?.query;
    final skillMentionsChanged = !listEquals(
      nextDraftSkillMentions,
      _draftSkillMentions,
    );
    if (skillQueryChanged || skillMentionsChanged) {
      if (!mounted) {
        _activeSkillQuery = nextSkillQuery;
        _draftSkillMentions = nextDraftSkillMentions;
      } else {
        setState(() {
          _activeSkillQuery = nextSkillQuery;
          _draftSkillMentions = nextDraftSkillMentions;
        });
      }
    }
    if (nextSkillQuery != null && _skills.isEmpty && !_loadingSkills) {
      unawaited(_loadSkills());
    }

    final nextFileQuery = _supportsFileMentions
        ? _extractActiveFileQuery(_composerController.value)
        : null;
    final nextDraftFileMentions = _supportsFileMentions
        ? _draftFileMentions
              .where(
                (item) => _composerController.text.contains(item.tokenText),
              )
              .toList(growable: false)
        : const <_ComposerFileMention>[];
    final fileQueryChanged =
        nextFileQuery?.start != _activeFileQuery?.start ||
        nextFileQuery?.end != _activeFileQuery?.end ||
        nextFileQuery?.query != _activeFileQuery?.query;
    final fileQueryTextChanged =
        nextFileQuery?.query.trim() != _activeFileQuery?.query.trim();
    final fileMentionsChanged = !listEquals(
      nextDraftFileMentions,
      _draftFileMentions,
    );
    if (fileQueryChanged || fileMentionsChanged) {
      if (!mounted) {
        _activeFileQuery = nextFileQuery;
        _draftFileMentions = nextDraftFileMentions;
        if (nextFileQuery == null || nextFileQuery.query.trim().isEmpty) {
          _fileSearchRequestId += 1;
          _fileSuggestions = const <FsSearchResult>[];
          _loadingFileSearch = false;
          _fileSearchError = null;
        } else if (fileQueryTextChanged) {
          _fileSuggestions = const <FsSearchResult>[];
          _fileSearchError = null;
        }
      } else {
        setState(() {
          _activeFileQuery = nextFileQuery;
          _draftFileMentions = nextDraftFileMentions;
          if (nextFileQuery == null || nextFileQuery.query.trim().isEmpty) {
            _fileSearchRequestId += 1;
            _fileSuggestions = const <FsSearchResult>[];
            _loadingFileSearch = false;
            _fileSearchError = null;
          } else if (fileQueryTextChanged) {
            _fileSuggestions = const <FsSearchResult>[];
            _fileSearchError = null;
          }
        });
      }
    }
    if (nextFileQuery != null &&
        nextFileQuery.query.trim().isNotEmpty &&
        (fileQueryTextChanged || !_loadingFileSearch)) {
      unawaited(_loadFileSuggestions());
    }
  }

  /// Tracks composer focus changes → drives the animated pill border.
  void _handleComposerFocusChanged() {
    final focused = _composerFocusNode.hasFocus;
    if (!focused) {
      _lastComposerBlurAt = DateTime.now();
    }
    if (focused != _composerFocused) {
      setState(() => _composerFocused = focused);
    }
  }

  /// Inserts a `$` skill-trigger character at the current cursor and focuses
  /// the composer.  Called by the mobile + button → context sheet.
  void _addSkillTriggerToComposer() {
    final text = _composerController.text;
    final sel = _composerController.selection;
    final offset = sel.isValid ? sel.end : text.length;
    final needsSpace = offset > 0 && text[offset - 1] != ' ';
    final insert = needsSpace ? r' $' : r'$';
    final newText = text.substring(0, offset) + insert + text.substring(offset);
    _composerController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset + insert.length),
    );
    _composerFocusNode.requestFocus();
  }

  /// Inserts a `@` file-trigger character at the current cursor and focuses
  /// the composer.  Called by the mobile + button → context sheet.
  void _addFileTriggerToComposer() {
    final text = _composerController.text;
    final sel = _composerController.selection;
    final offset = sel.isValid ? sel.end : text.length;
    final needsSpace = offset > 0 && text[offset - 1] != ' ';
    final insert = needsSpace ? ' @' : '@';
    final newText = text.substring(0, offset) + insert + text.substring(offset);
    _composerController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset + insert.length),
    );
    _composerFocusNode.requestFocus();
  }

  _ActiveComposerSkillQuery? _extractActiveSkillQuery(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return null;
    }

    final text = value.text;
    final cursor = math.min(math.max(selection.extentOffset, 0), text.length);
    var start = cursor;
    while (start > 0 && !_isComposerWhitespace(text.codeUnitAt(start - 1))) {
      start -= 1;
    }
    var end = cursor;
    while (end < text.length && !_isComposerWhitespace(text.codeUnitAt(end))) {
      end += 1;
    }
    if (start >= end) {
      return null;
    }

    final token = text.substring(start, end);
    if (!token.startsWith(r'$')) {
      return null;
    }

    return _ActiveComposerSkillQuery(
      start: start,
      end: end,
      query: token.substring(1),
    );
  }

  bool _isComposerWhitespace(int codeUnit) {
    switch (codeUnit) {
      case 0x09:
      case 0x0A:
      case 0x0B:
      case 0x0C:
      case 0x0D:
      case 0x20:
        return true;
      default:
        return false;
    }
  }

  _ActiveComposerFileQuery? _extractActiveFileQuery(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return null;
    }

    final text = value.text;
    final cursor = math.min(math.max(selection.extentOffset, 0), text.length);
    var start = cursor;
    while (start > 0 && !_isComposerWhitespace(text.codeUnitAt(start - 1))) {
      start -= 1;
    }
    var end = cursor;
    while (end < text.length && !_isComposerWhitespace(text.codeUnitAt(end))) {
      end += 1;
    }
    if (start >= end) {
      return null;
    }

    final token = text.substring(start, end);
    if (!token.startsWith('@')) {
      return null;
    }

    return _ActiveComposerFileQuery(
      start: start,
      end: end,
      query: token.substring(1),
    );
  }

  List<SkillSummary> get _skillSuggestions {
    if (!_supportsSkillInput) {
      return const <SkillSummary>[];
    }
    final active = _activeSkillQuery;
    if (active == null) {
      return const <SkillSummary>[];
    }

    final query = active.query.trim().toLowerCase();
    final candidates = _skills.where((item) => item.enabled).toList();
    if (candidates.isEmpty) {
      return const <SkillSummary>[];
    }

    candidates.sort((left, right) {
      final leftScore = _skillSuggestionScore(left, query);
      final rightScore = _skillSuggestionScore(right, query);
      final scoreCompare = leftScore.compareTo(rightScore);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      final scopeCompare = left.scopeRank.compareTo(right.scopeRank);
      if (scopeCompare != 0) {
        return scopeCompare;
      }
      return left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      );
    });

    return candidates
        .where((item) => _skillSuggestionScore(item, query) < 100)
        .take(80)
        .toList(growable: false);
  }

  int _skillSuggestionScore(SkillSummary skill, String query) {
    if (query.isEmpty) {
      return 0;
    }

    final displayName = skill.displayName.toLowerCase();
    final canonicalName = skill.name.toLowerCase();
    final summaryDescription = skill.summaryDescription.toLowerCase();
    if (displayName.startsWith(query)) {
      return 0;
    }
    if (canonicalName.startsWith(query)) {
      return 1;
    }
    if (matchesSearchQuery(displayName, query)) {
      return 2;
    }
    if (matchesSearchQuery(canonicalName, query)) {
      return 3;
    }
    if (matchesSearchQuery(summaryDescription, query)) {
      return 4;
    }
    return 100;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isMacDesktop) {
      switch (state) {
        case AppLifecycleState.inactive:
        case AppLifecycleState.hidden:
        case AppLifecycleState.paused:
          _restoreComposerFocusOnResume = _composerFocusNode.hasFocus;
          break;
        case AppLifecycleState.resumed:
          final shouldRestoreFocus = _restoreComposerFocusOnResume;
          _restoreComposerFocusOnResume = false;
          if (shouldRestoreFocus) {
            _queueComposerFocusRestore(onlyIfSafe: true);
          }
          break;
        case AppLifecycleState.detached:
          _restoreComposerFocusOnResume = false;
          break;
      }
    }
    if (state == AppLifecycleState.resumed && mounted && !_disposed) {
      // OS can pause or silently kill the socket while backgrounded; the
      // normal onDone / onError path often doesn't fire until a write
      // actually fails. Force a reconnect + re-sync on resume so the user
      // sees fresh state immediately — prefer the cheap events delta over
      // a full snapshot whenever we have a known lastSeq.
      unawaited(_resyncAfterResume());
      _connectLive();
      _schedulePendingSendRetry();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _markTranscriptPossiblyStale();
    }
  }

  bool get _isMacDesktop =>
      widget.desktopMode && defaultTargetPlatform == TargetPlatform.macOS;

  void _queueInitialDesktopComposerFocus() {
    if (_initialDesktopComposerFocusQueued ||
        !widget.desktopMode ||
        widget.initialComposerSeed != null) {
      return;
    }
    _initialDesktopComposerFocusQueued = true;
    _queueComposerFocusRestore(onlyIfSafe: true);
  }

  bool _shouldRestoreComposerFocusAfterDesktopOverlay() {
    if (!widget.desktopMode) {
      return false;
    }
    if (_composerFocusNode.hasFocus) {
      return true;
    }
    final blurAt = _lastComposerBlurAt;
    return blurAt != null &&
        DateTime.now().difference(blurAt) < const Duration(milliseconds: 800);
  }

  void _restoreComposerFocusAfterDesktopOverlay(bool shouldRestore) {
    if (!shouldRestore || !mounted || _disposed) {
      return;
    }
    _queueComposerFocusRestore(onlyIfSafe: true);
  }

  Future<T?> _showDesktopOverlayWithComposerFocusRestore<T>(
    Future<T?> Function() showOverlay,
  ) async {
    final shouldRestore = _shouldRestoreComposerFocusAfterDesktopOverlay();
    try {
      return await showOverlay();
    } finally {
      _restoreComposerFocusAfterDesktopOverlay(shouldRestore);
    }
  }

  bool _canAutoFocusComposer({bool allowOtherInputs = false}) {
    if (!widget.desktopMode || _pendingAction != null) {
      return false;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      return false;
    }
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null || primaryFocus == _composerFocusNode) {
      return true;
    }
    if (!allowOtherInputs && primaryFocus == _searchFocusNode) {
      return false;
    }
    final focusContext = primaryFocus.context;
    if (focusContext == null) {
      return true;
    }
    if (!allowOtherInputs &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() !=
                null)) {
      return false;
    }
    return true;
  }

  void _queueComposerFocusRestore({
    bool onlyIfSafe = false,
    bool allowOtherInputs = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 140), () {
        if (!mounted || _disposed) {
          return;
        }
        if (onlyIfSafe &&
            !_canAutoFocusComposer(allowOtherInputs: allowOtherInputs)) {
          return;
        }
        _composerFocusNode.requestFocus();
      });
    });
  }

  void _focusComposerFromShortcut() {
    _queueComposerFocusRestore(onlyIfSafe: true, allowOtherInputs: true);
  }

  void _reloadSnapshot() {
    unawaited(_loadSnapshot(scrollToBottom: false));
  }

  Future<void> _restartProvider() async {
    if (!_supportsProviderRestart) return;
    final providerKind = widget.session.provider;
    if (providerKind == null || providerKind.isEmpty) return;
    try {
      await widget.api.restartProvider(widget.host, providerKind);
      if (!mounted) return;
      showAppSnackBar(context, 'Provider restarting…');
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      _reloadSnapshot();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, 'Restart failed: ${friendlyError(error)}');
    }
  }

  void _retryFreshnessSync() {
    setState(() {
      _showingPossiblyStaleSnapshot = true;
      _resumeSyncing = true;
      _resumeSyncFailed = false;
    });
    unawaited(
      _loadSnapshot(
        messageLimit: _messageLimit,
        activityLimit: _activityLimit,
        scrollToBottom: false,
      ),
    );
  }

  void _markTranscriptPossiblyStale() {
    if (!mounted ||
        _disposed ||
        _messages.isEmpty ||
        _showingCachedSnapshot ||
        _showingPossiblyStaleSnapshot) {
      return;
    }
    setState(() {
      _showingPossiblyStaleSnapshot = true;
      _resumeSyncing = false;
      _resumeSyncFailed = false;
    });
  }

  Future<void> _resyncAfterResume() async {
    if (!mounted || _disposed) {
      return;
    }
    final needsSnapshotVerification =
        _showingCachedSnapshot ||
        _showingPossiblyStaleSnapshot ||
        _messages.isNotEmpty;
    if (_messages.isNotEmpty && !_showingCachedSnapshot) {
      setState(() {
        _showingPossiblyStaleSnapshot = true;
        _resumeSyncing = true;
        _resumeSyncFailed = false;
      });
    }
    await _refreshCachedSessionStatus();
    if (!mounted || _disposed) {
      return;
    }
    final applied = await _resyncDelta(
      markTranscriptFresh: !needsSnapshotVerification,
    );
    if (!mounted || _disposed) {
      return;
    }
    if (applied && !needsSnapshotVerification) {
      setState(() {
        _showingPossiblyStaleSnapshot = false;
        _resumeSyncing = false;
        _resumeSyncFailed = false;
      });
      return;
    }
    await _loadSnapshot(
      messageLimit: _messageLimit,
      activityLimit: _activityLimit,
      scrollToBottom: false,
    );
  }

  Future<void> _loadSnapshot({
    int? messageLimit,
    int? activityLimit,
    bool scrollToBottom = true,
  }) async {
    final resolvedMessageLimit = messageLimit ?? _messageLimit;
    final resolvedActivityLimit = activityLimit ?? _activityLimit;
    final requestId = ++_snapshotRequestId;
    _snapshotInFlightRequestId = requestId;
    if (_showingCachedSnapshot && mounted) {
      setState(() => _snapshotRefreshing = true);
    }
    try {
      final log = await widget.api.fetchLog(
        widget.host,
        widget.session.id,
        messageLimit: resolvedMessageLimit,
        activityLimit: resolvedActivityLimit,
      );
      if (!mounted || requestId != _snapshotRequestId) {
        return;
      }
      final pendingAction = log.pendingAction;
      final livePersisted = _hasPersistedLiveAssistant(log.messages);
      // Capture any live events delivered while the snapshot was in flight —
      // we'll replay them after the snapshot setState so they aren't clobbered.
      final bufferedEvents = List<LiveEvent>.from(_pendingLiveEvents);
      _pendingLiveEvents.clear();
      final snapshotActivities = _mergeIncomingActivities(
        _activities,
        log.activities,
        mode: _ActivityMergeMode.snapshot,
      );
      setState(() {
        _session = log.session;
        _messages = log.messages;
        _optimisticMessages = _reconcileOptimisticMessages(log.messages);
        _activities = snapshotActivities;
        _history = log.history;
        _messageLimit = resolvedMessageLimit;
        _activityLimit = resolvedActivityLimit;
        _historyBannerDismissed = false;
        _showingCachedSnapshot = false;
        _snapshotRefreshing = false;
        _showingPossiblyStaleSnapshot = false;
        _resumeSyncing = false;
        _resumeSyncFailed = false;
        // Snapshot responses are authoritative for pending actions. If a live
        // action_opened lands during this fetch, it is buffered and replayed
        // after this state update.
        _pendingAction = pendingAction;
        _running = log.session.isActive;
        _loading = false;
        if (!_running || livePersisted) {
          _clearLiveAssistantMessage();
        }
        _awaitingAssistantReply =
            log.session.isActive &&
            _liveAssistantText.isEmpty &&
            _pendingAction == null;
        final restoredPlanSeq = _restoreLatestPlanUpdate(
          log.latestPlanUpdate,
          fallbackCreatedAt: log.session.updatedAt,
        );
        // Seed lastSeq from the snapshot so subsequent resyncs can use the
        // cheap delta endpoint instead of re-downloading everything.
        var highestSeq = _lastEventSeq ?? 0;
        for (final m in log.messages) {
          if (m.seq > highestSeq) highestSeq = m.seq;
        }
        for (final a in snapshotActivities) {
          if (a.seq > highestSeq) highestSeq = a.seq;
        }
        if (restoredPlanSeq != null && restoredPlanSeq > highestSeq) {
          highestSeq = restoredPlanSeq;
        }
        if (highestSeq > 0) {
          _lastEventSeq = highestSeq;
        }
      });
      HostStatusStore.instance.markOnline(widget.host.id);
      unawaited(_dropResolvedPendingSends(log.messages));
      _refreshThinkingState();
      _syncSessionLiveActivity();
      _markCurrentSessionSeen();
      unawaited(_localStore.updateGhost(widget.host, log.session));
      // Replay live events that landed during the fetch so action_opened /
      // activity_updated aren't silently dropped.
      if (_snapshotInFlightRequestId == requestId) {
        _snapshotInFlightRequestId = null;
      }
      for (final event in bufferedEvents) {
        _handleEvent(event);
      }
      if (scrollToBottom) {
        await _scrollToBottom();
      }
      _persistCurrentSessionLog();
    } catch (error) {
      if (!mounted || requestId != _snapshotRequestId) {
        return;
      }
      setState(() {
        _loading = false;
        _snapshotRefreshing = false;
        if (_showingPossiblyStaleSnapshot) {
          _resumeSyncing = false;
          _resumeSyncFailed = true;
        }
      });
      HostStatusStore.instance.markOffline(
        widget.host.id,
        error: friendlyError(error),
      );
      showAppSnackBar(
        context,
        "Failed to load session: ${friendlyError(error)}",
      );
    } finally {
      if (_snapshotInFlightRequestId == requestId) {
        _snapshotInFlightRequestId = null;
      }
    }
  }

  Future<bool> _loadCachedSnapshot() async {
    try {
      final cached = await SessionLocalStore.instance.loadSessionLog(
        widget.host,
        widget.session.id,
      );
      if (!mounted || cached == null || _messages.isNotEmpty) {
        return false;
      }
      final log = cached.log;
      setState(() {
        _session = log.session;
        _messages = log.messages;
        _optimisticMessages = _reconcileOptimisticMessages(log.messages);
        _activities = _sortActivities(log.activities);
        _history = log.history;
        // Permission prompts are live state. Restoring them from disk can show
        // stale approvals after the server already resolved or forgot them.
        _pendingAction = null;
        _running = log.session.isActive;
        _loading = false;
        _showingCachedSnapshot = true;
        _showingPossiblyStaleSnapshot = false;
        _resumeSyncing = false;
        _resumeSyncFailed = false;
        _snapshotRefreshing = _snapshotInFlight;
        _awaitingAssistantReply =
            log.session.isActive &&
            _liveAssistantText.isEmpty &&
            _pendingAction == null;
        final restoredPlanSeq = _restoreLatestPlanUpdate(
          log.latestPlanUpdate,
          fallbackCreatedAt: log.session.updatedAt,
        );
        var highestSeq = _lastEventSeq ?? 0;
        for (final m in log.messages) {
          if (m.seq > highestSeq) highestSeq = m.seq;
        }
        for (final a in log.activities) {
          if (a.seq > highestSeq) highestSeq = a.seq;
        }
        if (restoredPlanSeq != null && restoredPlanSeq > highestSeq) {
          highestSeq = restoredPlanSeq;
        }
        if (highestSeq > 0) {
          _lastEventSeq = highestSeq;
        }
      });
      _refreshThinkingState();
      _markCurrentSessionSeen();
      return true;
    } catch (_) {
      // Cached transcripts are best-effort. A fresh snapshot is already queued.
      return false;
    }
  }

  void _applyFetchedSessionStatus(SessionStatus status) {
    _running = status.isRunning;
    _pendingAction = status.pendingAction;
    if (status.status == 'waiting_for_input' ||
        status.status == 'waiting_for_approval' ||
        status.status == 'errored' ||
        status.status == 'closed') {
      _latestThreadStatus = LiveEvent(
        type: 'thread_status_changed',
        sessionId: status.sessionId,
        status: status.status,
        pendingActionKind: status.pendingAction?.kind,
      );
    } else {
      _latestThreadStatus = null;
    }
    if (status.status == 'running') {
      _awaitingAssistantReply =
          _liveAssistantText.isEmpty && status.pendingAction == null;
      return;
    }
    _awaitingAssistantReply = false;
  }

  void _markTranscriptFreshAfterDelta() {
    _showingCachedSnapshot = false;
    _showingPossiblyStaleSnapshot = false;
    _resumeSyncing = false;
    _resumeSyncFailed = false;
    _snapshotRefreshing = false;
  }

  Future<void> _refreshSessionFreshness({bool scrollToBottom = true}) async {
    final needsSnapshotVerification =
        _showingCachedSnapshot || _showingPossiblyStaleSnapshot;
    await _refreshCachedSessionStatus();
    if (!mounted || _disposed) {
      return;
    }
    final applied = await _resyncDelta(
      markTranscriptFresh: !needsSnapshotVerification,
    );
    if (!mounted || _disposed || (applied && !needsSnapshotVerification)) {
      return;
    }
    await _loadSnapshot(
      messageLimit: _messageLimit,
      activityLimit: _activityLimit,
      scrollToBottom: scrollToBottom,
    );
  }

  Future<void> _refreshCachedSessionStatus() async {
    try {
      final status = await widget.api.fetchStatus(
        widget.host,
        widget.session.id,
      );
      if (!mounted || _disposed) {
        return;
      }
      setState(() {
        _applyFetchedSessionStatus(status);
        _snapshotRefreshing = _snapshotInFlight;
        _loading = false;
      });
      HostStatusStore.instance.markOnline(widget.host.id);
      _refreshThinkingState();
      _syncSessionLiveActivity();
    } catch (_) {
      // Keep the cached-transcript strip visible until the full snapshot lands.
    }
  }

  /// Cheap catchup using the events endpoint. Returns true if the delta
  /// was applied; false if we should fall back to a full snapshot.
  Future<bool> _resyncDelta({bool markTranscriptFresh = true}) async {
    final last = _lastEventSeq;
    if (last == null) return false;
    try {
      final baseUpdatedAt = _session?.updatedAt.millisecondsSinceEpoch;
      final delta = await widget.api.fetchEvents(
        widget.host,
        widget.session.id,
        since: last,
        baseUpdatedAt: baseUpdatedAt,
      );
      if (!mounted) return true;
      final latestPlanUpdate = delta.latestPlanUpdate;
      if (delta.messages.isEmpty &&
          delta.activities.isEmpty &&
          latestPlanUpdate == null &&
          delta.pendingAction == null &&
          delta.session == null) {
        if (markTranscriptFresh &&
            (_showingCachedSnapshot || _showingPossiblyStaleSnapshot)) {
          setState(_markTranscriptFreshAfterDelta);
        }
        HostStatusStore.instance.markOnline(widget.host.id);
        return true;
      }
      setState(() {
        final previousMessages = _messages;
        final previousActivities = _activities;
        var mergedMessages = _messages;
        var mergedActivities = _activities;
        var nextRunning = _running;
        if (delta.session != null) {
          _session = delta.session!;
          nextRunning = delta.session!.isActive;
        }
        if (delta.messages.isNotEmpty) {
          final byId = <String, SessionMessage>{
            for (final m in _messages) m.id: m,
          };
          for (final m in delta.messages) {
            byId[m.id] = m;
          }
          mergedMessages = byId.values.toList()
            ..sort((a, b) {
              if (a.seq != b.seq) return a.seq.compareTo(b.seq);
              return a.createdAt.compareTo(b.createdAt);
            });
        }
        if (delta.activities.isNotEmpty) {
          mergedActivities = _mergeIncomingActivities(
            _activities,
            delta.activities,
            mode: _ActivityMergeMode.incremental,
          );
        }
        _messages = mergedMessages;
        _activities = mergedActivities;
        _history = _updatedHistoryAfterDelta(
          previous: _history,
          previousMessages: previousMessages,
          mergedMessages: mergedMessages,
          previousActivities: previousActivities,
          mergedActivities: mergedActivities,
        );
        _optimisticMessages = _reconcileOptimisticMessages(mergedMessages);
        final restoredPlanSeq = _restoreLatestPlanUpdate(
          latestPlanUpdate,
          fallbackCreatedAt: delta.session?.updatedAt ?? DateTime.now(),
        );
        // The events endpoint returns the server's current pending-action
        // snapshot, so a null here means any previously shown action is gone.
        _pendingAction = delta.pendingAction;
        _running = nextRunning;
        if (!nextRunning || _hasPersistedLiveAssistant(mergedMessages)) {
          _clearLiveAssistantMessage();
        }
        _awaitingAssistantReply =
            nextRunning && _liveAssistantText.isEmpty && _pendingAction == null;
        final highestSeq = math.max(
          delta.nextSeq,
          restoredPlanSeq ?? delta.nextSeq,
        );
        if (highestSeq > (_lastEventSeq ?? 0)) {
          _lastEventSeq = highestSeq;
        }
        if (markTranscriptFresh) {
          _markTranscriptFreshAfterDelta();
        }
      });
      _refreshThinkingState();
      _syncSessionLiveActivity();
      _markCurrentSessionSeen();
      _persistCurrentSessionLog();
      HostStatusStore.instance.markOnline(widget.host.id);
      return true;
    } catch (_) {
      HostStatusStore.instance.markOffline(widget.host.id);
      return false;
    }
  }

  void _persistCurrentSessionLog() {
    _sessionCachePersistTimer?.cancel();
    _sessionCachePersistTimer = null;
    final session = _session;
    if (session == null) {
      return;
    }
    unawaited(
      SessionLocalStore.instance.saveSessionLog(
        widget.host,
        SessionLog(
          session: session,
          messages: _messages,
          activities: _activities,
          pendingAction: null,
          history: _history,
          latestPlanUpdate: _latestPlanUpdateForCache(),
        ),
      ),
    );
  }

  void _schedulePersistCurrentSessionLog() {
    _sessionCachePersistTimer?.cancel();
    _sessionCachePersistTimer = Timer(_sessionCacheWriteDebounce, () {
      _sessionCachePersistTimer = null;
      _persistCurrentSessionLog();
    });
  }

  SessionLogHistorySummary? _updatedHistoryAfterDelta({
    required SessionLogHistorySummary? previous,
    required List<SessionMessage> previousMessages,
    required List<SessionMessage> mergedMessages,
    required List<SessionActivity> previousActivities,
    required List<SessionActivity> mergedActivities,
  }) {
    if (previous == null) {
      return null;
    }
    final previousMessageIds = previousMessages.map((m) => m.id).toSet();
    final previousActivityIds = previousActivities.map((a) => a.id).toSet();
    final mergedMessageIds = mergedMessages.map((m) => m.id).toSet();
    final mergedActivityIds = mergedActivities.map((a) => a.id).toSet();
    final newMessageCount = mergedMessageIds.length - previousMessageIds.length;
    final newActivityCount =
        mergedActivityIds.length - previousActivityIds.length;
    final totalMessages = math.max(
      previous.totalMessages + (newMessageCount > 0 ? newMessageCount : 0),
      mergedMessages.length,
    );
    final totalActivities = math.max(
      previous.totalActivities + (newActivityCount > 0 ? newActivityCount : 0),
      mergedActivities.length,
    );
    return SessionLogHistorySummary(
      isTruncated:
          totalMessages > mergedMessages.length ||
          totalActivities > mergedActivities.length,
      totalMessages: totalMessages,
      returnedMessages: mergedMessages.length,
      totalActivities: totalActivities,
      returnedActivities: mergedActivities.length,
    );
  }

  Future<void> _loadOlderTranscript() async {
    final history = _history;
    if (_loadingOlderHistory || history == null || !history.isTruncated) {
      return;
    }
    final nextMessageLimit = _nextHistoryLimit(
      current: _messageLimit,
      pageSize: _messagePageSize,
      total: history.totalMessages,
    );
    final nextActivityLimit = _nextHistoryLimit(
      current: _activityLimit,
      pageSize: _activityPageSize,
      total: history.totalActivities,
    );
    if (nextMessageLimit == _messageLimit &&
        nextActivityLimit == _activityLimit) {
      return;
    }

    setState(() => _loadingOlderHistory = true);
    try {
      await _loadSnapshot(
        messageLimit: nextMessageLimit,
        activityLimit: nextActivityLimit,
        scrollToBottom: false,
      );
    } finally {
      if (mounted) {
        setState(() => _loadingOlderHistory = false);
      }
    }
  }

  int _nextHistoryLimit({
    required int current,
    required int pageSize,
    required int total,
  }) {
    if (total <= current) {
      return current;
    }
    final expanded = current + pageSize;
    return expanded > total ? total : expanded;
  }

  void _connectLive() {
    if (_disposed || !widget.host.enabled) return;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _subscription = null;
    _channel = null;
    try {
      final channel = widget.api.openLive(widget.host, widget.session.id);
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleRawEvent,
        onError: (_) => _scheduleReconnect(),
        onDone: () {
          if (!_disposed) _scheduleReconnect();
        },
        cancelOnError: false,
      );
      // Successful connect — reset the backoff counter. If the stream dies
      // immediately onDone will re-arm it.
      HostReconnectScheduler.instance.markConnected(
        widget.host.id,
        _reconnectSlotId,
      );
    } catch (_) {
      _channel = null;
      if (!widget.host.enabled) return;
      _scheduleReconnect();
    }
  }

  void _handleRawEvent(dynamic raw) {
    LiveEvent? event;
    try {
      final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
      event = LiveEvent.fromJson(decoded);
    } catch (_) {
      // Swallow malformed frames — don't tear down the stream for a single
      // bad line. Transport-level errors land in onError / onDone instead.
      return;
    }
    HostStatusStore.instance.markEvent(widget.host.id);
    _handleEvent(event);
  }

  void _scheduleReconnect() {
    if (_disposed || !mounted || !widget.host.enabled) return;
    final channel = _channel;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _subscription = null;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close());
    }
    HostReconnectScheduler.instance.markDisconnected(
      widget.host.id,
      _reconnectSlotId,
    );
  }

  void _handleEvent(LiveEvent event) {
    if (!mounted || event.sessionId != widget.session.id) {
      return;
    }

    // If a snapshot is in flight, queue non-hello events so the snapshot's
    // setState can't clobber them. They'll be replayed when the snapshot
    // completes.
    if (_snapshotInFlight && event.type != 'hello') {
      _pendingLiveEvents.add(event);
      return;
    }

    // Track server seq; if we detect a gap relative to what the server tells
    // us it has emitted, trigger a snapshot re-fetch to re-sync.
    if (event.type == 'hello') {
      unawaited(_loadSkills(forceReload: true));
      final nextSeq = event.nextSeq;
      final last = _lastEventSeq;
      if (nextSeq != null && last != null && nextSeq > last + 1) {
        // We missed events while disconnected; try the cheap delta first,
        // fall back to a full snapshot if that fails.
        unawaited(() async {
          final needsSnapshotVerification =
              _showingCachedSnapshot || _showingPossiblyStaleSnapshot;
          final applied = await _resyncDelta(
            markTranscriptFresh: !needsSnapshotVerification,
          );
          if (mounted && (!applied || needsSnapshotVerification)) {
            await _loadSnapshot(
              messageLimit: _messageLimit,
              activityLimit: _activityLimit,
              scrollToBottom: false,
            );
          }
        }());
      }
      return;
    }
    final seq = event.seq;
    if (seq != null) {
      final last = _lastEventSeq;
      if (last == null || seq > last) {
        _lastEventSeq = seq;
      }
    }

    switch (event.type) {
      case 'user_message_submitted':
        final message = event.messageItem;
        if (message == null) {
          return;
        }
        setState(() {
          _upsertOptimisticMessage(message);
          _running = true;
          _awaitingAssistantReply = true;
        });
        _refreshThinkingState();
        _syncSessionLiveActivity();
        _scrollToBottomFast();
      case 'turn_started':
        setState(() {
          _running = true;
          _awaitingAssistantReply =
              _liveAssistantText.isEmpty && _pendingAction == null;
        });
        _refreshThinkingState();
        _syncSessionLiveActivity();
      case 'assistant_delta':
        final delta = event.delta;
        if (delta == null || delta.isEmpty) {
          return;
        }
        _assistantDeltaBuffer.write(delta);
        _scheduleLiveFlush();
      case 'assistant_message_completed':
        _flushPendingLiveUpdates();
        final message = event.messageItem;
        final committedLive = _liveAssistantMessage;
        setState(() {
          if (message != null) {
            final hasThinkingBlocks = message.content.any(
              (b) => b is ThinkingBlock,
            );
            final liveThinking =
                committedLive != null &&
                committedLive.reasoning.trim().isNotEmpty;
            if (!hasThinkingBlocks && liveThinking) {
              final reasoning = committedLive.reasoning.trimRight();
              _upsertOptimisticMessage(
                SessionMessage(
                  id: message.id,
                  role: message.role,
                  text: message.text,
                  content: [
                    ThinkingBlock(reasoning),
                    ...message.content.whereType<TextBlock>(),
                    if (!message.content.any((b) => b is TextBlock) &&
                        message.text.trim().isNotEmpty)
                      TextBlock(message.text),
                  ],
                  attachments: message.attachments,
                  createdAt: message.createdAt,
                  seq: message.seq,
                  phase: message.phase,
                ),
              );
            } else {
              _upsertOptimisticMessage(message);
            }
          } else if (committedLive != null &&
              (committedLive.text.trim().isNotEmpty ||
                  committedLive.reasoning.trim().isNotEmpty)) {
            _upsertOptimisticMessage(committedLive.toMessage());
          }
          _clearLiveAssistantMessage();
          final phase = message?.phase ?? committedLive?.phase;
          _awaitingAssistantReply =
              phase == 'commentary' && _running && _pendingAction == null;
        });
        _refreshThinkingState();
        _syncSessionLiveActivity();
        _scrollToBottomFast();
      case 'turn_completed':
        _flushPendingLiveUpdates();
        final committedLive = _liveAssistantMessage;
        setState(() {
          _running = false;
          _awaitingAssistantReply = false;
          if (committedLive != null &&
              (committedLive.text.trim().isNotEmpty ||
                  committedLive.reasoning.trim().isNotEmpty)) {
            _upsertOptimisticMessage(committedLive.toMessage());
          }
          _clearLiveAssistantMessage();
        });
        _thinkingNotifier.value = false;
        _syncSessionLiveActivity();
        // Background reconcile; do not block UI. Delayed enough for the agent to
        // finish flushing the rollout .jsonl file — otherwise the snapshot
        // reads a partial file and the new assistant message appears to
        // vanish until the user reloads.
        Future<void>.delayed(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          unawaited(
            _loadSnapshot(
              messageLimit: _messageLimit,
              activityLimit: _activityLimit,
              scrollToBottom: false,
            ),
          );
          unawaited(_loadGitStatus(silent: true));
        });
      case 'activity_updated':
        final activity = event.activity;
        if (activity == null) {
          return;
        }
        _pendingActivityUpdates[activity.id] = activity;
        _scheduleLiveFlush();
      case 'runtime_updated':
        final runtime = event.runtime;
        if (runtime == null) {
          return;
        }
        setState(() {
          _session = (_session ?? widget.session).copyWith(runtime: runtime);
        });
        _persistCurrentSessionLog();
      case 'provider_warning':
        final message = event.message;
        if (message == null || message.isEmpty) {
          return;
        }
        setState(() {
          _appendTimelineRuntimeEvent(
            _TimelineLiveEventKind.providerWarning,
            event,
          );
        });
      case 'thread_status_changed':
        final status = event.status;
        if (status == null || status.isEmpty) {
          return;
        }
        setState(() {
          _latestThreadStatus = event;
          switch (status) {
            case 'running':
              _running = true;
              _awaitingAssistantReply =
                  _liveAssistantText.isEmpty && _pendingAction == null;
            case 'waiting_for_input':
            case 'waiting_for_approval':
              _running = true;
              _awaitingAssistantReply = false;
            case 'idle':
            case 'closed':
            case 'errored':
              _running = false;
              _awaitingAssistantReply = false;
          }
        });
        _refreshThinkingState();
        _syncSessionLiveActivity();
      case 'plan_updated':
        final plan = event.plan;
        if (plan == null) {
          return;
        }
        setState(() {
          final semanticKey = 'plan:${event.sessionId}';
          if (plan.isEmpty) {
            _removeTimelineRuntimeEvent(semanticKey);
          } else {
            _appendTimelineRuntimeEvent(
              _TimelineLiveEventKind.planUpdated,
              event,
              replaceSemanticKey: semanticKey,
            );
          }
        });
        _schedulePersistCurrentSessionLog();
      case 'reasoning_delta':
        final delta = event.delta;
        if (delta == null || delta.isEmpty) {
          return;
        }
        _reasoningDeltaBuffer.write(delta);
        _scheduleLiveFlush();
        break;
      case 'queue_updated':
        setState(() {
          _latestQueueUpdate = event;
        });
      case 'auto_retry_updated':
        setState(() {
          _latestAutoRetryUpdate = event;
        });
      case 'action_opened':
        setState(() {
          _pendingAction = event.action;
          _awaitingAssistantReply = false;
        });
        _refreshThinkingState();
        _syncSessionLiveActivity();
        _persistCurrentSessionLog();
      case 'action_resolved':
        setState(() {
          _pendingAction = null;
          _awaitingAssistantReply = _running && _liveAssistantText.isEmpty;
        });
        _refreshThinkingState();
        _syncSessionLiveActivity();
        _persistCurrentSessionLog();
      case 'skills_changed':
        unawaited(_loadSkills(forceReload: true));
      case 'hello':
      case 'error':
        break;
    }
  }

  void _appendTimelineRuntimeEvent(
    _TimelineLiveEventKind kind,
    LiveEvent event, {
    String? replaceSemanticKey,
    DateTime? createdAt,
    int? seqOverride,
  }) {
    final record = _TimelineLiveEventRecord(
      kind: kind,
      event: event,
      createdAt: createdAt ?? DateTime.now(),
      seq: seqOverride ?? event.seq ?? _nextTimelineSeq(),
      keyId: replaceSemanticKey == null
          ? '${kind.name}:${event.seq ?? DateTime.now().microsecondsSinceEpoch}'
          : '${kind.name}:$replaceSemanticKey',
      semanticKey: replaceSemanticKey,
    );
    final existingIndex = replaceSemanticKey == null
        ? -1
        : _timelineLiveEvents.indexWhere(
            (candidate) => candidate.semanticKey == replaceSemanticKey,
          );
    if (existingIndex == -1) {
      final next = [..._timelineLiveEvents, record];
      _timelineLiveEvents = next.length > 16
          ? next.sublist(next.length - 16)
          : next;
      return;
    }
    final updated = [..._timelineLiveEvents];
    updated[existingIndex] = record;
    _timelineLiveEvents = updated;
  }

  void _removeTimelineRuntimeEvent(String semanticKey) {
    _timelineLiveEvents = _timelineLiveEvents
        .where((candidate) => candidate.semanticKey != semanticKey)
        .toList(growable: false);
  }

  LiveEvent? _latestPlanUpdateForCache() {
    for (var i = _timelineLiveEvents.length - 1; i >= 0; i -= 1) {
      final record = _timelineLiveEvents[i];
      final plan = record.event.plan;
      if (record.kind == _TimelineLiveEventKind.planUpdated &&
          plan != null &&
          plan.isNotEmpty) {
        return record.event;
      }
    }
    return null;
  }

  int? _restoreLatestPlanUpdate(
    LiveEvent? latestPlanUpdate, {
    required DateTime fallbackCreatedAt,
  }) {
    final plan = latestPlanUpdate?.plan;
    if (latestPlanUpdate == null ||
        latestPlanUpdate.type != 'plan_updated' ||
        plan == null) {
      return null;
    }
    final restoredSeq = latestPlanUpdate.seq ?? _nextTimelineSeq();
    if (plan.isEmpty) {
      _removeTimelineRuntimeEvent('plan:${latestPlanUpdate.sessionId}');
      return restoredSeq;
    }
    _appendTimelineRuntimeEvent(
      _TimelineLiveEventKind.planUpdated,
      latestPlanUpdate,
      replaceSemanticKey: 'plan:${latestPlanUpdate.sessionId}',
      createdAt: fallbackCreatedAt,
      seqOverride: restoredSeq,
    );
    return restoredSeq;
  }

  bool get _showRuntimeSignalStrip {
    final threadStatus = _latestThreadStatus;
    final showThreadStatus =
        threadStatus != null &&
        (threadStatus.status?.isNotEmpty ?? false) &&
        ((threadStatus.status ?? '') != 'running' ||
            (threadStatus.message?.isNotEmpty ?? false) ||
            (threadStatus.pendingActionKind?.isNotEmpty ?? false));
    final queueUpdated = _latestQueueUpdate;
    final showQueue =
        queueUpdated != null &&
        ((queueUpdated.steeringCount ?? 0) > 0 ||
            (queueUpdated.followUpCount ?? 0) > 0 ||
            (queueUpdated.steeringPreview?.isNotEmpty ?? false) ||
            (queueUpdated.followUpPreview?.isNotEmpty ?? false));
    return showThreadStatus || showQueue || _latestAutoRetryUpdate != null;
  }

  bool _shouldShowThinking() {
    return _running &&
        _awaitingAssistantReply &&
        _liveAssistantText.isEmpty &&
        _pendingAction == null;
  }

  void _refreshThinkingState() {
    _thinkingNotifier.value = _shouldShowThinking();
  }

  void _syncSessionLiveActivity({SessionActivity? latestActivity}) {
    _syncScreenAwakeSource();
    final session = _session ?? widget.session;
    final pendingAction = _pendingAction;
    if (!_running && pendingAction == null) {
      unawaited(
        LiveActivityService.instance.endPrimarySession(
          host: widget.host,
          sessionId: session.id,
        ),
      );
      return;
    }
    unawaited(
      LiveActivityService.instance.syncPrimarySession(
        host: widget.host,
        session: session,
        isRunning: _running,
        isThinking: _shouldShowThinking(),
        isResponding: _liveAssistantText.isNotEmpty,
        pendingAction: pendingAction,
        latestActivity: latestActivity ?? _latestLiveActivity(),
      ),
    );
  }

  SessionActivity? _latestLiveActivity() {
    if (_activities.isEmpty) return null;
    const terminal = {'completed', 'failed', 'declined'};
    final running = _activities
        .where((activity) => !terminal.contains(activity.status))
        .toList(growable: false);
    final candidates = running.isNotEmpty ? running : _activities;
    return candidates.reduce((left, right) {
      if (left.seq != right.seq) {
        return left.seq > right.seq ? left : right;
      }
      return left.createdAt.isAfter(right.createdAt) ? left : right;
    });
  }

  void _scheduleLiveFlush() {
    if (_liveFlushTimer != null) {
      return;
    }
    _liveFlushTimer = Timer(_liveUpdateFlushInterval, _flushPendingLiveUpdates);
  }

  void _flushPendingLiveUpdates() {
    _liveFlushTimer?.cancel();
    _liveFlushTimer = null;
    if (!mounted) {
      _assistantDeltaBuffer.clear();
      _reasoningDeltaBuffer.clear();
      _pendingActivityUpdates.clear();
      return;
    }

    final hasDelta = _assistantDeltaBuffer.isNotEmpty;
    final delta = hasDelta ? _assistantDeltaBuffer.toString() : '';
    _assistantDeltaBuffer.clear();

    final hasReasoning = _reasoningDeltaBuffer.toString().trim().isNotEmpty;
    final reasoningDelta = hasReasoning ? _reasoningDeltaBuffer.toString() : '';
    _reasoningDeltaBuffer.clear();

    final activities = _pendingActivityUpdates.values.toList();
    _pendingActivityUpdates.clear();

    if (!hasDelta && !hasReasoning && activities.isEmpty) {
      return;
    }

    final currentLive = _liveAssistantMessage;
    var updatedLive = currentLive;
    if (hasDelta) {
      updatedLive = _appendLiveAssistantDelta(updatedLive, delta);
    }
    if (hasReasoning) {
      updatedLive = _appendLiveAssistantReasoning(updatedLive, reasoningDelta);
    }
    final needsLiveInsert = updatedLive != null && currentLive == null;

    if (updatedLive != null) {
      if (needsLiveInsert || activities.isNotEmpty) {
        setState(() {
          _running = true;
          _awaitingAssistantReply = false;
          _liveAssistantNotifier.value = updatedLive;
          for (final activity in activities) {
            _upsertActivity(activity);
          }
        });
      } else {
        _running = true;
        _awaitingAssistantReply = false;
        _liveAssistantNotifier.value = updatedLive;
        if (_searchQuery.trim().isNotEmpty) {
          setState(() {});
        }
      }
      _thinkingNotifier.value = false;
    } else if (activities.isNotEmpty) {
      setState(() {
        for (final activity in activities) {
          _upsertActivity(activity);
        }
      });
    }
    _syncSessionLiveActivity();
    _schedulePersistCurrentSessionLog();
    _scrollToBottomFast();
  }

  Future<void> _pickComposerImages() async {
    if (_sending) {
      return;
    }
    if (!_supportsImageInput) {
      showAppSnackBar(
        context,
        'This session does not accept image attachments.',
      );
      return;
    }

    try {
      final pickerConfig = _composerImagePickerConfig();
      if (pickerConfig.requestPhotoLibraryAccess &&
          !await _ensureImagePickerAccess()) {
        return;
      }
      final picked = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: true,
        type: pickerConfig.type,
        allowedExtensions: pickerConfig.allowedExtensions,
      );
      if (!mounted || picked == null || picked.files.isEmpty) {
        return;
      }
      await _addPickedDraftAttachments(picked.files);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Failed to attach images: ${friendlyError(error)}',
      );
    }
  }

  _ComposerImagePickerConfig _composerImagePickerConfig() {
    if (Platform.isIOS) {
      // `FileType.image` routes iOS through the Photos gallery picker instead
      // of the Files document picker used by `FileType.custom`.
      return const _ComposerImagePickerConfig(
        type: FileType.image,
        requestPhotoLibraryAccess: true,
      );
    }
    return const _ComposerImagePickerConfig(
      type: FileType.custom,
      allowedExtensions: <String>[
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
        'bmp',
        'heic',
        'heif',
      ],
    );
  }

  Future<bool> _ensureImagePickerAccess() async {
    if (!Platform.isIOS) {
      return true;
    }
    final status = await Permission.photos.request();
    if (status.isGranted || status.isLimited) {
      return true;
    }
    if (await _supportsIosPhotoPickerWithoutLibraryAccess()) {
      return true;
    }
    if (!mounted) {
      return false;
    }
    showAppSnackBar(
      context,
      status.isPermanentlyDenied || status.isRestricted
          ? 'Photo library access is disabled for Sidemesh in iOS Settings.'
          : 'Photo library access is required to attach images.',
    );
    return false;
  }

  Future<bool> _supportsIosPhotoPickerWithoutLibraryAccess() async {
    final systemVersion = (await DeviceInfoPlugin().iosInfo).systemVersion;
    final majorVersion = int.tryParse(systemVersion.split('.').first) ?? 0;
    return majorVersion >= 14;
  }

  Future<void> _addPickedDraftAttachments(List<PlatformFile> files) async {
    final nextAttachments = List<_ComposerImageAttachment>.from(
      _draftAttachments,
    );
    var totalBytes = nextAttachments.fold<int>(
      0,
      (sum, item) => sum + item.byteLength,
    );

    for (final file in files) {
      if (nextAttachments.length >= _maxDraftImageCount) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          'You can attach up to $_maxDraftImageCount images per message.',
        );
        break;
      }

      final bytes = await _readPickedFileBytes(file);
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          'Could not read ${file.name.isEmpty ? 'that image' : file.name}.',
        );
        continue;
      }
      if (bytes.length > _maxDecodedDraftImageBytes) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          '${file.name.isEmpty ? 'That image' : file.name} is too large to process on-device.',
        );
        continue;
      }

      final mimeType = _mimeTypeForImageName(file.name);
      if (mimeType == null) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          '${file.name.isEmpty ? 'That file' : file.name} is not a supported image.',
        );
        continue;
      }

      final result = await _appendDraftImageAttachment(
        nextAttachments: nextAttachments,
        totalBytes: totalBytes,
        name: file.name.isEmpty ? 'image' : file.name,
        mimeType: mimeType,
        bytes: bytes,
      );
      totalBytes = result.totalBytes;
      if (result.shouldStop) {
        break;
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _draftAttachments = nextAttachments;
    });
  }

  Future<Uint8List?> _readPickedFileBytes(PlatformFile file) async {
    if (file.bytes != null) {
      return file.bytes;
    }
    return file.xFile.readAsBytes();
  }

  Future<bool> _pasteComposerImage({bool showEmptyFeedback = true}) async {
    if (_sending) {
      return false;
    }
    if (!_supportsImageInput) {
      if (showEmptyFeedback) {
        showAppSnackBar(
          context,
          'This session does not accept image attachments.',
        );
      }
      return false;
    }

    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        if (!mounted) return false;
        if (showEmptyFeedback) {
          showAppSnackBar(
            context,
            'Clipboard image paste is not supported here.',
          );
        }
        return false;
      }
      final clipboardImage = await _readClipboardImage(clipboard);
      if (!mounted) {
        return false;
      }
      if (clipboardImage == null) {
        if (showEmptyFeedback) {
          showAppSnackBar(context, 'Clipboard does not contain an image.');
        }
        return false;
      }

      final nextAttachments = List<_ComposerImageAttachment>.from(
        _draftAttachments,
      );
      if (nextAttachments.length >= _maxDraftImageCount) {
        showAppSnackBar(
          context,
          'You can attach up to $_maxDraftImageCount images per message.',
        );
        return false;
      }

      final totalBytes = nextAttachments.fold<int>(
        0,
        (sum, item) => sum + item.byteLength,
      );
      final result = await _appendDraftImageAttachment(
        nextAttachments: nextAttachments,
        totalBytes: totalBytes,
        name: clipboardImage.name,
        mimeType: clipboardImage.mimeType,
        bytes: clipboardImage.bytes,
      );
      if (!result.added) {
        return false;
      }
      if (!mounted) {
        return false;
      }
      setState(() {
        _draftAttachments = nextAttachments;
      });
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      showAppSnackBar(
        context,
        'Failed to paste image: ${friendlyError(error)}',
      );
      return false;
    }
  }

  Future<_ClipboardImageData?> _readClipboardImage(
    SystemClipboard clipboard,
  ) async {
    final reader = await clipboard.read();
    for (final format in _clipboardImageFormats) {
      if (!reader.canProvide(format)) {
        continue;
      }
      final image = await _readClipboardImageForFormat(reader, format);
      if (image != null) {
        return image;
      }
    }
    return null;
  }

  Future<_ClipboardImageData?> _readClipboardImageForFormat(
    ClipboardReader reader,
    FileFormat format,
  ) {
    final completer = Completer<_ClipboardImageData?>();
    final progress = reader.getFile(
      format,
      (file) async {
        final bytes = await file.readAll();
        if (completer.isCompleted) {
          return;
        }
        completer.complete(
          _ClipboardImageData(
            name:
                file.fileName ??
                'pasted-image${_imageExtensionForMimeType(_mimeTypeForClipboardFormat(format))}',
            mimeType: _mimeTypeForClipboardFormat(format),
            bytes: bytes,
          ),
        );
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );
    if (progress == null) {
      return Future<_ClipboardImageData?>.value(null);
    }
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  }

  Future<_PreparedDraftImage> _prepareDraftImageAttachment({
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final payload = await compute(_compressDraftImagePayload, <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    });

    return _PreparedDraftImage(
      name: payload['name'] as String,
      mimeType: payload['mimeType'] as String,
      bytes: payload['bytes'] as Uint8List,
    );
  }

  Future<_DraftImageAppendResult> _appendDraftImageAttachment({
    required List<_ComposerImageAttachment> nextAttachments,
    required int totalBytes,
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Could not read ${name.isEmpty ? 'that image' : name}.',
        );
      }
      return _DraftImageAppendResult.skipped(totalBytes);
    }
    if (bytes.length > _maxDecodedDraftImageBytes) {
      if (mounted) {
        showAppSnackBar(
          context,
          '${name.isEmpty ? 'That image' : name} is too large to process on-device.',
        );
      }
      return _DraftImageAppendResult.skipped(totalBytes);
    }

    final prepared = await _prepareDraftImageAttachment(
      name: name,
      mimeType: mimeType,
      bytes: bytes,
    );
    if (!mounted) {
      return _DraftImageAppendResult.skipped(totalBytes);
    }
    if (prepared.bytes.length > _maxDraftImageBytes) {
      showAppSnackBar(
        context,
        '${prepared.name} is still larger than 5 MB after compression.',
      );
      return _DraftImageAppendResult.skipped(totalBytes);
    }
    if (totalBytes + prepared.bytes.length > _maxDraftPayloadBytes) {
      showAppSnackBar(
        context,
        'Attached images are too large for one message. Remove one or pick a smaller file.',
      );
      return _DraftImageAppendResult.stop(totalBytes);
    }

    final dataUrl =
        'data:${prepared.mimeType};base64,${base64Encode(prepared.bytes)}';
    nextAttachments.add(
      _ComposerImageAttachment(
        id: 'draft-${DateTime.now().microsecondsSinceEpoch}-${nextAttachments.length}',
        name: prepared.name,
        mimeType: prepared.mimeType,
        bytes: prepared.bytes,
        dataUrl: dataUrl,
      ),
    );
    return _DraftImageAppendResult.added(totalBytes + prepared.bytes.length);
  }

  void _removeDraftAttachment(String attachmentId) {
    setState(() {
      _draftAttachments = _draftAttachments
          .where((item) => item.id != attachmentId)
          .toList();
    });
  }

  String? _mimeTypeForImageName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    if (lower.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lower.endsWith('.heif')) {
      return 'image/heif';
    }
    return null;
  }

  String _mimeTypeForClipboardFormat(FileFormat format) {
    if (identical(format, Formats.png)) return 'image/png';
    if (identical(format, Formats.jpeg)) return 'image/jpeg';
    if (identical(format, Formats.webp)) return 'image/webp';
    if (identical(format, Formats.gif)) return 'image/gif';
    if (identical(format, Formats.bmp)) return 'image/bmp';
    if (identical(format, Formats.heic)) return 'image/heic';
    if (identical(format, Formats.heif)) return 'image/heif';
    return 'image/png';
  }

  String _imageExtensionForMimeType(String mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      case 'image/bmp':
        return '.bmp';
      case 'image/heic':
        return '.heic';
      case 'image/heif':
        return '.heif';
      default:
        return '.png';
    }
  }

  List<SessionInputItem> _buildComposerInputItems(
    String text,
    List<_ComposerImageAttachment> attachments,
    List<_ComposerSkillMention> skills,
    List<_ComposerFileMention> files,
  ) {
    return <SessionInputItem>[
      if (_supportsImageInput)
        ...attachments.map((item) => SessionInputItem.image(item.dataUrl)),
      if (_supportsSkillInput)
        ...skills.map(
          (item) => SessionInputItem.skill(item.skill.name, item.skill.path),
        ),
      ...files.map(
        (item) => SessionInputItem.file(
          item.file.path,
          isDirectory: item.file.isDirectory,
        ),
      ),
      if (text.isNotEmpty) SessionInputItem.text(text),
    ];
  }

  List<SessionMessageAttachment> _buildDraftMessageAttachments(
    List<_ComposerImageAttachment> attachments,
  ) {
    if (!_supportsImageInput) {
      return const <SessionMessageAttachment>[];
    }
    return attachments
        .map(
          (item) => SessionMessageAttachment(type: 'image', url: item.dataUrl),
        )
        .toList(growable: false);
  }

  void _insertSkillMention(SkillSummary skill) {
    if (!_supportsSkillInput) {
      return;
    }
    final active =
        _activeSkillQuery ??
        _extractActiveSkillQuery(_composerController.value);
    if (active == null) {
      return;
    }

    final tokenText = skill.mentionToken;
    final value = _composerController.value;
    final text = value.text;
    final replaced = text.replaceRange(active.start, active.end, '$tokenText ');
    final cursorOffset = active.start + tokenText.length + 1;
    _composerController.value = value.copyWith(
      text: replaced,
      selection: TextSelection.collapsed(offset: cursorOffset),
      composing: TextRange.empty,
    );

    final nextMentions = List<_ComposerSkillMention>.from(_draftSkillMentions);
    if (!nextMentions.any((item) => item.skill.path == skill.path)) {
      nextMentions.add(
        _ComposerSkillMention(skill: skill, tokenText: tokenText),
      );
    }

    HapticFeedback.selectionClick();
    if (!mounted) {
      _draftSkillMentions = nextMentions;
      _activeSkillQuery = null;
      return;
    }
    setState(() {
      _draftSkillMentions = nextMentions;
      _activeSkillQuery = null;
    });
  }

  void _removeDraftSkillMention(String skillPath) {
    _ComposerSkillMention? mention;
    for (final item in _draftSkillMentions) {
      if (item.skill.path == skillPath) {
        mention = item;
        break;
      }
    }
    if (mention == null) {
      return;
    }

    final nextText = _removeTokenFromText(
      _composerController.text,
      mention.tokenText,
    );
    _composerController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    setState(() {
      _draftSkillMentions = _draftSkillMentions
          .where((item) => item.skill.path != skillPath)
          .toList(growable: false);
    });
  }

  String _removeTokenFromText(String text, String tokenText) {
    final escaped = RegExp.escape(tokenText);
    var next = text.replaceAllMapped(
      RegExp('(^|\\s)$escaped(?=\\s|\$)'),
      (match) => match.group(1) ?? '',
    );
    next = next.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
    next = next.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return next.trim();
  }

  void _insertFileMention(FsSearchResult file) {
    final active =
        _activeFileQuery ?? _extractActiveFileQuery(_composerController.value);
    if (active == null) {
      return;
    }

    final tokenText = _fileMentionToken(file);
    final value = _composerController.value;
    final text = value.text;
    final replaced = text.replaceRange(active.start, active.end, '$tokenText ');
    final cursorOffset = active.start + tokenText.length + 1;
    _composerController.value = value.copyWith(
      text: replaced,
      selection: TextSelection.collapsed(offset: cursorOffset),
      composing: TextRange.empty,
    );

    final nextMentions = List<_ComposerFileMention>.from(_draftFileMentions);
    if (!nextMentions.any((item) => item.file.path == file.path)) {
      nextMentions.add(_ComposerFileMention(file: file, tokenText: tokenText));
    }

    HapticFeedback.selectionClick();
    if (!mounted) {
      _draftFileMentions = nextMentions;
      _activeFileQuery = null;
      return;
    }
    setState(() {
      _draftFileMentions = nextMentions;
      _activeFileQuery = null;
    });
  }

  void _removeDraftFileMention(String filePath) {
    _ComposerFileMention? mention;
    for (final item in _draftFileMentions) {
      if (item.file.path == filePath) {
        mention = item;
        break;
      }
    }
    if (mention == null) {
      return;
    }

    final nextText = _removeTokenFromText(
      _composerController.text,
      mention.tokenText,
    );
    _composerController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    setState(() {
      _draftFileMentions = _draftFileMentions
          .where((item) => item.file.path != filePath)
          .toList(growable: false);
    });
  }

  Future<void> _loadPendingSends() async {
    final pending = await _sendOutbox.loadForSession(
      widget.host,
      widget.session.id,
    );
    if (!mounted || _disposed) {
      return;
    }
    setState(() {
      _pendingSends = pending;
      for (final send in pending) {
        _upsertOptimisticMessage(send.message);
      }
    });
    _schedulePendingSendRetry();
  }

  Future<bool> _queuePendingSend({
    required String clientMessageId,
    required String text,
    required List<SessionInputItem> inputItems,
    required SessionMessage message,
    required String? model,
    required String? mode,
    required String? reasoningEffort,
    required bool? fastMode,
    required String? approvalPolicy,
    required String? sandboxMode,
    required bool? networkAccess,
    required Object error,
  }) async {
    final now = DateTime.now();
    final pending = PendingSessionSend(
      hostId: widget.host.id,
      hostFingerprint: SessionSendOutboxStore.hostFingerprint(widget.host),
      sessionId: widget.session.id,
      clientMessageId: clientMessageId,
      text: text,
      inputItems: inputItems,
      message: message,
      createdAt: now,
      updatedAt: now,
      nextAttemptAt: now.add(_pendingSendBackoff(0)),
      retryCount: 0,
      model: model,
      mode: mode,
      reasoningEffort: reasoningEffort,
      fastMode: fastMode,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      networkAccess: networkAccess,
      lastError: friendlyError(error),
    );
    final saved = await _sendOutbox.upsert(pending);
    if (!saved) {
      return false;
    }
    if (!mounted || _disposed) {
      return true;
    }
    setState(() => _upsertPendingSend(pending));
    _schedulePendingSendRetry();
    SessionSendOutboxWorker.instance.poke();
    return true;
  }

  void _upsertPendingSend(PendingSessionSend pending) {
    final existingIndex = _pendingSends.indexWhere(
      (item) => item.key == pending.key,
    );
    if (existingIndex == -1) {
      _pendingSends = [..._pendingSends, pending];
      return;
    }
    final updated = [..._pendingSends];
    updated[existingIndex] = pending;
    _pendingSends = updated;
  }

  void _removePendingSend(PendingSessionSend pending) {
    _pendingSends = _pendingSends
        .where((item) => item.key != pending.key)
        .toList(growable: false);
  }

  void _removeOptimisticPendingMessage(PendingSessionSend pending) {
    _optimisticMessages = _optimisticMessages
        .where((message) => message.id != pending.clientMessageId)
        .toList(growable: false);
  }

  Future<void> _movePendingSendToComposer(PendingSessionSend pending) async {
    await _sendOutbox.remove(pending);
    if (!mounted || _disposed) {
      return;
    }
    setState(() {
      _removePendingSend(pending);
      _removeOptimisticPendingMessage(pending);
    });
    _schedulePendingSendRetry();
    _applyComposerSeed(
      SessionComposerSeed(text: pending.text, inputItems: pending.inputItems),
    );
    showAppSnackBar(context, 'Queued message moved back into the composer.');
  }

  Future<void> _discardPendingSend(PendingSessionSend pending) async {
    await _sendOutbox.remove(pending);
    if (!mounted || _disposed) {
      return;
    }
    setState(() {
      _removePendingSend(pending);
      _removeOptimisticPendingMessage(pending);
    });
    _schedulePendingSendRetry();
    showAppSnackBar(context, 'Queued message discarded.');
  }

  Duration _pendingSendBackoff(int retryCount) {
    const steps = <Duration>[
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 45),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ];
    return steps[math.min(retryCount, steps.length - 1)];
  }

  void _schedulePendingSendRetry() {
    _pendingSendRetryTimer?.cancel();
    _pendingSendRetryTimer = null;
    if (_pendingSends.isEmpty || _disposed) {
      return;
    }
    final now = DateTime.now();
    final retryable = _pendingSends
        .where((send) => !send.blocked)
        .toList(growable: false);
    if (retryable.isEmpty) {
      return;
    }
    final nextAttempt = retryable
        .map((send) => send.nextAttemptAt)
        .reduce((left, right) => left.isBefore(right) ? left : right);
    final delay = nextAttempt.isAfter(now)
        ? nextAttempt.difference(now)
        : Duration.zero;
    _pendingSendRetryTimer = Timer(
      delay,
      () => unawaited(_retryPendingSends()),
    );
  }

  PendingSessionSend? _nextPendingSendForRetry({required bool manual}) {
    final now = DateTime.now();
    final candidates = _pendingSends
        .where((send) {
          if (manual) {
            return true;
          }
          return !send.blocked && !send.nextAttemptAt.isAfter(now);
        })
        .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((left, right) {
      final nextAttemptCompare = left.nextAttemptAt.compareTo(
        right.nextAttemptAt,
      );
      if (nextAttemptCompare != 0) {
        return nextAttemptCompare;
      }
      return left.createdAt.compareTo(right.createdAt);
    });
    return candidates.first;
  }

  Future<void> _retryPendingSends({bool manual = false}) async {
    _pendingSendRetryTimer?.cancel();
    _pendingSendRetryTimer = null;
    if (_retryingPendingSend ||
        _pendingSends.isEmpty ||
        !mounted ||
        _disposed) {
      return;
    }
    final pending = _nextPendingSendForRetry(manual: manual);
    if (pending == null) {
      _schedulePendingSendRetry();
      return;
    }
    final session = _session ?? widget.session;

    _retryingPendingSend = true;
    setState(() {});
    try {
      final normalizedOverrides = normalizeSessionSendOverrides(
        turnConfig: SessionTurnConfig(
          model: pending.model,
          mode: pending.mode,
          reasoningEffort: pending.reasoningEffort,
          fastMode: pending.fastMode,
        ),
        policy: SessionPolicy(
          approval: ApprovalPolicy.fromWire(pending.approvalPolicy),
          sandbox: SandboxMode.fromWire(pending.sandboxMode),
          networkAccess: pending.networkAccess,
        ),
        runtime: session.runtime,
        nodeInfo: _nodeInfo,
        providerKind: session.provider,
      );
      await widget.api.sendInput(
        widget.host,
        sessionId: pending.sessionId,
        text: pending.text,
        input: pending.inputItems,
        clientMessageId: pending.clientMessageId,
        model: normalizedOverrides.model,
        mode: normalizedOverrides.mode,
        reasoningEffort: normalizedOverrides.reasoningEffort,
        fastMode: normalizedOverrides.fastMode,
        approvalPolicy: normalizedOverrides.approvalPolicy,
        sandboxMode: normalizedOverrides.sandboxMode,
        networkAccess: normalizedOverrides.networkAccess,
      );
      HostStatusStore.instance.markOnline(widget.host.id);
      await _sendOutbox.remove(pending);
      if (!mounted || _disposed) {
        return;
      }
      setState(() {
        _completedPendingSendIds.add(pending.clientMessageId);
        _removePendingSend(pending);
      });
      unawaited(
        _loadSnapshot(
          messageLimit: _messageLimit,
          activityLimit: _activityLimit,
          scrollToBottom: false,
        ),
      );
      showAppSnackBar(
        context,
        'Pending message sent.',
        duration: const Duration(seconds: 2),
      );
    } catch (error) {
      if (!mounted || _disposed) {
        return;
      }
      final message = friendlyError(error);
      if (isRetryableSendError(error)) {
        HostStatusStore.instance.markOffline(widget.host.id, error: message);
        final retryCount = pending.retryCount + 1;
        final updated = pending.copyWith(
          updatedAt: DateTime.now(),
          nextAttemptAt: DateTime.now().add(_pendingSendBackoff(retryCount)),
          retryCount: retryCount,
          lastError: message,
          blocked: false,
        );
        final saved = await _sendOutbox.upsert(updated);
        if (!mounted || _disposed) {
          return;
        }
        if (saved) {
          setState(() => _upsertPendingSend(updated));
        } else {
          await _sendOutbox.remove(pending);
          if (!mounted || _disposed) {
            return;
          }
          setState(() => _removePendingSend(pending));
          showAppSnackBar(
            context,
            'Pending message is too large to keep retrying.',
          );
        }
      } else {
        final updated = pending.copyWith(
          updatedAt: DateTime.now(),
          retryCount: pending.retryCount + 1,
          lastError: message,
          blocked: true,
        );
        await _sendOutbox.upsert(updated);
        if (!mounted || _disposed) {
          return;
        }
        setState(() => _upsertPendingSend(updated));
        showAppSnackBar(context, 'Pending message needs attention: $message');
      }
    } finally {
      if (mounted && !_disposed) {
        setState(() => _retryingPendingSend = false);
        _schedulePendingSendRetry();
      } else {
        _retryingPendingSend = false;
      }
    }
  }

  Future<void> _dropResolvedPendingSends(
    List<SessionMessage> persistedMessages,
  ) async {
    if (_pendingSends.isEmpty || persistedMessages.isEmpty) {
      return;
    }
    final resolved = _pendingSends
        .where((pending) {
          return persistedMessages.any(
            (persisted) => _matchesPersistedPendingSend(persisted, pending),
          );
        })
        .toList(growable: false);
    if (resolved.isEmpty) {
      return;
    }
    for (final pending in resolved) {
      await _sendOutbox.remove(pending);
    }
    if (!mounted || _disposed) {
      return;
    }
    setState(() {
      for (final pending in resolved) {
        _completedPendingSendIds.add(pending.clientMessageId);
        _removePendingSend(pending);
      }
      _optimisticMessages = _reconcileOptimisticMessages(_messages);
    });
    _schedulePendingSendRetry();
  }

  Future<void> _sendInput() async {
    final text = _composerController.text.trim();
    final draftAttachments = List<_ComposerImageAttachment>.from(
      _draftAttachments,
    );
    final draftSkillMentions = List<_ComposerSkillMention>.from(
      _draftSkillMentions.where((item) => text.contains(item.tokenText)),
    );
    final draftFileMentions = List<_ComposerFileMention>.from(
      _draftFileMentions.where((item) => text.contains(item.tokenText)),
    );
    if ((text.isEmpty &&
            draftAttachments.isEmpty &&
            draftFileMentions.isEmpty) ||
        _sending) {
      return;
    }

    final wasRunning = _running;
    final inputItems = _buildComposerInputItems(
      text,
      draftAttachments,
      draftSkillMentions,
      draftFileMentions,
    );
    if (inputItems.isEmpty) {
      return;
    }
    final policy = _policyStore.policyFor(widget.host, widget.session.id);
    final turnConfig = _turnConfigStore.configFor(
      widget.host,
      widget.session.id,
    );
    final session = _session ?? widget.session;
    final normalizedOverrides = normalizeSessionSendOverrides(
      turnConfig: turnConfig,
      policy: policy,
      runtime: session.runtime,
      nodeInfo: _nodeInfo,
      providerKind: session.provider,
    );
    final retrySignature = _buildSendRetrySignature(
      inputItems: inputItems,
      model: normalizedOverrides.model,
      mode: normalizedOverrides.mode,
      reasoningEffort: normalizedOverrides.reasoningEffort,
      fastMode: normalizedOverrides.fastMode,
      approvalPolicy: normalizedOverrides.approvalPolicy,
      sandboxMode: normalizedOverrides.sandboxMode,
      networkAccess: normalizedOverrides.networkAccess,
    );
    final clientMessageId = _clientMessageIdForSend(retrySignature);
    final optimisticMessage = SessionMessage(
      id: clientMessageId,
      role: 'user',
      text: text,
      content: text.trim().isNotEmpty ? [TextBlock(text)] : const [],
      attachments: _buildDraftMessageAttachments(draftAttachments),
      createdAt: DateTime.now(),
      seq: _nextTimelineSeq(),
    );

    _composerController.clear();
    setState(() {
      _sending = true;
      _running = true;
      _awaitingAssistantReply = true;
      _draftAttachments = const <_ComposerImageAttachment>[];
      _draftSkillMentions = const <_ComposerSkillMention>[];
      _clearLiveAssistantMessage();
      _upsertOptimisticMessage(optimisticMessage);
    });
    _refreshThinkingState();
    _syncSessionLiveActivity();
    _scrollToBottomFast(force: true);
    if (widget.desktopMode) {
      _queueComposerFocusRestore(onlyIfSafe: true);
    }
    try {
      await widget.api.sendInput(
        widget.host,
        sessionId: widget.session.id,
        text: text,
        input: inputItems,
        clientMessageId: optimisticMessage.id,
        model: normalizedOverrides.model,
        mode: normalizedOverrides.mode,
        reasoningEffort: normalizedOverrides.reasoningEffort,
        fastMode: normalizedOverrides.fastMode,
        approvalPolicy: normalizedOverrides.approvalPolicy,
        sandboxMode: normalizedOverrides.sandboxMode,
        networkAccess: normalizedOverrides.networkAccess,
      );
      if (!mounted) {
        return;
      }
      await _sendOutbox.removeFor(
        hostId: widget.host.id,
        hostFingerprint: SessionSendOutboxStore.hostFingerprint(widget.host),
        sessionId: widget.session.id,
        clientMessageId: optimisticMessage.id,
      );
      if (!mounted) {
        return;
      }
      _clearFailedSendRetry();
    } catch (error) {
      if (!mounted) {
        return;
      }
      final retryable = isRetryableSendError(error);
      if (retryable) {
        final queued = await _queuePendingSend(
          clientMessageId: optimisticMessage.id,
          text: text,
          inputItems: inputItems,
          message: optimisticMessage,
          model: normalizedOverrides.model,
          mode: normalizedOverrides.mode,
          reasoningEffort: normalizedOverrides.reasoningEffort,
          fastMode: normalizedOverrides.fastMode,
          approvalPolicy: normalizedOverrides.approvalPolicy,
          sandboxMode: normalizedOverrides.sandboxMode,
          networkAccess: normalizedOverrides.networkAccess,
          error: error,
        );
        if (!mounted) {
          return;
        }
        if (queued) {
          HostStatusStore.instance.markOffline(
            widget.host.id,
            error: friendlyError(error),
          );
          showAppSnackBar(
            context,
            'Message queued. Sidemesh will retry when the host is reachable.',
          );
          setState(() {
            _running = wasRunning;
            _awaitingAssistantReply =
                wasRunning &&
                _liveAssistantText.isEmpty &&
                _pendingAction == null;
          });
          _refreshThinkingState();
          _syncSessionLiveActivity();
          return;
        }
      }
      _rememberFailedSendRetry(optimisticMessage.id, retrySignature);
      _composerController.text = text;
      _composerController.selection = TextSelection.collapsed(
        offset: _composerController.text.length,
      );
      final stillHasPending = _pendingAction != null;
      final restoredAttachments = List<_ComposerImageAttachment>.from(
        draftAttachments,
      );
      final restoredSkillMentions = List<_ComposerSkillMention>.from(
        draftSkillMentions,
      );
      final restoredFileMentions = List<_ComposerFileMention>.from(
        draftFileMentions,
      );
      showAppSnackBar(context, "Failed to send: ${friendlyError(error)}");
      setState(() {
        _optimisticMessages = _optimisticMessages
            .where((message) => message.id != optimisticMessage.id)
            .toList();
        _draftAttachments = restoredAttachments;
        _draftSkillMentions = restoredSkillMentions;
        _draftFileMentions = restoredFileMentions;
        _running = wasRunning;
        _awaitingAssistantReply =
            wasRunning && _liveAssistantText.isEmpty && !stillHasPending;
      });
      _refreshThinkingState();
      _syncSessionLiveActivity();
      if (widget.desktopMode) {
        _queueComposerFocusRestore(onlyIfSafe: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  String _buildSendRetrySignature({
    required List<SessionInputItem> inputItems,
    required String? model,
    required String? mode,
    required String? reasoningEffort,
    required bool? fastMode,
    required String? approvalPolicy,
    required String? sandboxMode,
    required bool? networkAccess,
  }) {
    return jsonEncode({
      'input': inputItems.map((item) => item.toJson()).toList(),
      'model': model,
      'mode': mode,
      'reasoningEffort': reasoningEffort,
      'fastMode': fastMode,
      'approvalPolicy': approvalPolicy,
      'sandboxMode': sandboxMode,
      'networkAccess': networkAccess,
    });
  }

  String _clientMessageIdForSend(String retrySignature) {
    final retryId = _failedSendRetryClientMessageId;
    final retryExpiresAt = _failedSendRetryExpiresAt;
    if (retryId != null &&
        _failedSendRetrySignature == retrySignature &&
        retryExpiresAt != null &&
        DateTime.now().isBefore(retryExpiresAt)) {
      return retryId;
    }
    return 'local-${DateTime.now().microsecondsSinceEpoch}';
  }

  void _rememberFailedSendRetry(String clientMessageId, String signature) {
    _failedSendRetryClientMessageId = clientMessageId;
    _failedSendRetrySignature = signature;
    _failedSendRetryExpiresAt = DateTime.now().add(_failedSendRetryWindow);
  }

  void _clearFailedSendRetry() {
    _failedSendRetryClientMessageId = null;
    _failedSendRetrySignature = null;
    _failedSendRetryExpiresAt = null;
  }

  Future<bool> _showSessionConfirmDialog({
    required IconData icon,
    required String title,
    required String body,
    required String confirmLabel,
    bool danger = false,
  }) async {
    Future<bool> showConfirm() => showMeshConfirmDialog(
      context,
      icon: icon,
      title: title,
      description: body,
      confirmLabel: confirmLabel,
      danger: danger,
      maxWidth: 420,
    );
    if (!widget.desktopMode) {
      return showConfirm();
    }
    return await _showDesktopOverlayWithComposerFocusRestore(showConfirm) ??
        false;
  }

  Future<String?> _promptSessionName(String current) async {
    final controller = TextEditingController(text: current)
      ..selection = TextSelection(baseOffset: 0, extentOffset: current.length);
    final nextName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return MeshDialogScaffold(
          icon: Icons.edit_outlined,
          title: 'Rename session',
          description: 'Choose the name shown in Sidemesh.',
          maxWidth: 460,
          showCloseButton: true,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Save name'),
            ),
          ],
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Session name'),
            textInputAction: TextInputAction.done,
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
        );
      },
    );
    controller.dispose();
    return nextName;
  }

  Future<void> _stopSession() async {
    if (!_supportsSessionInterrupt) {
      showAppSnackBar(
        context,
        'Stopping the agent is not available for this session yet.',
      );
      return;
    }
    final confirmed = await _showSessionConfirmDialog(
      icon: Icons.stop_circle_outlined,
      title: 'Stop the agent?',
      body:
          'The current task will stop. Any tools that are still running may not finish cleanly.',
      confirmLabel: 'Stop agent',
      danger: true,
    );
    if (!confirmed) return;
    if (!mounted) return;
    try {
      await widget.api.stopSession(widget.host, widget.session.id);
      if (!mounted) {
        return;
      }
      HapticFeedback.mediumImpact();
      setState(() {
        _running = false;
        _awaitingAssistantReply = false;
        _clearLiveAssistantMessage();
      });
      _refreshThinkingState();
      _syncSessionLiveActivity();
      showAppSnackBar(
        context,
        'Agent stopped.',
        duration: const Duration(seconds: 2),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Failed to stop the agent: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _compactSession() async {
    if (!_supportsSessionCompact) {
      showAppSnackBar(
        context,
        'Context compaction is not available for this session.',
      );
      return;
    }
    if (_running) {
      showAppSnackBar(context, 'Wait for the current turn to finish first.');
      return;
    }
    final confirmed = await _showSessionConfirmDialog(
      icon: Icons.compress_rounded,
      title: 'Compact this session?',
      body:
          'Older context will be summarized so future replies can use fewer tokens. Recent messages stay visible in Sidemesh.',
      confirmLabel: 'Start compaction',
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await widget.api.compactSession(widget.host, widget.session.id);
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Compaction started.',
        duration: const Duration(seconds: 2),
      );
      _reloadSnapshot();
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        "Failed to compact session: ${friendlyError(error)}",
      );
    }
  }

  Future<void> _renameSession() async {
    if (!_supportsSessionRename) {
      showAppSnackBar(context, 'Renaming is not available for this session.');
      return;
    }
    final current = (_session ?? widget.session).title;
    final newName = await _promptSessionName(current);
    final trimmed = newName?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == current) {
      return;
    }
    try {
      final updated = await widget.api.renameSession(
        widget.host,
        sessionId: widget.session.id,
        name: trimmed,
      );
      if (!mounted) {
        return;
      }
      setState(() => _session = updated);
      _syncSessionLiveActivity();
      SessionOverridesStore.instance.apply(widget.host.id, updated);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, "Failed to rename: ${friendlyError(error)}");
    }
  }

  Future<void> _archiveSession() async {
    if (!_supportsSessionArchive) {
      showAppSnackBar(context, 'Archiving is not available for this session.');
      return;
    }
    final confirmed = await _showSessionConfirmDialog(
      icon: Icons.archive_outlined,
      title: 'Archive this session?',
      body:
          'Archived sessions disappear from Recent. You can still restore them later from the host.',
      confirmLabel: 'Archive session',
    );
    if (!confirmed) {
      return;
    }
    try {
      await widget.api.archiveSession(widget.host, widget.session.id);
      if (!mounted) {
        return;
      }
      unawaited(
        LiveActivityService.instance.endPrimarySession(
          host: widget.host,
          sessionId: widget.session.id,
        ),
      );
      final onArchived = widget.onArchived;
      if (onArchived != null) {
        onArchived();
      } else {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, "Failed to archive: ${friendlyError(error)}");
    }
  }

  Future<void> _toggleFavorite() async {
    await _localStore.toggleFavorite(widget.host, widget.session.id);
  }

  Future<void> _markSessionUnread() async {
    final session = _session ?? widget.session;
    setState(() => _keepSessionUnread = true);
    _readStore.markUnread(widget.host, session.id);
    await _readStore.flush();
    if (!mounted) {
      return;
    }
    showAppSnackBar(
      context,
      'Flagged for follow-up — you\'ll see a blue dot in your recents list.',
    );
  }

  Future<void> _toggleMessagePin(SessionMessage message) async {
    if (!message.hasVisibleContent) {
      return;
    }
    final pinned = await _pinsStore.togglePin(
      widget.host,
      widget.session.id,
      message,
    );
    if (!mounted) return;
    HapticFeedback.selectionClick();
    showAppSnackBar(
      context,
      pinned ? 'Pinned message' : 'Unpinned message',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _unpinMessage(PinnedSessionMessage pin) async {
    await _pinsStore.unpin(widget.host, widget.session.id, pin.messageId);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    showAppSnackBar(
      context,
      'Unpinned message',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _showPinnedMessage(PinnedSessionMessage pin) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => _PinnedMessageSheet(
        pin: pin,
        onUnpin: () {
          Navigator.of(sheetContext).pop();
          unawaited(_unpinMessage(pin));
        },
        onOpenFile: _openWorkspaceFile,
      ),
    );
  }

  Future<void> _respondAction(PendingActionResponseDraft response) async {
    final action = _pendingAction;
    if (action == null) {
      return;
    }
    HapticFeedback.mediumImpact(); // immediate tactile confirmation
    try {
      await widget.api.respondToAction(
        widget.host,
        actionId: action.id,
        response: response,
      );
      if (!mounted) {
        return;
      }
      HapticFeedback.selectionClick();
      setState(() {
        _pendingAction = null;
      });
      _syncSessionLiveActivity();
      final label = switch (action.kind) {
        'user_input' => 'Answer sent',
        'elicitation' => 'Response sent',
        _ => switch (response.payload['decision']) {
          'accept' => 'Approved this step',
          'acceptForSession' => 'Approved for the rest of the session',
          'decline' => 'Declined',
          'cancel' => 'Cancelled',
          _ => 'Decision sent',
        },
      };
      showAppSnackBar(context, label, duration: const Duration(seconds: 2));
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        "Failed to resolve action: ${friendlyError(error)}",
      );
    }
  }

  Future<void> _showGitSheet(
    SessionSummary session, {
    bool forceRefresh = false,
  }) async {
    if (!_supportsGitStatus) {
      showAppSnackBar(context, 'Git status is not available for this session.');
      return;
    }
    if (forceRefresh || _gitStatus == null) {
      await _loadGitStatus();
    }
    if (!mounted) return;
    Future<void> showSheet() => showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      builder: (sheetContext) => _GitDetailsSheet(
        session: session,
        status: _gitStatus,
        loading: _gitStatusLoading,
        error: _gitStatusError,
        onRefresh: () {
          Navigator.of(sheetContext).pop();
          unawaited(_showGitSheet(session, forceRefresh: true));
        },
        onShowDiff: (kind) {
          Navigator.of(sheetContext).pop();
          unawaited(_showGitDiffSheet(kind));
        },
      ),
    );
    if (widget.desktopMode) {
      await _showDesktopOverlayWithComposerFocusRestore(showSheet);
      return;
    }
    await showSheet();
  }

  Future<void> _showGitDiffSheet(String kind) async {
    if (!_supportsGitDiffKind(kind)) {
      showAppSnackBar(
        context,
        'This Git diff is not available for this session.',
      );
      return;
    }
    if (!mounted) return;
    Future<void> showSheet() => showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _GitDiffSheet(
        future: widget.api.fetchGitDiff(
          widget.host,
          widget.session.id,
          kind: kind,
        ),
      ),
    );
    if (widget.desktopMode) {
      await _showDesktopOverlayWithComposerFocusRestore(showSheet);
      return;
    }
    await showSheet();
  }

  Future<void> _showSessionDetailsSheet(SessionSummary session) async {
    final colors = context.colors;
    final gitLabel = _supportsGitStatus
        ? _gitHeaderLabel(session, _gitStatus)
        : null;
    Widget sectionLabel(String title, String subtitle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textPrimary,
              fontWeight: AppWeights.title,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.35,
            ),
          ),
        ],
      );
    }

    Future<void> showSheet() => showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => MeshBottomSheetScaffold(
        icon: Icons.info_outline_rounded,
        title: 'Session details',
        description:
            'See where this session is running and the live settings the agent is using.',
        maxWidth: 760,
        maxHeightFactor: 0.86,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MeshCard(
                tone: MeshCardTone.muted,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Running on ${widget.host.label}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        MeshPill(
                          label: _running ? 'running' : 'idle',
                          icon: _running
                              ? Icons.play_circle_outline_rounded
                              : Icons.pause_circle_outline_rounded,
                          tone: _running
                              ? MeshPillTone.success
                              : MeshPillTone.neutral,
                        ),
                        MeshPill(
                          label: session.source,
                          icon: Icons.route_rounded,
                          tone: MeshPillTone.neutral,
                        ),
                        if (gitLabel != null)
                          MeshPill(
                            label: gitLabel,
                            icon: Icons.account_tree_rounded,
                            tone: MeshPillTone.info,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              sectionLabel(
                'Overview',
                'Where this session is running and how it started.',
              ),
              const SizedBox(height: 8),
              MeshCard(
                tone: MeshCardTone.muted,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(label: 'Host', value: widget.host.label),
                    _DetailRow(label: 'Folder', value: session.cwd),
                    _DetailRow(
                      label: 'Status',
                      value: _running ? 'Running' : 'Idle',
                    ),
                    _DetailRow(label: 'Started from', value: session.source),
                    if (gitLabel != null)
                      _DetailRow(label: 'Git', value: gitLabel),
                  ],
                ),
              ),
              if (gitLabel != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    unawaited(_showGitSheet(session));
                  },
                  icon: const Icon(Icons.account_tree_rounded, size: 18),
                  label: const Text('View Git details'),
                ),
              ],
              if (session.runtime != null) ...[
                const SizedBox(height: 14),
                sectionLabel(
                  'Runtime now',
                  'Live settings the agent is using for this session.',
                ),
                const SizedBox(height: 8),
                _SessionRuntimeDetails(runtime: session.runtime!),
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.desktopMode) {
      await _showDesktopOverlayWithComposerFocusRestore(showSheet);
      return;
    }
    await showSheet();
  }

  String? _cleanComposerLabel(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  String _compactComposerModelLabel(String value) {
    final model = value.split('/').last.trim();
    if (model.length <= 24) {
      return model;
    }
    return '${model.substring(0, 21)}...';
  }

  SessionTurnConfig _composerTurnConfig(SessionSummary session) {
    return _turnConfigStore.configFor(widget.host, session.id);
  }

  String _composerModelLabel(SessionSummary session) {
    final turnConfig = _composerTurnConfig(session);
    final override = _cleanComposerLabel(turnConfig.model);
    if (override != null) {
      return _compactComposerModelLabel(override);
    }
    final runtime = _cleanComposerLabel(session.runtime?.model);
    if (runtime != null) {
      return _compactComposerModelLabel(runtime);
    }
    final provider = agentProviderDisplayLabel(
      session.provider,
      nodeInfo: _nodeInfo,
    );
    return provider ?? 'Model';
  }

  String _composerModelDetail(SessionSummary session) {
    final turnConfig = _composerTurnConfig(session);
    if (_cleanComposerLabel(turnConfig.model) != null) {
      return 'Next reply';
    }
    if (_cleanComposerLabel(session.runtime?.model) != null) {
      return 'Current model';
    }
    if (agentProviderDisplayLabel(session.provider, nodeInfo: _nodeInfo) !=
        null) {
      return 'Agent default';
    }
    return 'Choose model';
  }

  bool _composerModelCustomized(SessionSummary session) {
    return _cleanComposerLabel(_composerTurnConfig(session).model) != null;
  }

  String _composerThinkingLabel(SessionSummary session) {
    final turnConfig = _composerTurnConfig(session);
    final override = _cleanComposerLabel(turnConfig.reasoningEffort);
    if (override != null) {
      return _reasoningEffortLabel(override);
    }
    final runtime = _cleanComposerLabel(session.runtime?.reasoningEffort);
    if (runtime != null) {
      return _reasoningEffortLabel(runtime);
    }
    return 'Auto';
  }

  String _composerThinkingDetail(SessionSummary session) {
    final turnConfig = _composerTurnConfig(session);
    if (_cleanComposerLabel(turnConfig.reasoningEffort) != null) {
      return 'Next reply';
    }
    if (_cleanComposerLabel(session.runtime?.reasoningEffort) != null) {
      return 'Current thinking';
    }
    return 'Thinking';
  }

  bool _composerThinkingCustomized(SessionSummary session) {
    return _cleanComposerLabel(
          _composerTurnConfig(session).reasoningEffort,
        ) !=
        null;
  }

  String? _composerRuntimeModelProvider(SessionSummary session) {
    final provider = _cleanComposerLabel(session.runtime?.modelProvider);
    if (provider == null || provider == 'openai') {
      return null;
    }
    return provider;
  }

  Future<ProviderCapabilities?> _loadComposerCapabilities(
    SessionSummary session,
  ) async {
    NodeInfo? node = _nodeInfo;
    if (node == null) {
      try {
        node = await widget.api.fetchNode(widget.host);
        if (!mounted || _disposed) return null;
        setState(() => _nodeInfo = node);
      } catch (_) {
        // Model loading below will show the user-facing error if the host is
        // unavailable. Capability checks are best-effort here.
      }
    }
    return node?.capabilitiesForProvider(session.provider);
  }

  Future<List<ModelCatalogEntry>?> _fetchComposerModels(
    SessionSummary session,
  ) async {
    try {
      final models = [
        ...await widget.api.fetchModels(
          widget.host,
          cwd: session.cwd,
          agentProvider: session.provider,
          provider: _composerRuntimeModelProvider(session),
        ),
      ];
      models.sort(_compareModelEntries);
      return models;
    } catch (error) {
      if (!mounted || _disposed) return null;
      showAppSnackBar(context, friendlyError(error));
      return null;
    }
  }

  Future<void> _showComposerModelPicker(SessionSummary session) async {
    await _turnConfigStore.ensureLoaded();
    if (!mounted || _disposed) return;

    final capabilities = await _loadComposerCapabilities(session);
    if (!mounted || _disposed) return;
    if (capabilities != null &&
        (!capabilities.supports('configuration', 'models') ||
            !capabilities.supports('runtimeControls', 'model'))) {
      showAppSnackBar(context, 'This agent does not offer model choices here.');
      return;
    }

    final models = await _fetchComposerModels(session);
    if (!mounted || _disposed) return;
    if (models == null) return;
    if (models.isEmpty) {
      showAppSnackBar(
        context,
        'No models are available from this host right now.',
      );
      return;
    }

    final turnConfig = _composerTurnConfig(session);
    final defaultModel = models.firstWhere(
      (model) => model.isDefault,
      orElse: () => models.first,
    );
    final currentModel =
        _cleanComposerLabel(turnConfig.model) ??
        _cleanComposerLabel(session.runtime?.model) ??
        defaultModel.model;
    final selected = await _showDesktopOverlayWithComposerFocusRestore(
      () => _showComposerModelPickerSurface(
        models: models,
        currentModel: currentModel,
        providerName: _composerRuntimeModelProvider(session),
      ),
    );
    if (!mounted || _disposed || selected == null) return;

    final nextConfig = _composerConfigForSelectedModel(
      session: session,
      current: turnConfig,
      selected: selected,
      capabilities: capabilities,
    );
    if (_sameTurnConfig(nextConfig, turnConfig)) {
      showAppSnackBar(context, 'This model is already selected.');
      return;
    }

    await _turnConfigStore.setConfig(widget.host, session.id, nextConfig);
    if (!mounted || _disposed) return;
    showAppSnackBar(context, 'Model will change on the next reply.');
  }

  Future<void> _showComposerThinkingPicker(SessionSummary session) async {
    await _turnConfigStore.ensureLoaded();
    if (!mounted || _disposed) return;

    final capabilities = await _loadComposerCapabilities(session);
    if (!mounted || _disposed) return;
    if (capabilities != null &&
        (!capabilities.supports('configuration', 'models') ||
            !capabilities.supports('runtimeControls', 'model') ||
            !capabilities.supports('runtimeControls', 'reasoningEffort'))) {
      showAppSnackBar(
        context,
        'This agent does not offer thinking choices here.',
      );
      return;
    }

    final models = await _fetchComposerModels(session);
    if (!mounted || _disposed) return;
    if (models == null) return;
    if (models.isEmpty) {
      showAppSnackBar(
        context,
        'No models are available from this host right now.',
      );
      return;
    }

    final turnConfig = _composerTurnConfig(session);
    final defaultModel = models.firstWhere(
      (model) => model.isDefault,
      orElse: () => models.first,
    );
    final currentModel =
        _cleanComposerLabel(turnConfig.model) ??
        _cleanComposerLabel(session.runtime?.model) ??
        defaultModel.model;
    final selectedModel = models.firstWhere(
      (model) => model.model == currentModel,
      orElse: () => defaultModel,
    );
    if (selectedModel.isAutoModel) {
      showAppSnackBar(
        context,
        'This model manages thinking automatically.',
      );
      return;
    }
    final options = selectedModel.supportedReasoningEfforts;
    if (options.isEmpty) {
      showAppSnackBar(
        context,
        'This model does not expose adjustable thinking effort.',
      );
      return;
    }

    final supportedReasoning = options
        .map((option) => option.reasoningEffort)
        .toSet();
    final rawCurrentReasoning =
        _cleanComposerLabel(turnConfig.reasoningEffort) ??
        _cleanComposerLabel(session.runtime?.reasoningEffort) ??
        selectedModel.defaultReasoningEffort;
    final currentReasoning = supportedReasoning.contains(rawCurrentReasoning)
        ? rawCurrentReasoning
        : selectedModel.defaultReasoningEffort;
    final selected = await _showDesktopOverlayWithComposerFocusRestore(
      () => _showComposerThinkingPickerSurface(
        options: options,
        currentReasoning: currentReasoning,
        defaultReasoning: selectedModel.defaultReasoningEffort,
        modelLabel: selectedModel.displayName,
      ),
    );
    if (!mounted || _disposed || selected == null) return;

    final runtimeModel = _cleanComposerLabel(session.runtime?.model);
    final runtimeReasoning = _cleanComposerLabel(
      session.runtime?.reasoningEffort,
    );
    final inheritsCurrentModel =
        _cleanComposerLabel(turnConfig.model) == null ||
        _cleanComposerLabel(turnConfig.model) == runtimeModel;
    String? nextReasoning = selected;
    if (inheritsCurrentModel &&
        runtimeReasoning != null &&
        selected == runtimeReasoning) {
      nextReasoning = null;
    } else if (inheritsCurrentModel &&
        runtimeReasoning == null &&
        selected == selectedModel.defaultReasoningEffort) {
      nextReasoning = null;
    }
    final nextConfig = turnConfig.copyWith(reasoningEffort: nextReasoning);
    if (_sameTurnConfig(nextConfig, turnConfig)) {
      showAppSnackBar(context, 'This thinking level is already selected.');
      return;
    }

    await _turnConfigStore.setConfig(widget.host, session.id, nextConfig);
    if (!mounted || _disposed) return;
    showAppSnackBar(context, 'Thinking level will change on the next reply.');
  }

  Future<ModelCatalogEntry?> _showComposerModelPickerSurface({
    required List<ModelCatalogEntry> models,
    required String currentModel,
    required String? providerName,
  }) {
    final picker = _ModelPickerSheet(
      models: models,
      currentModel: currentModel,
      providerName: providerName,
    );
    if (widget.desktopMode) {
      return showDialog<ModelCatalogEntry>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 48,
            vertical: 48,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
            child: picker,
          ),
        ),
      );
    }
    return showModalBottomSheet<ModelCatalogEntry>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => picker,
    );
  }

  Future<String?> _showComposerThinkingPickerSurface({
    required List<ModelReasoningEffortOption> options,
    required String currentReasoning,
    required String defaultReasoning,
    required String modelLabel,
  }) {
    final picker = _ReasoningPickerSheet(
      options: options,
      currentReasoning: currentReasoning,
      defaultReasoning: defaultReasoning,
      modelLabel: modelLabel,
    );
    if (widget.desktopMode) {
      return showDialog<String>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 48,
            vertical: 48,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
            child: picker,
          ),
        ),
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => picker,
    );
  }

  SessionTurnConfig _composerConfigForSelectedModel({
    required SessionSummary session,
    required SessionTurnConfig current,
    required ModelCatalogEntry selected,
    required ProviderCapabilities? capabilities,
  }) {
    final supportsReasoning =
        capabilities?.supports('runtimeControls', 'reasoningEffort') ?? true;
    final supportsFastMode =
        capabilities?.supports('runtimeControls', 'fastMode') ?? true;
    final runtimeModel = _cleanComposerLabel(session.runtime?.model);
    final runtimeReasoning = _cleanComposerLabel(
      session.runtime?.reasoningEffort,
    );
    final runtimeFast = session.runtime?.serviceTier == 'fast';
    final supportedReasoning = selected.supportedReasoningEfforts
        .map((option) => option.reasoningEffort)
        .toSet();

    final inheritsDefaultModel = runtimeModel == null && selected.isDefault;
    final nextModel = runtimeModel == selected.model || inheritsDefaultModel
        ? null
        : selected.model;
    var nextReasoning = _cleanComposerLabel(current.reasoningEffort);
    final effectiveReasoning = nextReasoning ?? runtimeReasoning;
    if (!supportsReasoning || selected.isAutoModel) {
      nextReasoning = null;
    } else if (effectiveReasoning != null &&
        supportedReasoning.contains(effectiveReasoning)) {
      nextReasoning = effectiveReasoning;
    } else {
      nextReasoning = selected.defaultReasoningEffort;
    }

    var nextFast = current.fastMode;
    if (!supportsFastMode) {
      nextFast = null;
    } else if (!selected.supportsFastMode &&
        (current.fastMode ?? runtimeFast)) {
      nextFast = false;
    }

    if (nextModel == null &&
        runtimeReasoning != null &&
        nextReasoning == runtimeReasoning) {
      nextReasoning = null;
    }
    if (nextModel == null &&
        runtimeReasoning == null &&
        current.reasoningEffort == null) {
      nextReasoning = null;
    }
    if (nextModel == null && nextFast != null && nextFast == runtimeFast) {
      nextFast = null;
    }

    return SessionTurnConfig(
      model: nextModel,
      mode: current.mode,
      reasoningEffort: nextReasoning,
      fastMode: nextFast,
    );
  }

  Future<void> _showSessionPolicySheet(SessionSummary session) async {
    await _policyStore.ensureLoaded();
    await _turnConfigStore.ensureLoaded();
    if (!mounted) return;
    final runtime = session.runtime;
    final isDesktop = widget.desktopMode;
    final sheet = SessionControlsSheet(
      api: widget.api,
      host: widget.host,
      session: session,
      useBottomSheetChrome: !isDesktop,
      runtimeModel: runtime?.model,
      runtimeModelProvider: runtime?.modelProvider,
      runtimeMode: runtime?.mode,
      runtimeServiceTier: runtime?.serviceTier,
      runtimeReasoningEffort: runtime?.reasoningEffort,
      runtimeApproval: ApprovalPolicy.fromWire(runtime?.approvalPolicy),
      runtimeSandbox: SandboxMode.fromWire(runtime?.sandboxMode),
      runtimeNetworkAccess: runtime?.networkAccess,
      policyStore: _policyStore,
      turnConfigStore: _turnConfigStore,
    );
    if (isDesktop) {
      await _showDesktopOverlayWithComposerFocusRestore(
        () => showDialog<void>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.35),
          builder: (dialogContext) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 48,
              vertical: 48,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dialogContext.colors.surfaceElevated,
                  borderRadius: AppShapes.dialog,
                  border: Border.all(color: dialogContext.colors.border),
                  boxShadow: AppShadows.dialog(
                    dialogContext.colors.textPrimary,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: AppShapes.dialog,
                  child: sheet,
                ),
              ),
            ),
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => sheet,
    );
  }

  Future<void> _startSessionFromCurrent() async {
    final session = _session ?? widget.session;
    final created = await showCreateSessionLauncher(
      context,
      host: widget.host,
      api: widget.api,
      initialCwd: session.cwd,
    );
    if (!mounted || created == null) return;

    final openSession = widget.onOpenSession;
    if (openSession != null) {
      openSession(created);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionScreen(
          host: widget.host,
          session: created,
          api: widget.api,
          onOpenSession: widget.onOpenSession,
          onArchived: widget.onArchived,
          topPadding: widget.topPadding,
          desktopMode: widget.desktopMode,
        ),
      ),
    );
  }

  Future<void> _openTerminal({String? cwdOverride}) async {
    if (!_supportsTerminal) {
      showAppSnackBar(context, 'This host does not expose terminals.');
      return;
    }
    final session = _session ?? widget.session;
    final resolvedCwd = (cwdOverride ?? session.cwd).trim();
    final scope = InspectorScope.maybeOf(context);
    if (widget.desktopMode && scope != null) {
      scope.show(
        buildInspectorTerminalSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          api: widget.api,
          session: session,
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalScreen(
          host: widget.host,
          api: widget.api,
          cwd: resolvedCwd.isEmpty ? session.cwd : resolvedCwd,
          sessionId: session.id,
          title: session.title,
        ),
      ),
    );
  }

  List<BrowserPreviewTargetCandidate> get _browserPreviewCandidates {
    return collectBrowserPreviewCandidates(_activities);
  }

  Future<void> _openBrowserPreviewLauncher({bool openInWindow = false}) async {
    if (!_supportsBrowserPreview) {
      showAppSnackBar(context, 'This host does not expose browser previews.');
      return;
    }
    final suggestions = _browserPreviewCandidates;
    if (suggestions.length == 1) {
      await _openBrowserPreviewTarget(
        suggestions.first,
        openInWindow: openInWindow,
      );
      return;
    }
    final selected = await showModalBottomSheet<BrowserPreviewTargetCandidate>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) =>
          _PreviewTargetPickerSheet(suggestions: suggestions),
    );
    if (!mounted || selected == null) {
      return;
    }
    await _openBrowserPreviewTarget(selected, openInWindow: openInWindow);
  }

  Future<void> _openBrowserPreviewTarget(
    BrowserPreviewTargetCandidate candidate, {
    bool openInWindow = false,
  }) async {
    if (!_supportsBrowserPreview) {
      showAppSnackBar(context, 'This host does not expose browser previews.');
      return;
    }
    final session = _session ?? widget.session;
    final viewport = MediaQuery.sizeOf(context);
    try {
      final previews = await widget.api.fetchBrowserPreviews(widget.host);
      final existing = findReusableBrowserPreview(
        previews,
        candidate,
        sessionId: session.id,
        cwd: session.cwd,
      );
      final preview =
          existing ??
          await widget.api.createBrowserPreview(
            widget.host,
            targetPort: candidate.port,
            targetHost: candidate.host,
            scheme: candidate.scheme,
            label: candidate.sourceLabel,
            cwd: candidate.cwd ?? session.cwd,
            sessionId: session.id,
            width: viewport.width.round().clamp(320, 1200),
            height: viewport.height.round().clamp(480, 1400),
            profileMode: 'sidemesh',
          );
      if (!mounted) return;
      if (openInWindow) {
        await _openBrowserPreviewWindow(preview);
      } else {
        await _showDockedBrowserPreview(preview: preview);
        if (!mounted) return;
        showAppSnackBar(
          context,
          'Opened preview for ${candidate.endpointLabel}.',
        );
      }
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not start browser preview: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _openConnections() async {
    if (!_supportsConnections) {
      showAppSnackBar(context, 'This host does not expose browser previews.');
      return;
    }
    final session = _session ?? widget.session;
    final scope = InspectorScope.maybeOf(context);
    if (widget.desktopMode && scope != null) {
      scope.show(
        buildInspectorPortsSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          api: widget.api,
          session: session,
          supportsBrowserPreview: _supportsBrowserPreview,
          supportsPortForwarding: _supportsPortForwarding,
          onBrowserPreviewOpened: (preview) {
            unawaited(_showDockedBrowserPreview(preview: preview));
          },
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PortForwardScreen(
          host: widget.host,
          api: widget.api,
          cwd: session.cwd,
          sessionId: session.id,
          sessionTitle: session.title,
          supportsBrowserPreview: _supportsBrowserPreview,
          supportsPortForwarding: _supportsPortForwarding,
          onBrowserPreviewOpened: (preview) {
            unawaited(_showDockedBrowserPreview(preview: preview));
            Navigator.of(context).maybePop();
          },
        ),
      ),
    );
  }

  Future<void> _showDockedBrowserPreview({
    required HostBrowserPreviewInfo preview,
  }) async {
    if (!mounted || _disposed) return;
    final manager = SidemeshBrowserPreviewWindowManager.instance;
    if (manager.isSupported) {
      final focused = await manager.focusBrowserPreviewWindowIfOpen(
        host: widget.host,
        preview: preview,
      );
      if (!mounted || _disposed || focused) {
        return;
      }
    }
    final scope = InspectorScope.maybeOf(context);
    if (widget.desktopMode && scope != null) {
      _activeInspectorBrowserPreviewId = preview.id;
      scope.show(
        buildInspectorBrowserPreviewSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          api: widget.api,
          preview: preview,
          onOpenInWindow:
              SidemeshBrowserPreviewWindowManager.instance.isSupported
              ? () => unawaited(_openBrowserPreviewWindow(preview))
              : null,
        ),
      );
      return;
    }
    setState(() {
      _activeInspectorBrowserPreviewId = null;
      _dockedBrowserPreview = _DockedBrowserPreview(preview: preview);
    });
  }

  void _detachCurrentBrowserPreviewSurface(HostBrowserPreviewInfo preview) {
    final current = _dockedBrowserPreview;
    if (current?.preview.id == preview.id) {
      setState(() => _dockedBrowserPreview = null);
    }
    final scope = InspectorScope.maybeOf(context);
    final active = scope?.current;
    if (active?.kind == InspectorSurfaceKind.browserPreview &&
        active?.ownerKey == _inspectorOwnerKey() &&
        _activeInspectorBrowserPreviewId == preview.id) {
      _activeInspectorBrowserPreviewId = null;
      scope?.close();
    }
  }

  Future<void> _openBrowserPreviewWindow(HostBrowserPreviewInfo preview) async {
    _detachCurrentBrowserPreviewSurface(preview);
    final opened = await SidemeshBrowserPreviewWindowManager.instance
        .openOrFocusBrowserPreviewWindow(host: widget.host, preview: preview);
    if (!mounted || _disposed) {
      return;
    }
    showAppSnackBar(
      context,
      opened
          ? 'Opened ${preview.label} in a new window.'
          : 'Browser preview windows are only available on the macOS desktop app.',
    );
  }

  void _minimizeDockedBrowserPreview() {
    final current = _dockedBrowserPreview;
    if (current == null) return;
    setState(() {
      _dockedBrowserPreview = current.copyWith(expanded: false);
    });
  }

  void _expandDockedBrowserPreview() {
    final current = _dockedBrowserPreview;
    if (current == null) return;
    setState(() {
      _dockedBrowserPreview = current.copyWith(expanded: true);
    });
  }

  Future<void> _openDockedBrowserFullPage() async {
    final current = _dockedBrowserPreview;
    if (current == null) return;
    setState(() {
      _dockedBrowserPreview = current.copyWith(expanded: false);
    });
    final stopped = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => BrowserPreviewScreen(
          host: widget.host,
          api: widget.api,
          preview: current.preview,
        ),
      ),
    );
    if (!mounted || _disposed) return;
    if (stopped ?? false) {
      setState(() => _dockedBrowserPreview = null);
    }
  }

  void _closeDockedBrowserPreview() {
    if (_dockedBrowserPreview == null) return;
    setState(() => _dockedBrowserPreview = null);
  }

  Future<void> _stopDockedBrowserPreview() async {
    final current = _dockedBrowserPreview;
    if (current == null) return;
    try {
      await widget.api.stopBrowserPreview(widget.host, current.preview.id);
      if (!mounted || _disposed) return;
      setState(() => _dockedBrowserPreview = null);
    } catch (error) {
      if (!mounted || _disposed) return;
      showAppSnackBar(
        context,
        'Could not stop browser preview: ${friendlyError(error)}',
      );
    }
  }

  void _dismissKeyboard() {
    _restoreComposerFocusOnResume = false;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _openWorkspaceFile(String path) {
    if (!_supportsFilesystem) {
      showAppSnackBar(context, 'This host does not expose workspace files.');
      return;
    }
    final session = _session ?? widget.session;
    final scope = InspectorScope.maybeOf(context);
    if (widget.desktopMode && scope != null) {
      scope.show(
        buildInspectorWorkspaceBrowserSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          api: widget.api,
          root: session.cwd,
          agentProvider: session.provider,
          sessionId: session.id,
          selectedPath: path,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileViewerScreen(
          host: widget.host,
          api: widget.api,
          path: path,
          agentProvider: session.provider,
          sessionId: session.id,
        ),
      ),
    );
  }

  void _browseWorkspacePath(String path) {
    if (!_supportsFilesystem) {
      showAppSnackBar(context, 'This host does not expose workspace files.');
      return;
    }
    final session = _session ?? widget.session;
    final scope = InspectorScope.maybeOf(context);
    final browserRoot = _workspaceBrowserRootForPath(path, session.cwd);
    if (widget.desktopMode && scope != null) {
      scope.show(
        buildInspectorWorkspaceBrowserSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          api: widget.api,
          root: session.cwd,
          agentProvider: session.provider,
          sessionId: session.id,
          selectedPath: path,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileBrowserScreen(
          host: widget.host,
          api: widget.api,
          root: browserRoot,
          agentProvider: session.provider,
          sessionId: session.id,
        ),
      ),
    );
  }

  String _workspaceBrowserRootForPath(String path, String sessionCwd) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == sessionCwd) {
      return sessionCwd;
    }
    if (trimmed.endsWith('/')) {
      return trimmed;
    }
    final slash = trimmed.lastIndexOf('/');
    if (slash <= 0) {
      return sessionCwd;
    }
    return trimmed.substring(0, slash);
  }

  bool _hasPersistedLiveAssistant(Iterable<SessionMessage> messages) {
    final liveAssistant = _liveAssistantMessage;
    if (liveAssistant == null) {
      return false;
    }
    return messages.any(
      (message) => _matchesPersistedMessage(message, liveAssistant.toMessage()),
    );
  }

  _LiveAssistantMessageState _appendLiveAssistantDelta(
    _LiveAssistantMessageState? current,
    String delta,
  ) {
    if (current == null) {
      return _LiveAssistantMessageState(
        id: 'local-stream-${DateTime.now().microsecondsSinceEpoch}',
        text: delta,
        createdAt: DateTime.now(),
        seq: _nextTimelineSeq(),
        phase: 'commentary',
      );
    }
    return current.copyWith(text: '${current.text}$delta');
  }

  _LiveAssistantMessageState _appendLiveAssistantReasoning(
    _LiveAssistantMessageState? current,
    String delta,
  ) {
    if (current == null) {
      return _LiveAssistantMessageState(
        id: 'local-stream-${DateTime.now().microsecondsSinceEpoch}',
        text: '',
        createdAt: DateTime.now(),
        seq: _nextTimelineSeq(),
        phase: 'commentary',
        reasoning: delta,
      );
    }
    return current.copyWith(reasoning: '${current.reasoning}$delta');
  }

  int _nextTimelineSeq() {
    var maxSeq = 0;
    for (final m in _messages) {
      if (m.seq > maxSeq) maxSeq = m.seq;
    }
    for (final m in _optimisticMessages) {
      if (m.seq > maxSeq) maxSeq = m.seq;
    }
    for (final a in _activities) {
      if (a.seq > maxSeq) maxSeq = a.seq;
    }
    final liveAssistant = _liveAssistantMessage;
    if (liveAssistant != null && liveAssistant.seq > maxSeq) {
      maxSeq = liveAssistant.seq;
    }
    for (final event in _timelineLiveEvents) {
      if (event.seq > maxSeq) maxSeq = event.seq;
    }
    return maxSeq + 1;
  }

  // With reverse:true, the bottom of the chat is offset 0 — instant & always
  // correct, no frame-wait dance needed. Only snaps if user is already near
  // the bottom so we don't steal their scroll position while they're reading.
  void _scrollToBottomFast({bool force = false}) {
    if (!_scrollController.hasClients) return;
    if (_scrollController.offset <= 0.5) return;
    if (!force && _scrollController.offset > 160) return;
    _scrollController.jumpTo(0);
  }

  Future<void> _scrollToBottom() async {
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scrollController.hasClients) return;
    if (_scrollController.offset > 0.5) {
      _scrollController.jumpTo(0);
    }
  }

  void _upsertOptimisticMessage(SessionMessage message) {
    final existingIndex = _optimisticMessages.indexWhere(
      (item) => item.id == message.id,
    );
    if (existingIndex == -1) {
      _optimisticMessages = [..._optimisticMessages, message];
      return;
    }
    final updated = [..._optimisticMessages];
    updated[existingIndex] = message;
    _optimisticMessages = updated;
  }

  List<SessionMessage> _reconcileOptimisticMessages(
    List<SessionMessage> persistedMessages,
  ) {
    return _optimisticMessages.where((optimistic) {
      return !persistedMessages.any(
        (persisted) => _matchesPersistedMessage(persisted, optimistic),
      );
    }).toList();
  }

  void _upsertActivity(SessionActivity activity) {
    _activities = _mergeIncomingActivities(
      _activities,
      [activity],
      mode: _ActivityMergeMode.incremental,
    );
  }

  List<SessionActivity> _sortActivities(List<SessionActivity> activities) {
    final sorted = [...activities];
    sorted.sort((left, right) {
      final byCreatedAt = left.createdAt.compareTo(right.createdAt);
      if (byCreatedAt != 0) return byCreatedAt;
      return left.seq.compareTo(right.seq);
    });
    return sorted;
  }

  List<SessionActivity> _mergeIncomingActivities(
    List<SessionActivity> current,
    Iterable<SessionActivity> incoming, {
    required _ActivityMergeMode mode,
  }) {
    final currentById = <String, SessionActivity>{
      for (final activity in current) activity.id: activity,
    };
    final byId = mode == _ActivityMergeMode.incremental
        ? <String, SessionActivity>{...currentById}
        : <String, SessionActivity>{};

    for (final activity in incoming) {
      byId[activity.id] = _chooseActivityMergeWinner(
        existing: currentById[activity.id],
        incoming: activity,
      );
    }

    if (mode == _ActivityMergeMode.snapshot) {
      for (final activity in current) {
        if (!_isCommandLikeActivity(activity)) {
          continue;
        }
        final snapshotActivity = byId[activity.id];
        if (snapshotActivity != null &&
            _hasReadableCommandActivity(snapshotActivity)) {
          continue;
        }
        byId[activity.id] = activity;
      }
    }

    return _sortActivities(byId.values.toList());
  }

  SessionActivity _chooseActivityMergeWinner({
    required SessionActivity? existing,
    required SessionActivity incoming,
  }) {
    if (existing != null &&
        _hasReadableCommandActivity(existing) &&
        !_hasReadableCommandActivity(incoming)) {
      return existing;
    }
    return incoming;
  }

  bool _isCommandLikeActivity(SessionActivity activity) {
    if (activity.isCommand) {
      return true;
    }
    if (!activity.isTool) {
      return false;
    }
    if (activity.toolCategory == 'command') {
      return true;
    }
    for (final target in activity.toolSemanticTargets) {
      if (target.type == 'command' &&
          ((target.command ?? target.value) ?? '').trim().isNotEmpty) {
        return true;
      }
    }
    return _toolArgsContainCommand(activity.toolArgs);
  }

  bool _hasReadableCommandActivity(SessionActivity activity) {
    if (!_isCommandLikeActivity(activity)) {
      return false;
    }
    if ((activity.command ?? '').trim().isNotEmpty) {
      return true;
    }
    for (final target in activity.toolSemanticTargets) {
      if (target.type == 'command' &&
          ((target.command ?? target.value) ?? '').trim().isNotEmpty) {
        return true;
      }
    }
    return _toolArgsContainCommand(activity.toolArgs);
  }

  bool _toolArgsContainCommand(Object? value) {
    if (value is! Map) {
      return false;
    }
    for (final key in const ['command', 'cmd', 'fullCommandText']) {
      final raw = value[key];
      if (raw is String && raw.trim().isNotEmpty) {
        return true;
      }
    }
    return value.values.any(_toolArgsContainCommand);
  }

  List<_TimelineEntry> _buildTimelineEntries() {
    final liveAssistant = _liveAssistantMessage;
    // Memoize: if message/activity/optimistic list identities are unchanged,
    // reuse the previous entries (skip the sort).
    if (identical(_entriesMessagesRef, _messages) &&
        identical(_entriesOptimisticRef, _optimisticMessages) &&
        identical(_entriesActivitiesRef, _activities) &&
        identical(_entriesTimelineEventsRef, _timelineLiveEvents) &&
        _entriesLiveAssistantId == liveAssistant?.id) {
      return _cachedEntries;
    }

    final messages = _messages.where((m) => m.isRenderable);
    final optimistic = _optimisticMessages.where((m) => m.isRenderable);
    final visibleActivities = _groupFileChangeActivities(_activities);
    final entries =
        <_TimelineEntry>[
          ...messages.map(_TimelineEntry.message),
          ...optimistic.map(_TimelineEntry.message),
          ...visibleActivities.map(_TimelineEntry.activity),
          ..._timelineLiveEvents.map(_TimelineEntry.runtimeEvent),
          if (liveAssistant != null)
            _TimelineEntry.liveAssistant(liveAssistant),
        ]..sort((left, right) {
          final byCreatedAt = left.createdAt.compareTo(right.createdAt);
          if (byCreatedAt != 0) return byCreatedAt;
          return left.seq.compareTo(right.seq);
        });

    _entriesMessagesRef = _messages;
    _entriesOptimisticRef = _optimisticMessages;
    _entriesActivitiesRef = _activities;
    _entriesTimelineEventsRef = _timelineLiveEvents;
    _entriesLiveAssistantId = liveAssistant?.id;
    _cachedEntries = entries;
    // Notify pane-3 surfaces (search) that records should be rebuilt.
    // Scheduled post-frame so we don't call notifyListeners during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _timelineRevision.value++;
    });
    return entries;
  }

  List<SessionActivity> _groupFileChangeActivities(
    List<SessionActivity> activities,
  ) {
    final grouped = <SessionActivity>[];
    var index = 0;
    while (index < activities.length) {
      final current = activities[index];
      final key = _fileChangeGroupKey(current);
      if (key == null) {
        grouped.add(current);
        index += 1;
        continue;
      }

      final bucket = <SessionActivity>[current];
      var nextIndex = index + 1;
      while (nextIndex < activities.length &&
          _fileChangeGroupKey(activities[nextIndex]) == key) {
        bucket.add(activities[nextIndex]);
        nextIndex += 1;
      }
      grouped.add(_aggregateFileChangeActivities(bucket));
      index = nextIndex;
    }
    return grouped;
  }

  String? _fileChangeGroupKey(SessionActivity activity) {
    if (!activity.isFileChange) return null;
    final turnId = (activity.turnId ?? '').trim();
    if (turnId.isEmpty) return null;
    return turnId;
  }

  SessionActivity _aggregateFileChangeActivities(
    List<SessionActivity> activities,
  ) {
    if (activities.length == 1) return activities.first;
    final first = activities.first;
    final changes = _aggregateFileChangeChanges(activities);
    return SessionActivity(
      id:
          'file-change-group:${first.turnId ?? first.id}:${activities.length}:${activities.last.id}',
      type: first.type,
      createdAt: first.createdAt,
      seq: first.seq,
      status: _aggregateFileChangeStatus(activities),
      turnId: first.turnId,
      command: first.command,
      cwd: first.cwd,
      output: first.output,
      exitCode: first.exitCode,
      durationMs: first.durationMs,
      source: first.source,
      processId: first.processId,
      commandActions: first.commandActions,
      terminalStatus: first.terminalStatus,
      terminalInput: first.terminalInput,
      toolName: first.toolName,
      toolTitle: first.toolTitle,
      toolArgs: first.toolArgs,
      toolResult: first.toolResult,
      toolError: first.toolError,
      toolSemantic: first.toolSemantic,
      changes: changes,
      diff: first.diff,
      query: first.query,
      queries: first.queries,
      targetUrl: first.targetUrl,
      pattern: first.pattern,
      revisedPrompt: first.revisedPrompt,
      savedPath: first.savedPath,
    );
  }

  List<SessionActivityChange> _aggregateFileChangeChanges(
    List<SessionActivity> activities,
  ) {
    final byPath = <String, SessionActivityChange>{};
    for (final activity in activities) {
      for (final change in activity.changes) {
        final key = change.path.trim();
        if (key.isEmpty) continue;
        byPath[key] = change;
      }
    }
    return byPath.values.toList(growable: false);
  }

  String _aggregateFileChangeStatus(List<SessionActivity> activities) {
    const terminal = {'completed', 'failed', 'declined'};
    if (activities.any((activity) => !terminal.contains(activity.status))) {
      return 'running';
    }
    if (activities.any((activity) => activity.status == 'failed')) {
      return 'failed';
    }
    if (activities.any((activity) => activity.status == 'declined')) {
      return 'declined';
    }
    return 'completed';
  }

  List<SearchRecord> _buildSearchRecords() {
    final entries = _buildTimelineEntries();
    final records = <SearchRecord>[];
    final session = _session ?? widget.session;
    for (final entry in entries) {
      if (entry.kind == _TimelineEntryKind.liveAssistant ||
          entry.kind == _TimelineEntryKind.providerWarning ||
          entry.kind == _TimelineEntryKind.planUpdated) {
        continue;
      }
      if (entry.kind == _TimelineEntryKind.message) {
        final message = entry.message!;
        records.add(
          SearchRecord(
            id: entry.keyId,
            kind: SearchRecordKind.message,
            createdAt: entry.createdAt,
            haystack: _messageSearchHaystack(message),
            title: _messageSearchTitle(message),
            message: message,
          ),
        );
      } else if (entry.kind == _TimelineEntryKind.activity) {
        final activity = entry.activity!;
        records.add(
          SearchRecord(
            id: entry.keyId,
            kind: SearchRecordKind.activity,
            createdAt: entry.createdAt,
            haystack: _activitySearchHaystack(activity),
            title: _activitySearchTitle(activity),
            activity: activity,
            sessionCwd: session.cwd,
          ),
        );
      }
    }
    return records;
  }

  String _messageSearchHaystack(SessionMessage message) {
    return [
      message.role,
      message.phase ?? '',
      message.text,
      for (final attachment in message.attachments) ...[
        attachment.type,
        attachment.url ?? '',
        attachment.path ?? '',
      ],
    ].join('\n').toLowerCase();
  }

  String _messageSearchTitle(SessionMessage message) {
    final role = message.role == 'user' ? 'You' : 'Assistant';
    final phase = (message.phase ?? '').trim();
    if (phase.isEmpty || phase == 'answer') return role;
    return '$role · ${phase.toUpperCase()}';
  }

  String _activitySearchHaystack(SessionActivity activity) {
    final output = activity.output ?? '';
    final tail = output.length > 800
        ? output.substring(output.length - 800)
        : output;
    final changesText = activity.changes
        .expand((c) => [c.path, c.movePath ?? ''])
        .join('\n');
    return [
      activity.type,
      activity.status,
      activity.command ?? '',
      activity.toolName ?? '',
      activity.toolTitle ?? '',
      activity.toolCategory ?? '',
      activity.toolAction ?? '',
      activity.toolTarget ?? '',
      activity.toolTargets.join(' '),
      activity.toolUrl ?? '',
      activity.toolQuery ?? '',
      activity.toolMode ?? '',
      jsonEncode(activity.toolArgs),
      jsonEncode(activity.toolResult),
      activity.cwd ?? '',
      activity.query ?? '',
      activity.queries.join(' '),
      activity.targetUrl ?? '',
      activity.pattern ?? '',
      activity.savedPath ?? '',
      activity.terminalInput ?? '',
      changesText,
      tail,
    ].join('\n').toLowerCase();
  }

  String _activitySearchTitle(SessionActivity activity) {
    switch (activity.type) {
      case 'command':
        final cmd = (activity.command ?? '').trim();
        return cmd.isEmpty ? 'Command' : cmd;
      case 'tool':
        final title = (activity.toolTitle ?? '').trim();
        if (title.isNotEmpty) return title;
        final name = (activity.toolName ?? '').trim();
        return name.isEmpty ? 'Tool execution' : name;
      case 'file_change':
        final fileCount = _fileChangeFileCount(activity.changes);
        if (fileCount == 1 && activity.changes.isNotEmpty) {
          return activity.changes.first.path;
        }
        return 'Edited $fileCount files';
      case 'turn_diff':
        return 'Turn diff';
      case 'web_search':
        final q = (activity.query ?? '').trim();
        return q.isEmpty ? 'Web search' : 'Web: $q';
      case 'image_generation':
        return 'Generated image';
      default:
        return activity.type;
    }
  }

  bool _matchesPersistedMessage(
    SessionMessage persisted,
    SessionMessage optimistic,
  ) {
    final sameBody =
        persisted.role == optimistic.role &&
        persisted.text.trim() == optimistic.text.trim() &&
        _sameMessageAttachments(persisted.attachments, optimistic.attachments);
    if (!sameBody) {
      return false;
    }
    if (persisted.id == optimistic.id ||
        _completedPendingSendIds.contains(optimistic.id)) {
      return true;
    }
    return (persisted.createdAt.difference(optimistic.createdAt).inSeconds)
            .abs() <=
        90;
  }

  bool _matchesPersistedPendingSend(
    SessionMessage persisted,
    PendingSessionSend pending,
  ) {
    if (persisted.role != 'user' ||
        persisted.text.trim() != pending.message.text.trim() ||
        !_sameMessageAttachments(
          persisted.attachments,
          pending.message.attachments,
        )) {
      return false;
    }
    // Rollout history does not preserve clientMessageId, so use the pending
    // send timestamps as a narrow window for stale outbox cleanup. This avoids
    // treating an intentional same-text message much later as the pending send.
    final lowerBound = pending.createdAt.subtract(const Duration(seconds: 90));
    final latestKnownAttempt = [
      pending.createdAt,
      pending.updatedAt,
      pending.nextAttemptAt,
    ].reduce((left, right) => left.isAfter(right) ? left : right);
    final upperBound = latestKnownAttempt.add(const Duration(minutes: 10));
    return !persisted.createdAt.isBefore(lowerBound) &&
        !persisted.createdAt.isAfter(upperBound);
  }

  bool _sameMessageAttachments(
    List<SessionMessageAttachment> left,
    List<SessionMessageAttachment> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftItem = left[index];
      final rightItem = right[index];
      if (leftItem.type != rightItem.type ||
          leftItem.url != rightItem.url ||
          leftItem.path != rightItem.path) {
        return false;
      }
    }
    return true;
  }

  Future<void> _openSessionInWindow() async {
    final session = _session ?? widget.session;
    final opened = await SidemeshSessionWindowManager.instance
        .openOrFocusSessionWindow(host: widget.host, session: session);
    if (!mounted) {
      return;
    }
    showAppSnackBar(
      context,
      opened
          ? 'Opened ${session.title} in a new window.'
          : 'Session pop-out windows are only available on the macOS desktop app.',
    );
  }

  void _handleSessionAction(String value, SessionSummary session) {
    switch (value) {
      case 'stop':
        unawaited(_stopSession());
      case 'restart_provider':
        unawaited(_restartProvider());
      case 'reload':
        _reloadSnapshot();
        break;
      case 'controls':
        _showSessionPolicySheet(session);
        break;
      case 'new':
        _startSessionFromCurrent();
        break;
      case 'terminal':
        if (_supportsTerminal) {
          unawaited(_openTerminal());
        }
        break;
      case 'preview':
        if (_supportsBrowserPreview) {
          unawaited(_openBrowserPreviewLauncher());
        }
        break;
      case 'preview_window':
        if (_supportsBrowserPreview) {
          unawaited(_openBrowserPreviewLauncher(openInWindow: true));
        }
        break;
      case 'connections':
        if (_supportsConnections) {
          unawaited(_openConnections());
        }
        break;
      case 'search':
        _toggleSearchPanel();
        break;
      case 'resources':
        if (_supportsSessionResources) {
          _openResourcesPanel();
        }
        break;
      case 'favorite':
        _toggleFavorite();
        break;
      case 'unread':
        unawaited(_markSessionUnread());
        break;
      case 'git':
        _showGitSheet(session);
        break;
      case 'compact':
        unawaited(_compactSession());
        break;
      case 'browse':
        if (_supportsFilesystem) {
          _browseWorkspacePath(session.cwd);
        }
        break;
      case 'popout':
        unawaited(_openSessionInWindow());
        break;
      case 'rename':
        _renameSession();
        break;
      case 'archive':
        _archiveSession();
        break;
    }
  }

  List<_SessionActionGroup> _sessionActionGroups({
    required bool favorite,
    required bool gitAvailable,
    required bool gitDirty,
    required bool terminalOpen,
    required bool portsOpen,
    required bool searchOpen,
    required bool resourcesOpen,
    bool includeStop = true,
    bool includeNew = true,
    bool includeControls = false,
    bool controlsCustomized = false,
  }) {
    return [
      // When the agent is running, surface the stop action at the top so
      // it's immediately reachable without scrolling the sheet.
      if (includeStop && _running && _supportsSessionInterrupt)
        const _SessionActionGroup(
          label: 'LIVE',
          actions: [
            _SessionActionSpec(
              value: 'stop',
              label: 'Stop agent',
              detail: 'Stop the current task immediately.',
              icon: Icons.stop_circle_rounded,
              tone: _SessionActionTone.danger,
            ),
          ],
        ),
      _SessionActionGroup(
        label: 'Workspace',
        actions: [
          if (_supportsTerminal)
            _SessionActionSpec(
              value: 'terminal',
              label: terminalOpen ? 'Terminal is open' : 'Open terminal',
              detail: terminalOpen
                  ? 'Jump back to the active terminal surface.'
                  : 'Open a shell for this workspace.',
              icon: Icons.terminal_rounded,
              tone: terminalOpen
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
              active: terminalOpen,
            ),
          if (_supportsFilesystem)
            const _SessionActionSpec(
              value: 'browse',
              label: 'Browse files',
              detail: 'Open the workspace file browser.',
              icon: Icons.folder_rounded,
            ),
          if (_supportsSessionResources)
            _SessionActionSpec(
              value: 'resources',
              label: resourcesOpen ? 'Resources are open' : 'Open resources',
              detail: 'View generated images and session assets.',
              icon: Icons.perm_media_rounded,
              tone: resourcesOpen
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
              active: resourcesOpen,
            ),
        ],
      ),
      _SessionActionGroup(
        label: 'Browser preview',
        actions: [
          if (_supportsBrowserPreview)
            const _SessionActionSpec(
              value: 'preview',
              label: 'Open browser preview',
              detail: 'Open a streamed browser preview for a localhost app.',
              icon: Icons.open_in_browser_rounded,
              tone: _SessionActionTone.accent,
            ),
          if (_supportsBrowserPreview &&
              SidemeshBrowserPreviewWindowManager.instance.isSupported)
            const _SessionActionSpec(
              value: 'preview_window',
              label: 'Open preview in new window',
              detail: 'Detach a browser preview into its own macOS window.',
              icon: Icons.open_in_new_rounded,
            ),
          if (_supportsConnections)
            _SessionActionSpec(
              value: 'connections',
              label: portsOpen
                  ? 'Browser previews are open'
                  : 'Manage browser previews',
              detail: 'Inspect active browser previews for this session.',
              icon: Icons.open_in_browser_rounded,
              tone: portsOpen
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
              active: portsOpen,
            ),
        ],
      ),
      _SessionActionGroup(
        label: 'Transcript',
        actions: [
          _SessionActionSpec(
            value: 'search',
            label: searchOpen ? 'Close search' : 'Search transcript',
            detail: searchOpen
                ? 'Hide the current search panel.'
                : 'Find text in loaded messages.',
            icon: searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
            tone: searchOpen
                ? _SessionActionTone.accent
                : _SessionActionTone.neutral,
            active: searchOpen,
          ),
          if (gitAvailable)
            _SessionActionSpec(
              value: 'git',
              label: 'Git details',
              detail: gitDirty
                  ? 'Working tree has changes.'
                  : 'Branch, upstream, and diff shortcuts.',
              icon: Icons.account_tree_rounded,
              tone: gitDirty
                  ? _SessionActionTone.warning
                  : _SessionActionTone.neutral,
              active: gitDirty,
            ),
        ],
      ),
      _SessionActionGroup(
        label: 'Session',
        actions: [
          if (includeNew)
            const _SessionActionSpec(
              value: 'new',
              label: 'New session',
              detail: 'Start beside this working directory.',
              icon: Icons.add_circle_outline_rounded,
            ),
          const _SessionActionSpec(
            value: 'reload',
            label: 'Reload',
            detail: 'Refresh this transcript from the host.',
            icon: Icons.refresh_rounded,
          ),
          if (includeControls)
            _SessionActionSpec(
              value: 'controls',
              label: controlsCustomized
                  ? 'Session controls changed'
                  : 'Session controls',
              detail: 'Model, thinking, permissions, and access.',
              icon: Icons.tune_rounded,
              tone: controlsCustomized
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
              active: controlsCustomized,
            ),
          _SessionActionSpec(
            value: 'favorite',
            label: favorite ? 'Remove favorite' : 'Add favorite',
            detail: favorite
                ? 'Take this session out of your shortcuts.'
                : 'Keep this session easy to find.',
            icon: favorite ? Icons.star_rounded : Icons.star_outline_rounded,
            tone: favorite
                ? _SessionActionTone.warning
                : _SessionActionTone.neutral,
            active: favorite,
          ),
          const _SessionActionSpec(
            value: 'unread',
            label: 'Flag for follow-up',
            detail: 'Adds a blue dot to this session in your recents list.',
            icon: Icons.flag_rounded,
          ),
          if (_supportsSessionCompact)
            const _SessionActionSpec(
              value: 'compact',
              label: 'Compact context',
              detail: 'Summarize older context to keep the session lighter.',
              icon: Icons.compress_rounded,
            ),
          if (widget.topPadding != null &&
              SidemeshSessionWindowManager.instance.isSupported)
            const _SessionActionSpec(
              value: 'popout',
              label: 'Open in new window',
              detail: 'Detach this session into its own macOS window.',
              icon: Icons.open_in_new_rounded,
            ),
        ],
      ),
      if (_supportsProviderRestart ||
          _supportsSessionRename ||
          _supportsSessionArchive)
        _SessionActionGroup(
          label: 'Manage',
          actions: [
            if (_supportsProviderRestart)
              const _SessionActionSpec(
                value: 'restart_provider',
                label: 'Restart agent',
                detail: 'Restart the active agent on this host.',
                icon: Icons.restart_alt_rounded,
                tone: _SessionActionTone.warning,
              ),
            if (_supportsSessionRename)
              const _SessionActionSpec(
                value: 'rename',
                label: 'Rename',
                detail: 'Change the session title.',
                icon: Icons.drive_file_rename_outline,
              ),
            if (_supportsSessionArchive)
              const _SessionActionSpec(
                value: 'archive',
                label: 'Archive',
                detail: 'Move this session out of recents.',
                icon: Icons.archive_rounded,
                tone: _SessionActionTone.danger,
              ),
          ],
        ),
    ];
  }

  Future<void> _showSessionActionsSheet({
    required SessionSummary session,
    required bool favorite,
    required bool gitAvailable,
    required bool gitDirty,
    required bool terminalOpen,
    required bool portsOpen,
    required bool searchOpen,
    required bool resourcesOpen,
    BuildContext? anchorContext,
    bool includeStop = true,
    bool includeNew = true,
    bool includeControls = false,
    bool controlsCustomized = false,
  }) async {
    final groups = _sessionActionGroups(
      favorite: favorite,
      gitAvailable: gitAvailable,
      gitDirty: gitDirty,
      terminalOpen: terminalOpen,
      portsOpen: portsOpen,
      searchOpen: searchOpen,
      resourcesOpen: resourcesOpen,
      includeStop: includeStop,
      includeNew: includeNew,
      includeControls: includeControls,
      controlsCustomized: controlsCustomized,
    );
    final String? selected;
    final restoreComposerFocus = _shouldRestoreComposerFocusAfterDesktopOverlay();
    if (widget.desktopMode) {
      final anchorRect = _desktopPopoverAnchorRect(anchorContext);
      selected = await showDialog<String>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.32),
        useSafeArea: false,
        builder: (dialogContext) {
          final size = MediaQuery.sizeOf(dialogContext);
          final padding = MediaQuery.paddingOf(dialogContext);
          final availableHeight = math.max(
            240.0,
            size.height - padding.top - 24,
          );
          final maxHeight = math.min(660.0, availableHeight);
          final anchor = anchorRect;
          final topLimit = math.max(
            padding.top + 12.0,
            size.height - maxHeight - 12,
          );
          final top = anchor == null
              ? padding.top + 12
              : math.min(anchor.bottom + 8, topLimit);
          final right = anchor == null
              ? 16.0
              : math.max(12.0, size.width - anchor.right);
          return Stack(
            children: [
              Positioned(
                top: top,
                right: right,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 520,
                    maxHeight: maxHeight,
                  ),
                  child: _SessionActionSheet(
                    session: session,
                    groups: groups,
                    desktop: true,
                  ),
                ),
              ),
            ],
          );
        },
      );
    } else {
      selected = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.28),
        showDragHandle: false,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => _SessionActionSheet(
          session: session,
          groups: groups,
        ),
      );
    }
    if (!mounted || selected == null) {
      _restoreComposerFocusAfterDesktopOverlay(restoreComposerFocus);
      return;
    }
    _handleSessionAction(selected, session);
    if (_sessionActionReturnsToComposer(selected)) {
      _restoreComposerFocusAfterDesktopOverlay(restoreComposerFocus);
    }
  }

  bool _sessionActionReturnsToComposer(String value) {
    return switch (value) {
      'reload' || 'restart_provider' || 'favorite' || 'unread' => true,
      _ => false,
    };
  }

  Rect? _desktopPopoverAnchorRect(BuildContext? anchorContext) {
    final anchorObject = anchorContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context);
    final overlayObject = overlay?.context.findRenderObject();
    if (anchorObject is! RenderBox ||
        overlayObject is! RenderBox ||
        !anchorObject.attached ||
        !overlayObject.attached) {
      return null;
    }
    final topLeft = anchorObject.localToGlobal(
      Offset.zero,
      ancestor: overlayObject,
    );
    return topLeft & anchorObject.size;
  }

  @override
  Widget build(BuildContext context) {
    final session = _session ?? widget.session;
    final colors = context.colors;
    final timelineEntries = _buildTimelineEntries();
    final visibleTimelineEntries = timelineEntries;
    final pinnedMessages = _pinsStore.pinsFor(widget.host, session.id);
    final isCompact = MediaQuery.of(context).size.width < 600;
    final pinnedActive = _isPinnedInspectorOpen(
      InspectorScope.maybeOf(context),
    );
    final freshnessMode = _transcriptFreshnessMode;
    final showHistoryBanner =
        (_history?.isTruncated ?? false) && !_historyBannerDismissed;
    final showStopPill = isCompact && _running && _supportsSessionInterrupt;
    final showWaitingState = !_loading && timelineEntries.isEmpty && _running;
    final freshnessTopPadding =
        widget.desktopMode && _pendingAction == null ? 8.0 : 0.0;
    final bodyContent = Column(
      children: [
        if (!isCompact && !widget.desktopMode)
          ListenableBuilder(
            listenable: SessionLocalStore.instance,
            builder: (context, _) {
              final favorite = _localStore.isFavorite(widget.host, session.id);
              return _SessionHeader(
                host: widget.host,
                session: session,
                gitStatus: _gitStatus,
                showGit: _supportsGitStatus,
                running: _running,
                favorite: favorite,
                pinnedCount: pinnedMessages.length,
                pinnedActive: pinnedActive,
                onPinnedTap: _openPinnedPanel,
                onDetails: () => _showSessionDetailsSheet(session),
                onGitDetails: () => _showGitSheet(session),
              );
            },
          ),
        if (_pendingAction != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: _PendingActionCard(
              action: _pendingAction!,
              onRespond: _respondAction,
            ),
          ),
        if (freshnessMode != null)
          Padding(
            padding: EdgeInsets.fromLTRB(16, freshnessTopPadding, 16, 10),
            child: ListenableBuilder(
              listenable: RelativeTimeTicker.seconds,
              builder: (context, _) {
                return _CachedTranscriptStrip(
                  mode: freshnessMode,
                  refreshing:
                      _snapshotRefreshing ||
                      (freshnessMode == _TranscriptFreshnessMode.reconnecting &&
                          _resumeSyncing),
                  lastConnectedLabel: _lastConnectedLabel,
                  onRetry: freshnessMode == _TranscriptFreshnessMode.offline
                      ? _retryFreshnessSync
                      : null,
                );
              },
            ),
          ),
        Expanded(
          child: (_loading && timelineEntries.isEmpty)
              ? const MeshLoader()
              : Stack(
                  children: [
                    if (showWaitingState)
                      Positioned.fill(
                        child: _SessionWaitingState(
                          onStop: _supportsSessionInterrupt
                              ? _stopSession
                              : null,
                        ),
                      )
                    else
                      RefreshIndicator(
                        onRefresh: () => _loadSnapshot(scrollToBottom: false),
                        edgeOffset: 0,
                        displacement: 28,
                        child: SelectionArea(
                          child: ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount:
                                visibleTimelineEntries.length +
                                (showHistoryBanner ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (showHistoryBanner &&
                                  index == visibleTimelineEntries.length) {
                                return Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    0,
                                    10,
                                    0,
                                    6,
                                  ),
                                  child: _HistoryTruncationCard(
                                    history: _history!,
                                    loading: _loadingOlderHistory,
                                    onLoadOlderHistory: _loadOlderTranscript,
                                    onDismiss: () => setState(
                                      () => _historyBannerDismissed = true,
                                    ),
                                  ),
                                );
                              }
                              final chronoIndex =
                                  visibleTimelineEntries.length - index - 1;
                              final entry = visibleTimelineEntries[chronoIndex];
                              final prev = chronoIndex > 0
                                  ? visibleTimelineEntries[chronoIndex - 1]
                                  : null;
                              final showDay =
                                  prev == null ||
                                  !_sameCalendarDay(
                                    prev.createdAt,
                                    entry.createdAt,
                                  );
                              final child = KeyedSubtree(
                                key: ValueKey(entry.keyId),
                                child: switch (entry.kind) {
                                  _TimelineEntryKind.message => _MessageBubble(
                                    host: widget.host,
                                    api: widget.api,
                                    message: entry.message!,
                                    pinned: _pinsStore.isPinned(
                                      widget.host,
                                      session.id,
                                      entry.message!.id,
                                    ),
                                    onTogglePin: () =>
                                        _toggleMessagePin(entry.message!),
                                    onOpenFile: _openWorkspaceFile,
                                  ),
                                  _TimelineEntryKind.activity => _ActivityCard(
                                    host: widget.host,
                                    api: widget.api,
                                    activity: entry.activity!,
                                    sessionCwd: session.cwd,
                                    defaultCollapsed:
                                        entry.activity!.type !=
                                        'image_generation',
                                    onOpenFile: _openWorkspaceFile,
                                    onBrowsePath: _supportsFilesystem
                                        ? _browseWorkspacePath
                                        : null,
                                    onOpenBrowserPreview:
                                        _supportsBrowserPreview
                                        ? (target) => unawaited(
                                            _openBrowserPreviewTarget(target),
                                          )
                                        : null,
                                    onOpenTerminal: _supportsTerminal
                                        ? (cwd) => unawaited(
                                            _openTerminal(cwdOverride: cwd),
                                          )
                                        : null,
                                    opensFilesInInspector:
                                        widget.desktopMode &&
                                        _inspectorController != null,
                                  ),
                                  _TimelineEntryKind.providerWarning =>
                                    _ProviderWarningRow(
                                      event: entry.runtimeEvent!.event,
                                    ),
                                  _TimelineEntryKind.planUpdated =>
                                    _PlanUpdateCard(
                                      event: entry.runtimeEvent!.event,
                                    ),
                                  _TimelineEntryKind.liveAssistant =>
                                    _LiveAssistantBubble(
                                      host: widget.host,
                                      api: widget.api,
                                      message: _liveAssistantNotifier,
                                      onOpenFile: _openWorkspaceFile,
                                    ),
                                },
                              );
                              if (!showDay) return child;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _DaySeparator(
                                    label: _formatDaySeparator(entry.createdAt),
                                  ),
                                  child,
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    if (showStopPill)
                      Positioned(
                        left: 16,
                        bottom: 12,
                        child: _StopAgentPill(onTap: _stopSession),
                      ),
                    Positioned(
                      right: 16,
                      bottom: 12,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _showJumpToLatest,
                        builder: (context, show, _) {
                          return IgnorePointer(
                            ignoring: !show,
                            child: AnimatedOpacity(
                              opacity: show ? 1 : 0,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                              child: _JumpToLatestPill(
                                onTap: () {
                                  if (!_scrollController.hasClients) {
                                    return;
                                  }
                                  _scrollController.animateTo(
                                    0,
                                    duration: const Duration(milliseconds: 240),
                                    curve: Curves.easeOut,
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        if (!widget.desktopMode && _dockedBrowserPreview != null)
          _SessionBrowserPreviewDock(
            host: widget.host,
            api: widget.api,
            dockedPreview: _dockedBrowserPreview!,
            onExpand: _expandDockedBrowserPreview,
            onMinimize: _minimizeDockedBrowserPreview,
            onFullPage: () => unawaited(_openDockedBrowserFullPage()),
            onClose: _closeDockedBrowserPreview,
            onStop: () => unawaited(_stopDockedBrowserPreview()),
            onStopped: (_) => _closeDockedBrowserPreview(),
          ),
        if (_pendingSends.isNotEmpty)
          _PendingSendStrip(
            host: widget.host,
            pending: _pendingSends,
            retrying: _retryingPendingSend,
            onRetryNow: () => unawaited(_retryPendingSends(manual: true)),
            onEditCopy: (pending) =>
                unawaited(_movePendingSendToComposer(pending)),
            onDiscard: (pending) => unawaited(_discardPendingSend(pending)),
          ),
        if (_showRuntimeSignalStrip)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _RuntimeSignalStrip(
              threadStatus: _latestThreadStatus,
              queueUpdated: _latestQueueUpdate,
              autoRetryUpdated: _latestAutoRetryUpdate,
            ),
        ),
        _ComposerStatusStrip(thinking: _thinkingNotifier),
        ListenableBuilder(
          listenable: _turnConfigStore,
          builder: (context, _) {
            final showModelPicker = _supportsComposerModelPicker;
            final showThinkingPicker = _supportsComposerThinkingPicker;
            return _Composer(
              controller: _composerController,
              focusNode: _composerFocusNode,
              isFocused: _composerFocused,
              attachments: _draftAttachments,
              skills: _draftSkillMentions,
              files: _draftFileMentions,
              activeSkillQuery: _activeSkillQuery?.query,
              skillSuggestions: _skillSuggestions,
              loadingSkills: _loadingSkills,
              skillError: _skillsError,
              activeFileQuery: _activeFileQuery?.query,
              fileSuggestions: _fileSuggestions,
              loadingFileSearch: _loadingFileSearch,
              fileError: _fileSearchError,
              sending: _sending,
              supportsImageInput: _supportsImageInput,
              supportsSkillInput: _supportsSkillInput,
              supportsFileMentions: _supportsFileMentions,
              onPickImages: _pickComposerImages,
              onNativePaste: () =>
                  _pasteComposerImage(showEmptyFeedback: false),
              onRemoveAttachment: _removeDraftAttachment,
              onSelectSkill: _insertSkillMention,
              onRemoveSkill: _removeDraftSkillMention,
              onSelectFile: _insertFileMention,
              onRemoveFile: _removeDraftFileMention,
              onSend: _sendInput,
              onDismiss: _dismissKeyboard,
              onAddSkillTrigger: _supportsSkillInput
                  ? _addSkillTriggerToComposer
                  : null,
              onAddFileTrigger: _supportsFileMentions
                  ? _addFileTriggerToComposer
                  : null,
              modelLabel: showModelPicker ? _composerModelLabel(session) : null,
              modelDetail: showModelPicker
                  ? _composerModelDetail(session)
                  : null,
              modelCustomized: showModelPicker
                  ? _composerModelCustomized(session)
                  : false,
              onModelTap: showModelPicker
                  ? () => _showComposerModelPicker(session)
                  : null,
              thinkingLabel: showThinkingPicker
                  ? _composerThinkingLabel(session)
                  : null,
              thinkingDetail: showThinkingPicker
                  ? _composerThinkingDetail(session)
                  : null,
              thinkingCustomized: showThinkingPicker
                  ? _composerThinkingCustomized(session)
                  : false,
              onThinkingTap: showThinkingPicker
                  ? () => _showComposerThinkingPicker(session)
                  : null,
              submitOnEnter: widget.desktopMode,
            );
          },
        ),
      ],
    );
    final layoutBody = bodyContent;
    final inspectorScope = InspectorScope.maybeOf(context);
    final searchOpenInInspector =
        inspectorScope != null && _isSearchInspectorOpen(inspectorScope);
    final resourcesOpenInInspector = _isResourcesInspectorOpen(inspectorScope);
    final terminalOpenInInspector = _isTerminalInspectorOpen(inspectorScope);
    final portsOpenInInspector = _isPortsInspectorOpen(inspectorScope);
    final PreferredSizeWidget? appBarBottom;
    if (widget.desktopMode) {
      appBarBottom = const _DesktopSessionHeaderDivider();
    } else if (isCompact) {
      appBarBottom = PreferredSize(
        preferredSize: const Size.fromHeight(30),
        child: _SessionAppBarSubtitle(
          host: widget.host,
          session: session,
          gitStatus: _gitStatus,
          showGit: _supportsGitStatus,
          running: _running,
          pinnedCount: pinnedMessages.length,
          pinnedActive: pinnedActive,
          onPinnedTap: _openPinnedPanel,
          onDetails: () => _showSessionDetailsSheet(session),
          onGitDetails: () => _showGitSheet(session),
        ),
      );
    } else {
      appBarBottom = null;
    }
    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: widget.desktopMode ? 16 : null,
        toolbarHeight: isCompact ? 52 : (widget.desktopMode ? 60 : null),
        bottom: appBarBottom,
        title: widget.desktopMode
            ? _DesktopSessionTitle(
                session: session,
                running: _running,
                canRename: _supportsSessionRename,
                onRename: () => unawaited(_renameSession()),
              )
            : Row(
                children: [
                  if (_running) ...[
                    const LivePulse(),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: _supportsSessionRename && !isCompact
                        ? GestureDetector(
                            onTap: () => unawaited(_renameSession()),
                            behavior: HitTestBehavior.opaque,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    session.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.edit_rounded,
                                  size: 13,
                                  color: colors.textTertiary,
                                ),
                              ],
                            ),
                          )
                        : Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ],
              ),
        actions: [
          // Reserve a permanent slot for interrupt — this prevents all other
          // action buttons from jumping left/right when the agent starts/stops.
          if (!isCompact && !widget.desktopMode && _supportsSessionInterrupt)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _running ? 1.0 : 0.3,
                child: IgnorePointer(
                  ignoring: !_running,
                  child: MeshIconButton(
                    icon: Icons.stop_circle_rounded,
                    tooltip: 'Stop agent',
                    color: colors.danger,
                    onTap: _stopSession,
                    semanticLabel: 'Stop agent',
                  ),
                ),
              ),
            ),
          if (!isCompact && !widget.desktopMode)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: MeshIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Reload session',
                color: colors.textSecondary,
                onTap: _reloadSnapshot,
              ),
            ),
          if (!isCompact && !widget.desktopMode)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: MeshIconButton(
                icon: Icons.add_circle_outline_rounded,
                tooltip: 'New session',
                color: colors.textSecondary,
                onTap: _startSessionFromCurrent,
              ),
            ),
          if (!isCompact && !widget.desktopMode && _supportsTerminal)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: MeshIconButton(
                icon: Icons.terminal_rounded,
                tooltip: terminalOpenInInspector
                    ? 'Terminal is open'
                    : 'Open terminal',
                color: terminalOpenInInspector
                    ? colors.accent
                    : colors.textSecondary,
                onTap: () => unawaited(_openTerminal()),
              ),
            ),
          if (!isCompact && !widget.desktopMode && _supportsConnections)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: MeshIconButton(
                icon: Icons.open_in_browser_rounded,
                tooltip: portsOpenInInspector
                    ? 'Browser previews are open'
                    : 'Manage browser previews',
                color: portsOpenInInspector
                    ? colors.accent
                    : colors.textSecondary,
                onTap: () => unawaited(_openConnections()),
              ),
            ),
          if (!isCompact &&
              !widget.desktopMode &&
              _supportsGitStatus &&
              _gitHeaderLabel(session, _gitStatus) != null &&
              (_gitStatus?.dirty ?? false))
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: MeshIconButton(
                icon: Icons.account_tree_rounded,
                tooltip: 'Git details',
                color: colors.warning,
                onTap: () => _showGitSheet(session),
              ),
            ),
          if (!isCompact && !widget.desktopMode)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: MeshIconButton(
                icon: searchOpenInInspector
                    ? Icons.search_off_rounded
                    : Icons.search_rounded,
                tooltip: searchOpenInInspector ? 'Close search' : 'Search',
                color: searchOpenInInspector
                    ? colors.accent
                    : colors.textSecondary,
                onTap: _toggleSearchPanel,
              ),
            ),
          if (!isCompact && !widget.desktopMode && _supportsSessionResources)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: MeshIconButton(
                icon: resourcesOpenInInspector
                    ? Icons.perm_media_rounded
                    : Icons.perm_media_rounded,
                tooltip: resourcesOpenInInspector
                    ? 'Close resources'
                    : 'Open resources',
                color: resourcesOpenInInspector
                    ? colors.accent
                    : colors.textSecondary,
                onTap: _openResourcesPanel,
              ),
            ),
          if (!isCompact && !widget.desktopMode)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: ListenableBuilder(
                listenable: Listenable.merge([_policyStore, _turnConfigStore]),
                builder: (context, _) {
                  final policy = _policyStore.policyFor(
                    widget.host,
                    session.id,
                  );
                  final turnConfig = _turnConfigStore.configFor(
                    widget.host,
                    session.id,
                  );
                  final runtime = session.runtime;
                  final runtimeLoosened = SessionPolicy.runtimeIsLoosened(
                    approvalPolicy: runtime?.approvalPolicy,
                    sandboxMode: runtime?.sandboxMode,
                    networkAccess: runtime?.networkAccess,
                  );
                  final customised =
                      !policy.isEmpty || !turnConfig.isEmpty || runtimeLoosened;
                  return MeshIconButton(
                    icon: customised ? Icons.tune_rounded : Icons.tune_rounded,
                    tooltip: 'Session controls',
                    color: customised ? colors.accent : colors.textSecondary,
                    onTap: () => _showSessionPolicySheet(session),
                  );
                },
              ),
            ),
          ListenableBuilder(
            listenable: Listenable.merge([
              SessionLocalStore.instance,
              _policyStore,
              _turnConfigStore,
            ]),
            builder: (context, _) {
              final favorite = _localStore.isFavorite(widget.host, session.id);
              final gitAvailable =
                  _supportsGitStatus &&
                  _gitHeaderLabel(session, _gitStatus) != null;
              final gitDirty = _gitStatus?.dirty ?? false;
              final policy = _policyStore.policyFor(widget.host, session.id);
              final turnConfig = _turnConfigStore.configFor(
                widget.host,
                session.id,
              );
              final runtime = session.runtime;
              final runtimeLoosened = SessionPolicy.runtimeIsLoosened(
                approvalPolicy: runtime?.approvalPolicy,
                sandboxMode: runtime?.sandboxMode,
                networkAccess: runtime?.networkAccess,
              );
              final sessionControlsCustomized =
                  !policy.isEmpty || !turnConfig.isEmpty || runtimeLoosened;
              // Hide the 'Git details' menu item when it's already a visible
              // icon (dirty state). Keep it hidden entirely if there is no
              // git info to show.
              final showGitInMenu = gitAvailable && !gitDirty;
              final menuGitAvailable = widget.desktopMode
                  ? gitAvailable
                  : showGitInMenu;
              if (isCompact) {
                return Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MeshIconButton(
                        icon: Icons.tune_rounded,
                        tooltip: 'Session controls',
                        color: sessionControlsCustomized
                            ? colors.accent
                            : colors.textSecondary,
                        onTap: () => _showSessionPolicySheet(session),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      MeshIconButton(
                        icon: favorite
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        tooltip: favorite ? 'Unpin session' : 'Pin session',
                        color: favorite ? colors.warning : colors.textSecondary,
                        onTap: _toggleFavorite,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      MeshIconButton(
                        icon: Icons.more_vert_rounded,
                        tooltip: _running
                            ? 'Session actions (agent running)'
                            : 'Session actions',
                        color: _running ? colors.warning : colors.textPrimary,
                        onTap: () => unawaited(
                          _showSessionActionsSheet(
                            session: session,
                            favorite: favorite,
                            gitAvailable: gitAvailable,
                            gitDirty: gitDirty,
                            terminalOpen: terminalOpenInInspector,
                            portsOpen: portsOpenInInspector,
                            searchOpen: searchOpenInInspector,
                            resourcesOpen: resourcesOpenInInspector,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              if (widget.desktopMode) {
                return Builder(
                  builder: (buttonContext) => Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _DesktopSessionCommandBar(
                      running: _running,
                      canStop: _supportsSessionInterrupt,
                      onStop: _stopSession,
                      onNewSession: _startSessionFromCurrent,
                      onMore: () => unawaited(
                        _showSessionActionsSheet(
                          session: session,
                          favorite: favorite,
                          gitAvailable: menuGitAvailable,
                          gitDirty: gitDirty,
                          terminalOpen: terminalOpenInInspector,
                          portsOpen: portsOpenInInspector,
                          searchOpen: searchOpenInInspector,
                          resourcesOpen: resourcesOpenInInspector,
                          anchorContext: buttonContext,
                          includeStop: false,
                          includeNew: false,
                          includeControls: true,
                          controlsCustomized: sessionControlsCustomized,
                        ),
                      ),
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: MeshIconButton(
                  icon: Icons.more_horiz_rounded,
                  tooltip: _running
                      ? 'Session actions (agent running)'
                      : 'Session actions',
                  color: _running ? colors.warning : colors.textSecondary,
                  onTap: () => unawaited(
                    _showSessionActionsSheet(
                      session: session,
                      favorite: favorite,
                      gitAvailable: menuGitAvailable,
                      gitDirty: gitDirty,
                      terminalOpen: terminalOpenInInspector,
                      portsOpen: portsOpenInInspector,
                      searchOpen: searchOpenInInspector,
                      resourcesOpen: resourcesOpenInInspector,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: widget.desktopMode
          ? layoutBody
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissKeyboard,
              child: layoutBody,
            ),
    );
    Widget sessionContent = scaffold;
    if (widget.desktopMode) {
      sessionContent = CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyJ, meta: true):
              _focusComposerFromShortcut,
        },
        child: sessionContent,
      );
    }
    if (widget.topPadding == null) {
      return sessionContent;
    }
    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding!),
      child: sessionContent,
    );
  }
}
