import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import '../composer_image_attachments.dart';
import '../host_status_store.dart';
import '../image_blob_cache_store.dart';
import '../live_activity_service.dart';
import '../theme/message_text_styles.dart';
import '../models.dart';
import '../fs_models.dart';
import '../resource_reference.dart';
import '../pending_send_recovery.dart';
import '../provider_labels.dart';
import '../search_query.dart';
import 'browser_preview_screen.dart';
import 'browser_tabs_screen.dart';
import 'agent_runs_screen.dart';
import 'file_browser_screen.dart';
import 'file_viewer_screen.dart';
import 'image_viewer_screen.dart';
import 'terminal_screen.dart';
import 'inspector/inspector_browser_tabs.dart';
import 'inspector/inspector_agents.dart';
import 'inspector/inspector_browser_preview.dart';
import 'inspector/inspector_controller.dart';
import 'inspector/inspector_file_browser.dart';
import 'inspector/inspector_persistence.dart';
import 'inspector/inspector_pinned.dart';
import 'inspector/inspector_resources.dart';
import 'inspector/inspector_search.dart';
import 'inspector/inspector_terminal.dart';
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
import '../theme/app_control_styles.dart';
import '../windowing.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_composer.dart';
import '../widgets/mobile_model_picker.dart';
import '../widgets/app_menu.dart';
import '../widgets/app_primitives.dart';
import '../widgets/app_sheets.dart';
import '../widgets/markdown_content.dart';
import '../widgets/diff_view.dart';
import '../widgets/launch_options_form.dart';
import '../widgets/mesh_widgets.dart';
import 'package:sidemesh_mobile/src/host_reconnect_scheduler.dart';
import '../widgets/provider_access_mode_choices.dart';
import '../widgets/reasoning_choice_list.dart';
import '../relative_time_ticker.dart';
import '../widgets/syntax_code_block.dart';
import '../theme/app_status_styles.dart';

part 'session_screen_header.dart';
part 'session_screen_composer.dart';
part 'session_screen_timeline.dart';
part 'session_screen_controls.dart';
part 'session_screen_preview.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.host,
    required this.session,
    required this.api,
    this.onOpenSession,
    this.onArchived,
    this.onClose,
    this.initialComposerSeed,
    this.topPadding,
    this.desktopMode = false,
    this.screenAwakeSourceKey,
    this.onReturnToSessionList,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;
  final ValueChanged<SessionSummary>? onOpenSession;
  final VoidCallback? onArchived;

  /// Called when the user dismisses this session from the desktop detail pane.
  final VoidCallback? onClose;
  final SessionComposerSeed? initialComposerSeed;

  /// Returns to the home session list, including from nested session routes.
  final VoidCallback? onReturnToSessionList;
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

String _formatSubAgentSourceKind(String kind) {
  switch (kind) {
    case 'child_session':
    case 'thread_spawn':
    case 'subagent':
      return 'Sub-agent';
    case 'memory_consolidation':
      return 'Memory consolidation';
    default:
      return kind.replaceAll('_', ' ');
  }
}

class _DesktopSessionTitle extends StatelessWidget {
  const _DesktopSessionTitle({
    required this.session,
    required this.host,
    required this.running,
    required this.verifying,
  });

  final SessionSummary session;
  final bool running;
  final bool verifying;
  final HostProfile host;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (verifying) ...[
          const MeshDelayedActivityIndicator(
            key: ValueKey('session-freshness-indicator'),
            active: true,
          ),
          const SizedBox(width: AppSpacing.sm),
        ] else if (running) ...[
          const LivePulse(),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.colors.textPrimary,
                  fontWeight: AppWeights.emphasis,
                ),
              ),
              Text(
                [
                  host.label,
                  ?session.cwd
                      .split('/')
                      .where((part) => part.isNotEmpty)
                      .lastOrNull,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: context.colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DesktopSessionCommandBar extends StatelessWidget {
  const _DesktopSessionCommandBar({
    required this.running,
    required this.canStop,
    required this.onStop,
    required this.tools,
    required this.actions,
    this.onClose,
  });
  final bool running;
  final bool canStop;
  final VoidCallback onStop;
  final List<Widget> tools;
  final List<Widget> actions;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (running && canStop)
        IconButton(
          tooltip: 'Stop agent',
          icon: Icon(
            Icons.stop_circle_outlined,
            size: AppSizes.inlineIcon,
            color: context.colors.danger,
          ),
          onPressed: onStop,
        ),
      AppMenuButton(
        tooltip: 'Workspace tools',
        icon: Icons.space_dashboard_outlined,
        children: tools,
      ),
      AppMenuButton(
        tooltip: running
            ? 'Session actions (agent running)'
            : 'Session actions',
        children: actions,
      ),
      if (onClose != null)
        IconButton(
          tooltip: 'Close session',
          icon: const Icon(Icons.close_rounded, size: AppSizes.inlineIcon),
          onPressed: onClose,
        ),
    ],
  );
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
            const SizedBox(width: AppSpacing.compact),
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
                                fontWeight: AppWeights.strong,
                                letterSpacing: AppLetterSpacing.headline,
                              ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      MeshPill(
                        label: 'paused',
                        tone: MeshPillTone.warning,
                        icon: Icons.pause_rounded,
                        mono: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Tap to reopen · $target',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      color: colors.textSecondary,
                      fontSize: AppFontSizes.metadata,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            _BrowserDockCloseButton(
              icon: Icons.close_rounded,
              tooltip: 'Hide browser',
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
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.compact,
              AppSpacing.sm,
            ),
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
                            'Browser',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: colors.textSecondary,
                                  fontWeight: AppWeights.strong,
                                  letterSpacing: AppLetterSpacing.caps,
                                ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          MeshPill(
                            label: 'open',
                            tone: MeshPillTone.success,
                            icon: Icons.bolt_rounded,
                            mono: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        dockedPreview.preview.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: colors.textPrimary,
                              fontWeight: AppWeights.strong,
                              letterSpacing: AppLetterSpacing.headline,
                            ),
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        target,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textSecondary,
                          fontSize: AppFontSizes.caption,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _BrowserDockAction(
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: 'Minimize',
                  onTap: onMinimize,
                ),
                const SizedBox(width: AppSpacing.tight),
                _BrowserDockAction(
                  icon: Icons.fullscreen_rounded,
                  tooltip: 'Full page',
                  color: colors.accent,
                  onTap: onFullPage,
                ),
                const SizedBox(width: AppSpacing.tight),
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
                bottom: Radius.circular(AppRadii.sheet),
              ),
              child: BrowserPreviewPane(
                key: ValueKey(
                  'session-browser-preview:${dockedPreview.preview.id}',
                ),
                host: host,
                api: api,
                preview: dockedPreview.preview,
                showHeader: false,
                autoResizeViewport: true,
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
    final radius = BorderRadius.circular(
      compact ? AppRadii.sheet : AppRadii.floatingSheet,
    );
    final content = Container(
      height: height,
      margin: EdgeInsets.fromLTRB(
        AppSpacing.compact,
        compact ? AppSpacing.tight : AppSpacing.xs,
        AppSpacing.compact,
        AppSpacing.sm,
      ),
      padding: compact
          ? const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.compact,
              AppSpacing.sm,
              AppSpacing.compact,
            )
          : null,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: colors.borderStrong.withValues(alpha: AppEmphasis.secondary),
        ),
        color: colors.surfaceElevated,
        boxShadow: [AppShadows.surface(colors.textPrimary)],
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
                  color: colors.accent.withValues(alpha: AppEmphasis.focus),
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
        borderRadius: BorderRadius.circular(
          compact ? AppRadii.panel : AppRadii.surface,
        ),
        border: Border.all(
          color: colors.accent.withValues(alpha: AppEmphasis.borderTint),
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: compact ? 18 : 22,
            height: compact ? 18 : 22,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: colors.accent, width: AppStrokes.focus),
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
          borderRadius: BorderRadius.circular(AppRadii.panel),
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: AppEmphasis.focus),
              borderRadius: BorderRadius.circular(AppRadii.panel),
              border: Border.all(color: fg.withValues(alpha: AppEmphasis.soft)),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: AppSizes.inlineIcon, color: fg),
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
          borderRadius: BorderRadius.circular(AppRadii.panel),
          onTap: onTap,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              icon,
              size: AppSizes.inlineIcon,
              color: colors.textTertiary,
            ),
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
  final _composerController = TextEditingController();
  final _searchController = TextEditingController();
  final _composerFocusNode = FocusNode(debugLabel: 'session_composer');
  final _modelPickerAnchor = GlobalKey();
  final _thinkingPickerAnchor = GlobalKey();
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
  final ComposerImageAttachmentService _imageAttachmentService =
      const SystemComposerImageAttachmentService();

  // Live-streaming state is held in notifiers so that mid-stream deltas only
  // rebuild the tiny widgets that display them, not the whole Scaffold/list.
  final ValueNotifier<_LiveAssistantMessageState?> _liveAssistantNotifier =
      ValueNotifier<_LiveAssistantMessageState?>(null);
  final ValueNotifier<bool> _thinkingNotifier = ValueNotifier<bool>(false);

  SessionSummary? _session;
  List<SessionMessage> _messages = const [];
  List<SessionMessage> _optimisticMessages = const [];
  List<SessionActivity> _activities = const [];
  List<ComposerImageAttachment> _draftAttachments =
      const <ComposerImageAttachment>[];
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
  int _messageLimit = _initialMessageLimit;
  int _activityLimit = _initialActivityLimit;
  bool _running = false;
  bool _loading = true;
  String? _snapshotError;
  bool _loadingOlderHistory = false;
  bool _sending = false;
  bool _awaitingAssistantReply = false;
  bool _loadingSkills = false;
  bool _loadingFileSearch = false;
  bool _loadingNodeInfo = false;
  bool _showingCachedSnapshot = false;
  bool _showingPossiblyStaleSnapshot = false;
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
  // Incremented whenever a fresh snapshot is requested so in-flight responses
  // from older requests can be discarded.
  int _snapshotRequestId = 0;
  int? _snapshotRevision;
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
  bool get _showOfflineTranscriptStatus =>
      _resumeSyncFailed &&
      (_showingCachedSnapshot || _showingPossiblyStaleSnapshot);

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
  bool get _verifyingVisibleSnapshot =>
      _snapshotInFlight &&
      !_resumeSyncFailed &&
      (_showingCachedSnapshot || _showingPossiblyStaleSnapshot);

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

  bool get _supportsAgentRuns =>
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

  bool get _supportsBrowserPreview =>
      _supportsHostCapability('workspace', 'browserPreview');

  bool get _supportsProviderRestart =>
      _supportsProviderCapability('lifecycle', 'restart');

  bool get _supportsComposerModelPicker =>
      _supportsProviderCapability('configuration', 'models') &&
      _supportsProviderCapability('runtimeControls', 'model');

  bool get _supportsComposerThinkingPicker =>
      _supportsComposerModelPicker &&
      _supportsProviderCapability('runtimeControls', 'reasoningEffort');

  bool _supportsGitDiffKind(String kind) {
    return _supportsHostCapability('workspace', 'gitDiff');
  }

  // Inspector (desktop pane-3) lifecycle tracking. Resolved in
  // [didChangeDependencies] so we can addListener/removeListener around
  // the same controller instance exposed by the shell's InspectorScope.
  InspectorController? _inspectorController;
  bool _inspectorRestoreAttempted = false;
  bool _inspectorSawOurSurface = false;

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
      _draftAttachments = const <ComposerImageAttachment>[];
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
    final unsupportedAgents =
        current.kind == InspectorSurfaceKind.agents && !_supportsAgentRuns;
    final unsupportedFiles =
        current.kind == InspectorSurfaceKind.fileBrowser &&
        !_supportsFilesystem;
    final unsupportedTerminal =
        current.kind == InspectorSurfaceKind.terminal && !_supportsTerminal;
    final unsupportedBrowser =
        (current.kind == InspectorSurfaceKind.browserTabs ||
            current.kind == InspectorSurfaceKind.browserPreview) &&
        !_supportsBrowserPreview;
    if (unsupportedAgents ||
        unsupportedResources ||
        unsupportedFiles ||
        unsupportedTerminal ||
        unsupportedBrowser) {
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
    final draftAttachments = <ComposerImageAttachment>[];
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
            ComposerImageAttachment(
              id: 'seed-image-$attachmentIndex',
              name:
                  'attachment-${attachmentIndex + 1}${imageExtensionForMimeType(mimeType)}',
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
            _ComposerFileMention(
              file: file,
              tokenText: _fileMentionToken(file),
            ),
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

    // If something else has already opened a surface for this owner
    // (e.g. the shell's debug shortcut) don't stomp it.
    if (cur != null && cur.ownerKey == ownerKey) return;

    if (kind == null) {
      closeOrphan();
      return;
    }
    switch (kind) {
      case InspectorSurfaceKind.agents:
        if (!_supportsAgentRuns) {
          closeOrphan();
          unawaited(InspectorPersistence.save(ownerKey, null));
          return;
        }
        controller.show(
          buildInspectorAgentsSurface(
            ownerKey: ownerKey,
            host: widget.host,
            session: _session ?? widget.session,
            api: widget.api,
          ),
        );
        break;
      case InspectorSurfaceKind.search:
        controller.show(
          buildInspectorSearchSurface(
            ownerKey: ownerKey,
            controller: _searchController,
            focusNode: _searchFocusNode,
            recordsBuilder: _buildSearchRecords,
            loadingBuilder: () =>
                _loading ||
                (_snapshotInFlightRequestId != null && _snapshotError == null),
            errorBuilder: () => _snapshotError,
            onRetry: () => _loadSnapshot(scrollToBottom: false),
            refresh: _timelineRevision,
          ),
        );
        break;
      case InspectorSurfaceKind.resources:
        if (!_supportsSessionResources) {
          closeOrphan();
          unawaited(InspectorPersistence.save(ownerKey, null));
          return;
        }
        controller.show(
          buildInspectorResourcesSurface(
            ownerKey: ownerKey,
            host: widget.host,
            session: _session ?? widget.session,
            api: widget.api,
            onOpenFile: (path) => unawaited(_openMessageResource(path)),
            onOpenHostUrl: _openHostUrl,
          ),
        );
        break;
      case InspectorSurfaceKind.fileBrowser:
        if (!_supportsFilesystem) {
          closeOrphan();
          unawaited(InspectorPersistence.save(ownerKey, null));
          return;
        }
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
        if (!_supportsTerminal) {
          closeOrphan();
          unawaited(InspectorPersistence.save(ownerKey, null));
          return;
        }
        controller.show(
          buildInspectorTerminalSurface(
            ownerKey: ownerKey,
            host: widget.host,
            api: widget.api,
            session: _session ?? widget.session,
          ),
        );
        break;
      case InspectorSurfaceKind.browserTabs:
        if (!_supportsBrowserPreview) {
          closeOrphan();
          unawaited(InspectorPersistence.save(ownerKey, null));
          return;
        }
        controller.show(
          buildInspectorBrowserTabsSurface(
            ownerKey: ownerKey,
            host: widget.host,
            api: widget.api,
            session: _session ?? widget.session,
            onBrowserOpened: (preview) {
              unawaited(_showDockedBrowserPreview(preview: preview));
            },
          ),
        );
        break;
      case InspectorSurfaceKind.browserPreview:
      case InspectorSurfaceKind.debug:
      case InspectorSurfaceKind.gitDetails:
      case InspectorSurfaceKind.sessionDetails:
        // These surfaces are transient or no longer restorable.
        closeOrphan();
        unawaited(InspectorPersistence.save(ownerKey, null));
        break;
      case InspectorSurfaceKind.sessionControls:
        // Controls are transient form state. Never restore a stale draft.
        closeOrphan();
        unawaited(InspectorPersistence.save(ownerKey, null));
        break;
    }
  }

  void _onInspectorChanged() {
    if (!mounted || _disposed) return;
    final controller = _inspectorController;
    if (controller == null) return;
    final ownerKey = _inspectorOwnerKey();
    final cur = controller.current;
    if (cur != null && cur.ownerKey == ownerKey) {
      _inspectorSawOurSurface = true;
      // Transient controls must never reopen on the next visit. Deliberately
      // opened tools remain available across session switches until the user
      // closes them.
      if (cur.kind != InspectorSurfaceKind.sessionControls) {
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
      unawaited(InspectorPersistence.save(ownerKey, null));
    }
    _inspectorSawOurSurface = false;
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
          loadingBuilder: () =>
              _loading ||
              (_snapshotInFlightRequestId != null && _snapshotError == null),
          errorBuilder: () => _snapshotError,
          onRetry: () => _loadSnapshot(scrollToBottom: false),
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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ListenableBuilder(
        listenable: _timelineRevision,
        builder: (context, _) {
          final bottomInset = MediaQuery.of(context).viewInsets.bottom;
          return MeshBottomSheetScaffold(
            title: 'Search',
            maxWidth: 760,
            maxHeightFactor: bottomInset > 0 ? 0.88 : 0.65,
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.lg + bottomInset,
            ),
            child: SearchPanel(
              controller: _searchController,
              focusNode: _searchFocusNode,
              records: _buildSearchRecords(),
              loading:
                  _loading ||
                  (_snapshotInFlightRequestId != null &&
                      _snapshotError == null),
              error: _snapshotError,
              onRetry: () => _loadSnapshot(scrollToBottom: false),
            ),
          );
        },
      ),
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

  bool _isBrowserInspectorOpen(InspectorController? scope) {
    if (scope == null) return false;
    final cur = scope.current;
    return cur != null &&
        (cur.kind == InspectorSurfaceKind.browserTabs ||
            cur.kind == InspectorSurfaceKind.browserPreview) &&
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
          Navigator.of(sheetContext).pop();
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
          onOpenFile: (path) => unawaited(_openMessageResource(path)),
          onOpenHostUrl: _openHostUrl,
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
        maxWidth: 900,
        maxHeightFactor: 0.84,
        child: SessionResourcesPanel(
          host: widget.host,
          session: session,
          api: widget.api,
          onClose: () => Navigator.of(sheetContext).maybePop(),
          onOpenFile: (path) {
            Navigator.of(sheetContext).maybePop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _disposed) return;
              unawaited(_openMessageResource(path));
            });
          },
          onOpenHostUrl: (url) {
            Navigator.of(sheetContext).maybePop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _disposed) return;
              _openHostUrl(url);
            });
          },
        ),
      ),
    );
  }

  void _openAgentsPanel() {
    if (!_supportsAgentRuns) {
      showAppSnackBar(context, 'This agent does not expose session history.');
      return;
    }
    final width = MediaQuery.of(context).size.width;
    final scope = InspectorScope.maybeOf(context);
    final session = _session ?? widget.session;
    if (width >= 900 && scope != null) {
      scope.toggle(
        buildInspectorAgentsSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          session: session,
          api: widget.api,
        ),
      );
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AgentRunsScreen(
            host: widget.host,
            session: session,
            api: widget.api,
          ),
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

  /// Tracks composer blur timing so desktop overlays can restore focus safely.
  void _handleComposerFocusChanged() {
    if (!_composerFocusNode.hasFocus) {
      _lastComposerBlurAt = DateTime.now();
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
      // sees fresh state immediately from a provider snapshot.
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
      _resumeSyncFailed = false;
    });
  }

  Future<void> _resyncAfterResume() async {
    if (!mounted || _disposed) return;
    _markTranscriptPossiblyStale();
    await _loadSnapshot(scrollToBottom: false);
  }

  Future<void> _loadSnapshot({
    int? messageLimit,
    int? activityLimit,
    bool scrollToBottom = true,
  }) async {
    final resolvedMessageLimit = messageLimit ?? _messageLimit;
    final resolvedActivityLimit = activityLimit ?? _activityLimit;
    _flushPendingLiveUpdates();
    final requestId = ++_snapshotRequestId;
    setState(() {
      _snapshotInFlightRequestId = requestId;
      _snapshotError = null;
    });
    _timelineRevision.value++;
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
      // Apply buffered events through the same revision check as events that
      // arrive after the HTTP response. The two connections can arrive in
      // either order.
      final bufferedEvents = List<LiveEvent>.from(_pendingLiveEvents);
      _pendingLiveEvents.clear();
      final snapshotActivities = _mergeIncomingActivities(
        _activities,
        log.activities,
        mode: _ActivityMergeMode.snapshot,
      );
      setState(() {
        _snapshotRevision = log.revision;
        _snapshotError = null;
        _session = log.session;
        _messages = log.messages;
        _optimisticMessages = _reconcileOptimisticMessages(log.messages);
        _activities = snapshotActivities;
        _history = log.history;
        _messageLimit = resolvedMessageLimit;
        _activityLimit = resolvedActivityLimit;
        _historyBannerDismissed = false;
        _showingCachedSnapshot = false;
        _showingPossiblyStaleSnapshot = false;
        _resumeSyncFailed = false;
        // Snapshot responses are authoritative for pending actions. If a live
        // action_opened lands during this fetch, it is buffered and replayed
        // after this state update.
        _applyFetchedSessionStatus(SessionStatus(
          sessionId: log.session.id,
          status: log.session.status,
          isRunning: log.session.isActive,
          activeTurnId: null,
          pendingAction: pendingAction,
        ));
        _loading = false;
        _clearLiveAssistantMessage();
        if (_running && log.liveAssistantText.isNotEmpty) {
          _liveAssistantNotifier.value = _appendLiveAssistantDelta(null, log.liveAssistantText);
        }
        if (_running && log.liveAssistantReasoning.isNotEmpty) {
          _liveAssistantNotifier.value = _appendLiveAssistantReasoning(_liveAssistantMessage, log.liveAssistantReasoning);
        }
        _awaitingAssistantReply =
            log.session.isActive &&
            _liveAssistantText.isEmpty &&
            _pendingAction == null;
        _restoreLatestPlanUpdate(
          log.latestPlanUpdate,
          fallbackCreatedAt: log.session.updatedAt,
        );
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
      final canKeepShowingSavedTranscript =
          _showingCachedSnapshot || _showingPossiblyStaleSnapshot;
      setState(() {
        _loading = false;
        if (canKeepShowingSavedTranscript) {
          _resumeSyncFailed = true;
        } else if (_messages.isEmpty) {
          _snapshotError = friendlyError(error);
        }
      });
      HostStatusStore.instance.markOffline(
        widget.host.id,
        error: friendlyError(error),
      );
      if (!canKeepShowingSavedTranscript && _messages.isNotEmpty) {
        showAppSnackBar(
          context,
          "Failed to load session: ${friendlyError(error)}",
        );
      }
    } finally {
      if (mounted && _snapshotInFlightRequestId == requestId) {
        setState(() => _snapshotInFlightRequestId = null);
        final bufferedEvents = List<LiveEvent>.from(_pendingLiveEvents);
        _pendingLiveEvents.clear();
        for (final event in bufferedEvents) {
          _handleEvent(event);
        }
      }
      if (mounted && !_disposed) _timelineRevision.value++;
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
        _snapshotError = null;
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
        _resumeSyncFailed = false;
        _awaitingAssistantReply =
            log.session.isActive &&
            _liveAssistantText.isEmpty &&
            _pendingAction == null;
        _restoreLatestPlanUpdate(
          log.latestPlanUpdate,
          fallbackCreatedAt: log.session.updatedAt,
        );
      });
      _refreshThinkingState();
      _markCurrentSessionSeen();
      return true;
    } catch (_) {
      // Cached transcripts are best-effort. A fresh snapshot is already queued.
      return false;
    }
  }

  void _scheduleTurnCompletionRefresh() {
    // Providers can finish a turn before their last history write is readable.
    // Keep this refresh even when a snapshot already covered the idle state.
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      unawaited(_loadSnapshot(scrollToBottom: false));
      unawaited(_loadGitStatus(silent: true));
    });
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

  Future<void> _refreshSessionFreshness({bool scrollToBottom = true}) async {
    await _loadSnapshot(scrollToBottom: scrollToBottom);
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

    if (event.type == 'hello') {
      _snapshotRevision = null;
      _pendingLiveEvents.clear();
      unawaited(_loadSkills(forceReload: true));
      // Every connection verifies the snapshot, including daemon restarts and
      // changes to existing transcript items that do not allocate a new seq.
      _markTranscriptPossiblyStale();
      unawaited(_loadSnapshot(scrollToBottom: false));
      return;
    }

    final revision = event.revision;
    if (revision != null &&
        _snapshotRevision != null &&
        revision <= _snapshotRevision!) {
      // History can lag a live completion and use different message IDs.
      // Preserve the reply without applying old status/draft transitions.
      final message = event.messageItem;
      if (message != null &&
          !_messages.any((saved) =>
              saved.id == message.id ||
              _matchesPersistedMessage(saved, message))) {
        setState(() => _upsertOptimisticMessage(message));
      }
      if (event.type == 'turn_completed') {
        _scheduleTurnCompletionRefresh();
      }
      // These notifications are not represented in the session snapshot.
      if (event.type != 'provider_warning' &&
          event.type != 'queue_updated' &&
          event.type != 'auto_retry_updated' &&
          event.type != 'skills_changed') {
        return;
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
        _scheduleTurnCompletionRefresh();
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
    final showThreadStatus = _shouldShowThreadStatusEvent(threadStatus);
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
      final update = await _imageAttachmentService.pickImages(
        current: _draftAttachments,
      );
      if (!mounted || update == null) return;
      _applyImageAttachmentUpdate(update);
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
      final update = await _imageAttachmentService.pasteImage(
        current: _draftAttachments,
        reportEmpty: showEmptyFeedback,
      );
      if (!mounted) return false;
      _applyImageAttachmentUpdate(update);
      return update.added;
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

  void _applyImageAttachmentUpdate(ComposerImageAttachmentUpdate update) {
    setState(() {
      _draftAttachments = update.attachments;
    });
    for (final message in update.feedback) {
      showAppSnackBar(context, message);
    }
  }

  void _removeDraftAttachment(String attachmentId) {
    setState(() {
      _draftAttachments = _draftAttachments
          .where((item) => item.id != attachmentId)
          .toList();
    });
  }

  List<SessionInputItem> _buildComposerInputItems(
    String text,
    List<ComposerImageAttachment> attachments,
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
    List<ComposerImageAttachment> attachments,
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
    required String? accessMode,
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
      accessMode: accessMode,
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
          accessMode: pending.accessMode,
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
        accessMode: normalizedOverrides.accessMode,
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
    if (_loading || _snapshotError != null) return;
    final text = _composerController.text.trim();
    final draftAttachments = List<ComposerImageAttachment>.from(
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
      accessMode: normalizedOverrides.accessMode,
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
      _draftAttachments = const <ComposerImageAttachment>[];
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
        accessMode: normalizedOverrides.accessMode,
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
          accessMode: normalizedOverrides.accessMode,
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
      final restoredAttachments = List<ComposerImageAttachment>.from(
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
    required String? accessMode,
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
      'accessMode': accessMode,
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
    final random = math.Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return 'local-${base64UrlEncode(bytes).replaceAll('=', '')}';
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
        onOpenFile: (path) => unawaited(_openMessageResource(path)),
        onOpenHostUrl: _openHostUrl,
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
      final providerOptionId = response.payload['providerOptionId'];
      String? providerOptionLabel;
      if (providerOptionId is String) {
        for (final option in action.approval?.providerOptions ?? const []) {
          if (option.id == providerOptionId) {
            providerOptionLabel = option.label;
            break;
          }
        }
      }
      final label = switch (action.kind) {
        'user_input' => 'Answer sent',
        'elicitation' => 'Response sent',
        _ when providerOptionLabel != null => providerOptionLabel,
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
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => _GitDetailsSheet(
          session: session,
          status: _gitStatus,
          loading: _gitStatusLoading,
          error: _gitStatusError,
          onRefresh: () async {
            final refresh = _loadGitStatus();
            setSheetState(() {});
            await refresh;
            if (sheetContext.mounted) setSheetState(() {});
          },
          onShowDiff: (kind) {
            Navigator.of(sheetContext).pop();
            unawaited(_showGitDiffSheet(kind));
          },
        ),
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
    final gitLabel = _supportsGitStatus
        ? _gitHeaderLabel(session, _gitStatus)
        : null;
    final subAgentInfo = session.subAgent;
    final subAgentLabel = subAgentInfo?.label;
    Widget detailsContent(BuildContext surfaceContext) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            session.title,
            style: Theme.of(surfaceContext).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
          _DetailRow(label: 'Machine', value: widget.host.label),
          _DetailRow(label: 'Folder', value: session.cwd),
          _DetailRow(label: 'Status', value: _running ? 'Running' : 'Idle'),
          _DetailRow(label: 'Started from', value: session.source),
          if (subAgentLabel != null)
            _DetailRow(label: 'Sub-agent', value: subAgentLabel),
          if (subAgentInfo?.parentSessionId?.isNotEmpty == true)
            _DetailRow(
              label: 'Parent session',
              value: subAgentInfo!.parentSessionId!,
            ),
          if (subAgentInfo != null)
            _DetailRow(
              label: 'Sub-agent source',
              value: _formatSubAgentSourceKind(subAgentInfo.sourceKind),
            ),
          if (gitLabel != null) ...[
            _DetailRow(label: 'Git', value: gitLabel),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.of(surfaceContext).pop();
                  unawaited(_showGitSheet(session));
                },
                icon: const Icon(Icons.account_tree_rounded),
                label: const Text('View Git details'),
              ),
            ),
          ],
          if (session.runtime != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Runtime',
              style: Theme.of(surfaceContext).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            _SessionRuntimeDetails(runtime: session.runtime!),
          ],
        ],
      );
    }

    Future<void> showSheet() => showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => MeshBottomSheetScaffold(
        title: 'Session details',
        maxWidth: AppSizes.readingMaxWidth,
        maxHeightFactor: 0.86,
        child: SingleChildScrollView(child: detailsContent(sheetContext)),
      ),
    );
    if (widget.desktopMode) {
      await _showDesktopOverlayWithComposerFocusRestore(showSheet);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (pageContext) => Scaffold(
          backgroundColor: pageContext.colors.canvas,
          appBar: AppBar(title: const Text('Session details')),
          body: SingleChildScrollView(
            padding: AppPadding.mobilePage,
            child: AppContentColumn(child: detailsContent(pageContext)),
          ),
        ),
      ),
    );
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

  String _composerThinkingLabel(SessionSummary session) {
    final turnConfig = _composerTurnConfig(session);
    final override = _cleanComposerLabel(turnConfig.reasoningEffort);
    if (override != null) {
      return reasoningEffortLabel(override);
    }
    final runtime = _cleanComposerLabel(session.runtime?.reasoningEffort);
    if (runtime != null) {
      return reasoningEffortLabel(runtime);
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
        currentReasoning:
            turnConfig.reasoningEffort ?? session.runtime?.reasoningEffort,
        onReasoningSelected:
            capabilities?.supports('runtimeControls', 'reasoningEffort') == true
            ? (effort) => _saveComposerReasoning(
                session,
                models.firstWhere(
                  (model) => model.model == currentModel,
                  orElse: () => defaultModel,
                ),
                effort,
              )
            : null,
      ),
    );
    if (!mounted || _disposed || selected == null) return;

    final nextConfig = _composerConfigForSelectedModel(
      session: session,
      current: _composerTurnConfig(session),
      selected: selected,
      capabilities: capabilities,
    );
    if (_sameTurnConfig(nextConfig, turnConfig)) {
      return;
    }

    await _turnConfigStore.setConfig(widget.host, session.id, nextConfig);
    if (!mounted || _disposed) return;
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
      showAppSnackBar(context, 'This model manages thinking automatically.');
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

    await _saveComposerReasoning(session, selectedModel, selected);
  }

  Future<void> _saveComposerReasoning(
    SessionSummary session,
    ModelCatalogEntry selectedModel,
    String selected,
  ) async {
    final turnConfig = _composerTurnConfig(session);
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
      return;
    }

    await _turnConfigStore.setConfig(widget.host, session.id, nextConfig);
    if (!mounted || _disposed) return;
  }

  Future<T?> _showComposerPicker<T>({
    required GlobalKey anchor,
    required double height,
    required Widget child,
  }) {
    final box = anchor.currentContext?.findRenderObject() as RenderBox?;
    final position = box?.localToGlobal(Offset.zero);
    final size = MediaQuery.sizeOf(context);
    final width = math.min(AppSizes.pickerWidth, size.width - AppSpacing.xl);
    final pickerHeight = math.min(height, size.height - 24);
    final left = ((position?.dx ?? size.width) + (box?.size.width ?? 0) - width)
        .clamp(12.0, size.width - width - 12);
    final top = ((position?.dy ?? size.height - 48) - pickerHeight - 8).clamp(
      12.0,
      size.height - pickerHeight - 12,
    );
    return showDialog<T>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: width,
            height: pickerHeight,
            child: Material(
              color: context.colors.surfaceElevated,
              elevation: AppEmphasis.popupElevation,
              shadowColor: context.colors.textPrimary.withValues(
                alpha: AppEmphasis.popupShadow,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: AppShapes.menu,
                side: BorderSide(color: context.colors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<ModelCatalogEntry?> _showComposerModelPickerSurface({
    required List<ModelCatalogEntry> models,
    required String currentModel,
    required String? providerName,
    String? currentReasoning,
    Future<void> Function(String)? onReasoningSelected,
  }) {
    final picker = _ModelPickerSheet(
      models: models,
      currentModel: currentModel,
      providerName: providerName,
      currentReasoning: currentReasoning,
      onReasoningSelected: onReasoningSelected,
    );
    if (widget.desktopMode) {
      return _showComposerPicker<ModelCatalogEntry>(
        anchor: _modelPickerAnchor,
        height: AppSizes.pickerMaxHeight,
        child: _ModelPickerSheet(
          models: models,
          currentModel: currentModel,
          providerName: providerName,
          compact: true,
        ),
      );
    }
    return showModalBottomSheet<ModelCatalogEntry>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppOverlayColors.modalBarrier,
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
      return _showComposerPicker<String>(
        anchor: _thinkingPickerAnchor,
        height: AppSizes.menuItem + options.length * AppSizes.desktopMenuItem,
        child: _ReasoningPickerSheet(
          options: options,
          currentReasoning: currentReasoning,
          defaultReasoning: defaultReasoning,
          modelLabel: modelLabel,
          compact: true,
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
    if (widget.desktopMode) {
      await showDialog<void>(
        context: context,
        barrierColor: AppOverlayColors.modalBarrier,
        builder: (dialogContext) => Material(
          type: MaterialType.transparency,
          child: MeshBottomSheetScaffold(
            title: 'Session settings',
            maxWidth: AppSizes.pickerWidth + AppSizes.control * 2,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: SessionControlsSheet(
              api: widget.api,
              host: widget.host,
              session: session,
              showReplyControls: false,
              onClose: () => Navigator.of(dialogContext).pop(),
              runtimeModel: runtime?.model,
              runtimeModelProvider: runtime?.modelProvider,
              runtimeMode: runtime?.mode,
              runtimeServiceTier: runtime?.serviceTier,
              runtimeReasoningEffort: runtime?.reasoningEffort,
              runtimeApproval: ApprovalPolicy.fromWire(runtime?.approvalPolicy),
              runtimeSandbox: SandboxMode.fromWire(runtime?.sandboxMode),
              runtimeNetworkAccess: runtime?.networkAccess,
              runtimeAccessMode: runtime?.accessMode,
              policyStore: _policyStore,
              turnConfigStore: _turnConfigStore,
            ),
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) => Scaffold(
          backgroundColor: pageContext.colors.canvas,
          appBar: AppBar(title: const Text('Session settings')),
          body: SessionControlsSheet(
            api: widget.api,
            host: widget.host,
            session: session,
            showReplyControls: false,
            runtimeModel: runtime?.model,
            runtimeModelProvider: runtime?.modelProvider,
            runtimeMode: runtime?.mode,
            runtimeServiceTier: runtime?.serviceTier,
            runtimeReasoningEffort: runtime?.reasoningEffort,
            runtimeApproval: ApprovalPolicy.fromWire(runtime?.approvalPolicy),
            runtimeSandbox: SandboxMode.fromWire(runtime?.sandboxMode),
            runtimeNetworkAccess: runtime?.networkAccess,
            runtimeAccessMode: runtime?.accessMode,
            policyStore: _policyStore,
            turnConfigStore: _turnConfigStore,
          ),
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

  Future<void> _openBrowserPreviewTarget(
    BrowserPreviewTargetCandidate candidate,
  ) async {
    if (!_supportsBrowserPreview) {
      showAppSnackBar(context, 'This host does not expose the browser.');
      return;
    }
    final session = _session ?? widget.session;
    final viewport = MediaQuery.sizeOf(context);
    try {
      final profileMode = browserPreviewProfileModeForTarget(candidate);
      final previews = await widget.api.fetchBrowserPreviews(widget.host);
      final existing = findReusableBrowserPreview(
        previews,
        candidate,
        sessionId: session.id,
        cwd: session.cwd,
        profileMode: profileMode,
      );
      final preview =
          existing ??
          await widget.api.createBrowserPreview(
            widget.host,
            targetPort: candidate.port,
            targetHost: candidate.host,
            targetUrl: candidate.targetUrl,
            scheme: candidate.scheme,
            label: candidate.sourceLabel,
            cwd: candidate.cwd ?? session.cwd,
            sessionId: session.id,
            width: viewport.width.round().clamp(320, 1200),
            height: viewport.height.round().clamp(480, 1400),
            profileMode: profileMode,
          );
      if (!mounted) return;
      await _showDockedBrowserPreview(preview: preview);
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Opened browser for ${candidate.endpointLabel}.',
      );
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not open browser: ${friendlyError(error)}',
      );
    }
  }

  void _openHostUrl(String raw) {
    final session = _session ?? widget.session;
    final parsed = parseBrowserPreviewTargetInput(
      raw,
      sourceLabel: 'Message link',
      cwd: session.cwd,
    );
    final candidate = parsed.candidate;
    if (candidate == null) {
      showAppSnackBar(context, parsed.error ?? 'Could not open host link.');
      return;
    }
    unawaited(_openBrowserPreviewTarget(candidate));
  }

  Future<void> _openMessageResource(String path) async {
    if (!_supportsFilesystem) {
      showAppSnackBar(context, 'This host does not expose workspace files.');
      return;
    }
    final session = _session ?? widget.session;
    try {
      final metadata = await widget.api.fetchMetadata(
        widget.host,
        path,
        agentProvider: session.provider,
        sessionId: session.id,
      );
      if (!mounted || _disposed) return;
      _openWorkspaceFile(metadata.path);
      return;
    } on ApiException catch (error) {
      if (error.statusCode != 403) {
        if (mounted && !_disposed) {
          showAppSnackBar(
            context,
            'Could not open file: ${friendlyError(error)}',
          );
        }
        return;
      }
    } catch (error) {
      if (mounted && !_disposed) {
        showAppSnackBar(
          context,
          'Could not open file: ${friendlyError(error)}',
        );
      }
      return;
    }

    try {
      final artifact = await widget.api.publishSessionArtifact(
        widget.host,
        sessionId: session.id,
        source: path,
      );
      final bytes = await widget.api.fetchSessionArtifact(
        widget.host,
        artifact.id,
      );
      if (!mounted || _disposed) return;
      showImageViewer(
        context,
        source: ImageViewerSource(
          imageProvider: MemoryImage(bytes),
          heroTag: 'session-artifact:${widget.host.id}:${artifact.id}',
          title: _basename(path),
          subtitle: 'Temporary artifact from ${widget.host.label}',
        ),
      );
    } catch (error) {
      if (!mounted || _disposed) return;
      showAppSnackBar(
        context,
        'Could not open temporary artifact: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _openBrowserTabs() async {
    if (!_supportsBrowserPreview) {
      showAppSnackBar(context, 'This host does not expose the browser.');
      return;
    }
    final session = _session ?? widget.session;
    final scope = InspectorScope.maybeOf(context);
    if (widget.desktopMode && scope != null) {
      scope.show(
        buildInspectorBrowserTabsSurface(
          ownerKey: _inspectorOwnerKey(),
          host: widget.host,
          api: widget.api,
          session: session,
          onBrowserOpened: (preview) {
            unawaited(_showDockedBrowserPreview(preview: preview));
          },
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserTabsScreen(
          host: widget.host,
          api: widget.api,
          cwd: session.cwd,
          sessionId: session.id,
          onBrowserOpened: (preview) {
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
    final scope = InspectorScope.maybeOf(context);
    if (widget.desktopMode && scope != null) {
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
      _dockedBrowserPreview = _DockedBrowserPreview(preview: preview);
    });
  }

  Future<void> _openBrowserPreviewWindow(HostBrowserPreviewInfo preview) async {
    final current = _dockedBrowserPreview;
    if (current?.preview.id == preview.id) {
      setState(() => _dockedBrowserPreview = null);
    }
    final scope = InspectorScope.maybeOf(context);
    final active = scope?.current;
    if (active?.kind == InspectorSurfaceKind.browserPreview &&
        active?.ownerKey == _inspectorOwnerKey()) {
      scope?.close();
    }
    final opened = await SidemeshBrowserPreviewWindowManager.instance
        .openOrFocusBrowserPreviewWindow(host: widget.host, preview: preview);
    if (!mounted || _disposed) {
      return;
    }
    showAppSnackBar(
      context,
      opened
          ? 'Opened ${preview.label} in a new window.'
          : 'Browser windows are only available on the desktop app.',
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
        'Could not close browser: ${friendlyError(error)}',
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
          root: browserRoot,
          agentProvider: session.provider,
          sessionId: session.id,
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
    _activities = _mergeIncomingActivities(_activities, [
      activity,
    ], mode: _ActivityMergeMode.incremental);
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

    final grouped = <_TimelineEntry>[];
    final infoNotices = <(String?, String?, String?), int>{};
    for (final entry in entries) {
      final notice = entry.runtimeEvent?.event;
      if (entry.kind == _TimelineEntryKind.providerWarning &&
          notice?.level == 'info') {
        final key = (notice?.message, notice?.source, notice?.code);
        final index = infoNotices[key];
        if (index != null) {
          final prior = grouped[index];
          grouped[index] = _TimelineEntry._(
            kind: prior.kind,
            createdAt: prior.createdAt,
            seq: prior.seq,
            keyId: prior.keyId,
            runtimeEvent: prior.runtimeEvent,
            repeatCount: prior.repeatCount + 1,
          );
          continue;
        }
        infoNotices[key] = grouped.length;
      }
      final previous = grouped.lastOrNull;
      final event = entry.runtimeEvent?.event;
      final prior = previous?.runtimeEvent?.event;
      if (entry.kind == _TimelineEntryKind.providerWarning &&
          previous?.kind == _TimelineEntryKind.providerWarning &&
          event?.message == prior?.message &&
          event?.level == prior?.level &&
          event?.source == prior?.source &&
          event?.code == prior?.code) {
        grouped[grouped.length - 1] = _TimelineEntry._(
          kind: previous!.kind,
          createdAt: previous.createdAt,
          seq: previous.seq,
          keyId: previous.keyId,
          runtimeEvent: previous.runtimeEvent,
          repeatCount: previous.repeatCount + 1,
        );
      } else {
        grouped.add(entry);
      }
    }

    _entriesMessagesRef = _messages;
    _entriesOptimisticRef = _optimisticMessages;
    _entriesActivitiesRef = _activities;
    _entriesTimelineEventsRef = _timelineLiveEvents;
    _entriesLiveAssistantId = liveAssistant?.id;
    _cachedEntries = grouped;
    // Notify pane-3 surfaces (search) that records should be rebuilt.
    // Scheduled post-frame so we don't call notifyListeners during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _timelineRevision.value++;
    });
    return grouped;
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
      id: 'file-change-group:${first.turnId ?? first.id}:${activities.length}:${activities.last.id}',
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
      return 'in_progress';
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
    ].join('\n');
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
    ].join('\n');
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
        return activity.status == 'in_progress'
            ? 'Editing $fileCount files'
            : 'Edited $fileCount files';
      case 'turn_diff':
        return 'Turn diff';
      case 'web_search':
        final q = (activity.query ?? '').trim();
        return q.isEmpty ? 'Web search' : 'Web: $q';
      case 'image_generation':
        return switch (activity.status) {
          'completed' => 'Generated image',
          'failed' => 'Image generation failed',
          'declined' => 'Image generation declined',
          _ => 'Generating image',
        };
      case 'context_compaction':
        return switch (activity.status) {
          'completed' => 'Context compacted',
          'failed' => 'Context compaction failed',
          'declined' => 'Context compaction declined',
          _ => 'Compacting context',
        };
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
          : 'Session pop-out windows are only available on the desktop app.',
    );
  }

  void _handleSessionAction(String value, SessionSummary session) {
    switch (value) {
      case 'stop':
        unawaited(_stopSession());
      case 'restart_provider':
        unawaited(_restartProvider());
      case 'info':
        _showSessionDetailsSheet(session);
        break;
      case 'reload':
        _reloadSnapshot();
        break;
      case 'controls':
        _showSessionPolicySheet(session);
        break;
      case 'terminal':
        if (_supportsTerminal) {
          unawaited(_openTerminal());
        }
        break;
      case 'preview':
        if (_supportsBrowserPreview) {
          unawaited(_openBrowserTabs());
        }
        break;
      case 'pins':
        _openPinnedPanel();
        break;
      case 'search':
        _toggleSearchPanel();
        break;
      case 'resources':
        if (_supportsSessionResources) {
          _openResourcesPanel();
        }
        break;
      case 'agents':
        if (_supportsAgentRuns) {
          _openAgentsPanel();
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
    required bool browserOpen,
    required bool searchOpen,
    required bool resourcesOpen,
    bool includeStop = true,
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
        label: 'Open',
        actions: [
          if (_supportsAgentRuns)
            const _SessionActionSpec(
              value: 'agents',
              label: 'Agents',
              detail: 'View agents spawned by this session.',
              icon: Icons.account_tree_rounded,
            ),
          if (_supportsBrowserPreview)
            _SessionActionSpec(
              value: 'preview',
              label: 'Browser',
              detail: browserOpen
                  ? 'Choose another tab or return to the open browser.'
                  : 'Open a tab or enter a URL.',
              icon: Icons.open_in_browser_rounded,
              tone: browserOpen
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
            ),
          if (_supportsTerminal)
            _SessionActionSpec(
              value: 'terminal',
              label: terminalOpen ? 'Terminal is open' : 'Terminal',
              detail: terminalOpen
                  ? 'Jump back to the active terminal.'
                  : 'Open a shell for this workspace.',
              icon: Icons.terminal_rounded,
              tone: terminalOpen
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
            ),
          if (_supportsFilesystem)
            const _SessionActionSpec(
              value: 'browse',
              label: 'Files',
              detail: 'Browse this workspace.',
              icon: Icons.folder_rounded,
            ),
          if (_supportsSessionResources)
            _SessionActionSpec(
              value: 'resources',
              label: resourcesOpen ? 'Resources are open' : 'Resources',
              detail: 'View generated images and session assets.',
              icon: Icons.perm_media_rounded,
              tone: resourcesOpen
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
            ),
          if (_currentPins().isNotEmpty)
            const _SessionActionSpec(
              value: 'pins',
              label: 'Pinned messages',
              icon: Icons.push_pin_outlined,
            ),
          if (gitAvailable)
            _SessionActionSpec(
              value: 'git',
              label: 'Git',
              detail: gitDirty
                  ? 'Working tree has changes.'
                  : 'Branch, upstream, and diff shortcuts.',
              icon: Icons.account_tree_rounded,
              tone: gitDirty
                  ? _SessionActionTone.warning
                  : _SessionActionTone.neutral,
            ),
        ],
      ),
      _SessionActionGroup(
        label: 'Session',
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
          ),
          if (includeControls)
            _SessionActionSpec(
              value: 'controls',
              label: 'Session settings',
              detail: 'Speed, permissions, and access.',
              icon: Icons.tune_rounded,
              tone: controlsCustomized
                  ? _SessionActionTone.accent
                  : _SessionActionTone.neutral,
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
          ),
          const _SessionActionSpec(
            value: 'unread',
            label: 'Mark unread',
            detail: 'Keep this session unread in your session list.',
            icon: Icons.flag_rounded,
          ),
          const _SessionActionSpec(
            value: 'info',
            label: 'Session details',
            detail: 'View host, model, git, and usage info.',
            icon: Icons.info_outline_rounded,
          ),
          if (widget.topPadding != null &&
              SidemeshSessionWindowManager.instance.isSupported)
            const _SessionActionSpec(
              value: 'popout',
              label: 'Open in new window',
              detail: 'Detach this session into its own desktop window.',
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
      _SessionActionGroup(
        label: 'Troubleshooting',
        actions: [
          if (_supportsSessionCompact)
            const _SessionActionSpec(
              value: 'compact',
              label: 'Compact context',
              detail: 'Summarize older context to keep the session lighter.',
              icon: Icons.compress_rounded,
            ),
          const _SessionActionSpec(
            value: 'reload',
            label: 'Reload',
            detail: 'Refresh this transcript from the host.',
            icon: Icons.refresh_rounded,
          ),
          if (_supportsProviderRestart)
            const _SessionActionSpec(
              value: 'restart_provider',
              label: 'Restart agent',
              detail: 'Restart the active agent on this host.',
              icon: Icons.restart_alt_rounded,
              tone: _SessionActionTone.warning,
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
    required bool browserOpen,
    required bool searchOpen,
    required bool resourcesOpen,
    bool includeStop = true,
    bool includeControls = false,
    bool controlsCustomized = false,
  }) async {
    final groups = _sessionActionGroups(
      favorite: favorite,
      gitAvailable: gitAvailable,
      gitDirty: gitDirty,
      terminalOpen: terminalOpen,
      browserOpen: browserOpen,
      searchOpen: searchOpen,
      resourcesOpen: resourcesOpen,
      includeStop: includeStop,
      includeControls: includeControls,
      controlsCustomized: controlsCustomized,
    );
    final String? selected;
    final restoreComposerFocus =
        _shouldRestoreComposerFocusAfterDesktopOverlay();
    selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppOverlayColors.modalBarrier,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) =>
          _SessionActionSheet(session: session, groups: groups),
    );
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

  @override
  Widget build(BuildContext context) {
    final session = _session ?? widget.session;
    final colors = context.colors;
    final timelineEntries = _buildTimelineEntries();
    final visibleTimelineEntries = timelineEntries;
    final isCompact = MediaQuery.of(context).size.width < 600;
    final showHistoryBanner =
        (_history?.isTruncated ?? false) && !_historyBannerDismissed;
    final showStopPill = isCompact && _running && _supportsSessionInterrupt;
    final showWaitingState = !_loading && timelineEntries.isEmpty && _running;
    final bodyContent = Column(
      children: [
        if (_snapshotError != null)
          MaterialBanner(
            content: Text('Could not load this conversation. $_snapshotError'),
            actions: [
              TextButton(
                onPressed: _snapshotInFlightRequestId == null
                    ? _reloadSnapshot
                    : null,
                child: const Text('Retry'),
              ),
            ],
          ),
        if (_pendingAction != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xs,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: _PendingActionCard(
              action: _pendingAction!,
              onRespond: _respondAction,
            ),
          ),
        if (_showOfflineTranscriptStatus)
          ListenableBuilder(
            listenable: RelativeTimeTicker.seconds,
            builder: (context, _) {
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  widget.desktopMode && _pendingAction == null
                      ? AppSpacing.sm
                      : 0,
                  AppSpacing.lg,
                  AppSpacing.compact,
                ),
                child: _OfflineTranscriptStrip(
                  lastConnectedLabel: _lastConnectedLabel,
                  onRetry: _retryFreshnessSync,
                ),
              );
            },
          ),
        Expanded(
          child: (_loading && timelineEntries.isEmpty)
              ? const MeshLoader(label: 'Loading conversation')
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
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.lg,
                              AppSpacing.tight,
                              AppSpacing.lg,
                              AppSpacing.md,
                            ),
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
                                    AppSpacing.compact,
                                    0,
                                    AppSpacing.tight,
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
                                    sessionId: session.id,
                                    message: entry.message!,
                                    pinned: _pinsStore.isPinned(
                                      widget.host,
                                      session.id,
                                      entry.message!.id,
                                    ),
                                    onTogglePin: () =>
                                        _toggleMessagePin(entry.message!),
                                    onOpenFile: (path) =>
                                        unawaited(_openMessageResource(path)),
                                    onOpenHostUrl: _openHostUrl,
                                  ),
                                  _TimelineEntryKind.activity => _ActivityCard(
                                    host: widget.host,
                                    api: widget.api,
                                    sessionId: session.id,
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
                                      repeatCount: entry.repeatCount,
                                    ),
                                  _TimelineEntryKind.planUpdated =>
                                    _PlanUpdateCard(
                                      event: entry.runtimeEvent!.event,
                                    ),
                                  _TimelineEntryKind.liveAssistant =>
                                    _LiveAssistantBubble(
                                      host: widget.host,
                                      api: widget.api,
                                      sessionId: session.id,
                                      message: _liveAssistantNotifier,
                                      onOpenFile: (path) =>
                                          unawaited(_openMessageResource(path)),
                                      onOpenHostUrl: _openHostUrl,
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
                              opacity: show ? AppEmphasis.full : 0,
                              duration: AppMotion.quick,
                              curve: AppMotion.standard,
                              child: _JumpToLatestPill(
                                onTap: () {
                                  if (!_scrollController.hasClients) {
                                    return;
                                  }
                                  _scrollController.animateTo(
                                    0,
                                    duration: AppMotion.reveal,
                                    curve: AppMotion.standard,
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
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.compact,
            ),
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
              enabled: !_loading && _snapshotError == null,
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
              modelAnchorKey: _modelPickerAnchor,
              thinkingAnchorKey: _thinkingPickerAnchor,
              modelLabel: showModelPicker ? _composerModelLabel(session) : null,
              modelDetail: showModelPicker
                  ? _composerModelDetail(session)
                  : null,
              onModelTap: showModelPicker
                  ? () => _showComposerModelPicker(session)
                  : null,
              thinkingLabel: showThinkingPicker
                  ? _composerThinkingLabel(session)
                  : null,
              thinkingDetail: showThinkingPicker
                  ? _composerThinkingDetail(session)
                  : null,
              onThinkingTap: showThinkingPicker
                  ? () => _showComposerThinkingPicker(session)
                  : null,
              submitOnEnter: widget.desktopMode,
            );
          },
        ),
      ],
    );
    final layoutBody = AppContentColumn(
      maxWidth: AppSizes.readingMaxWidth + AppSizes.mobileGutter * 2,
      child: bodyContent,
    );
    final inspectorScope = InspectorScope.maybeOf(context);
    final searchOpenInInspector =
        inspectorScope != null && _isSearchInspectorOpen(inspectorScope);
    final resourcesOpenInInspector = _isResourcesInspectorOpen(inspectorScope);
    final terminalOpenInInspector = _isTerminalInspectorOpen(inspectorScope);
    final browserOpenInInspector = _isBrowserInspectorOpen(inspectorScope);
    final browserOpen = browserOpenInInspector || _dockedBrowserPreview != null;
    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: !widget.desktopMode
            ? IconButton(
                tooltip: 'Back to sessions',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed:
                    widget.onReturnToSessionList ??
                    () => Navigator.of(context).maybePop(),
              )
            : null,
        titleSpacing: widget.desktopMode ? 16 : null,
        toolbarHeight: AppSizes.sessionToolbar,
        title: widget.desktopMode
            ? _DesktopSessionTitle(
                session: session,
                host: widget.host,
                running: _running,
                verifying: _verifyingVisibleSnapshot,
              )
            : Row(
                children: [
                  if (_running) ...[
                    const LivePulse(),
                    const SizedBox(width: AppSpacing.compact),
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
                                const SizedBox(width: AppSpacing.xs),
                                Icon(
                                  Icons.edit_rounded,
                                  size: AppSizes.smallIcon,
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
          // Non-compact mobile toolbar: Stop (when running) + Tune + overflow.
          // All tool launchers (terminal, browser, search, resources, git,
          // reload, new session) live in the overflow sheet only.
          if (!isCompact && !widget.desktopMode && _supportsSessionInterrupt)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: AnimatedOpacity(
                duration: AppMotion.reveal,
                opacity: _running ? AppEmphasis.full : AppEmphasis.muted,
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
              padding: const EdgeInsets.only(right: AppSpacing.compact),
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
                    icon: Icons.tune_rounded,
                    tooltip: 'Session settings',
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
                        icon: Icons.more_vert_rounded,
                        tooltip: _running
                            ? 'Session actions (agent running)'
                            : 'Session actions',
                        framed: false,
                        color: _running ? colors.warning : colors.textPrimary,
                        onTap: () => unawaited(
                          _showSessionActionsSheet(
                            session: session,
                            favorite: favorite,
                            gitAvailable: gitAvailable,
                            gitDirty: gitDirty,
                            terminalOpen: terminalOpenInInspector,
                            browserOpen: browserOpen,
                            searchOpen: searchOpenInInspector,
                            resourcesOpen: resourcesOpenInInspector,
                            includeControls: true,
                            controlsCustomized: sessionControlsCustomized,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              if (widget.desktopMode) {
                final groups = _sessionActionGroups(
                  favorite: favorite,
                  gitAvailable: menuGitAvailable,
                  gitDirty: gitDirty,
                  terminalOpen: terminalOpenInInspector,
                  browserOpen: browserOpen,
                  searchOpen: searchOpenInInspector,
                  resourcesOpen: resourcesOpenInInspector,
                  includeStop: false,
                  includeControls: true,
                  controlsCustomized: sessionControlsCustomized,
                );
                Widget menuItem(_SessionActionSpec action) => AppMenuItem(
                  label: action.label,
                  leadingIcon: action.icon,
                  foregroundColor: action.tone == _SessionActionTone.danger
                      ? colors.danger
                      : null,
                  onPressed: () => _handleSessionAction(action.value, session),
                );
                List<Widget> items(bool tools) => [
                  for (final group in groups.where(
                    (group) => (group.label == 'Open') == tools,
                  )) ...[
                    if (group.label == 'Troubleshooting')
                      SubmenuButton(
                        menuChildren: group.actions.map(menuItem).toList(),
                        child: const Text('Troubleshooting'),
                      )
                    else ...[
                      if (group.label == 'Manage') const Divider(height: 9),
                      ...group.actions.map(menuItem),
                    ],
                  ],
                ];
                return Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.compact),
                  child: _DesktopSessionCommandBar(
                    running: _running,
                    canStop: _supportsSessionInterrupt,
                    onStop: _stopSession,
                    onClose: widget.onClose,
                    tools: items(true),
                    actions: items(false),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.compact),
                child: MeshIconButton(
                  icon: Icons.more_horiz_rounded,
                  tooltip: _running
                      ? 'Session actions (agent running)'
                      : 'Session actions',
                  color: colors.textSecondary,
                  onTap: () => unawaited(
                    _showSessionActionsSheet(
                      session: session,
                      favorite: favorite,
                      gitAvailable: menuGitAvailable,
                      gitDirty: gitDirty,
                      terminalOpen: terminalOpenInInspector,
                      browserOpen: browserOpen,
                      searchOpen: searchOpenInInspector,
                      resourcesOpen: resourcesOpenInInspector,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: AppSpacing.xs),
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
