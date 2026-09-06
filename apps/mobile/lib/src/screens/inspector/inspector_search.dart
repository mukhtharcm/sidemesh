import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../search_query.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_tokens.dart';
import '../../theme/app_control_styles.dart';
import '../../widgets/mesh_widgets.dart';
import 'inspector_controller.dart';

enum SearchRecordKind { message, activity }

class SearchRecord {
  SearchRecord({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.haystack,
    required this.title,
    this.message,
    this.activity,
    this.sessionCwd,
  });

  final String id;
  final SearchRecordKind kind;
  final DateTime createdAt;
  final String haystack;
  final String title;
  final SessionMessage? message;
  final SessionActivity? activity;
  final String? sessionCwd;
}

/// Builds an [InspectorSurface] that hosts the search panel in pane 3.
///
/// [recordsBuilder] is invoked every time the surface rebuilds so fresh
/// transcript data is picked up without needing to re-open the surface.
InspectorSurface buildInspectorSearchSurface({
  required String ownerKey,
  required TextEditingController controller,
  required FocusNode focusNode,
  required List<SearchRecord> Function() recordsBuilder,
  Listenable? refresh,
  bool Function()? loadingBuilder,
  String? Function()? errorBuilder,
  VoidCallback? onRetry,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.search,
    ownerKey: ownerKey,
    title: 'Search',
    icon: Icons.search_rounded,
    bodyBuilder: (context) {
      Widget buildPanel() => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: SearchPanel(
          controller: controller,
          focusNode: focusNode,
          records: recordsBuilder(),
          loading: loadingBuilder?.call() ?? false,
          error: errorBuilder?.call(),
          onRetry: onRetry,
        ),
      );
      if (refresh == null) return buildPanel();
      return ListenableBuilder(
        listenable: refresh,
        builder: (context, _) => buildPanel(),
      );
    },
  );
}

/// Search content shared by the mobile sheet and desktop inspector.
class SearchPanel extends StatefulWidget {
  const SearchPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.records,
    this.loading = false,
    this.error,
    this.onRetry,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<SearchRecord> records;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

enum _SearchFilter { all, messages, activities }

class _SearchPanelState extends State<SearchPanel> {
  _SearchFilter _filter = _SearchFilter.all;
  String _query = '';
  Timer? _debounce;
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _query = widget.controller.text;
    widget.controller.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onQueryChanged);
    super.dispose();
  }

  void _onQueryChanged() {
    final text = widget.controller.text;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (text == _query) return;
      setState(() => _query = text);
    });
  }

  List<SearchRecord> _filteredRecords() {
    return widget.records
        .where((r) {
          final kindOk = switch (_filter) {
            _SearchFilter.all => true,
            _SearchFilter.messages => r.kind == SearchRecordKind.message,
            _SearchFilter.activities => r.kind == SearchRecordKind.activity,
          };
          if (!kindOk) return false;
          return matchesSearchQuery(r.haystack, _query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final results = _filteredRecords();
    final hasQuery = _query.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: AppControlStyles.searchText(context),
          decoration: AppControlStyles.search(context).copyWith(
            hintText: 'Search messages and actions',
            suffixIcon: widget.controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: widget.controller.clear,
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
        if (widget.records.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_SearchFilter>(
              segments: const [
                ButtonSegment(value: _SearchFilter.all, label: Text('All')),
                ButtonSegment(
                  value: _SearchFilter.messages,
                  label: Text('Messages'),
                ),
                ButtonSegment(
                  value: _SearchFilter.activities,
                  label: Text('Actions'),
                ),
              ],
              selected: {_filter},
              showSelectedIcon: false,
              onSelectionChanged: (values) =>
                  setState(() => _filter = values.single),
            ),
          ),
        ],
        if (hasQuery && results.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            '${results.length} match${results.length == 1 ? '' : 'es'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Expanded(
          child: widget.records.isEmpty && widget.loading
              ? const MeshLoader(label: 'Loading conversation')
              : widget.records.isEmpty && widget.error != null
              ? MeshEmptyState.compact(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load conversation',
                  body: widget.error!,
                  action: widget.onRetry == null
                      ? null
                      : TextButton(
                          onPressed: widget.onRetry,
                          child: const Text('Retry'),
                        ),
                )
              : !hasQuery || results.isEmpty
              ? Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xl,
                    ),
                    child: Text(
                      widget.records.isEmpty
                          ? 'No messages or actions to search yet.'
                          : hasQuery
                          ? 'No matches. Try another word or filter.'
                          : 'Type to search this conversation.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: results.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: AppStrokes.border, color: colors.border),
                  itemBuilder: (context, index) {
                    final record = results[index];
                    return _SearchResultRow(
                      record: record,
                      query: _query.trim(),
                      expanded: _expanded.contains(record.id),
                      onToggle: () {
                        setState(() {
                          if (!_expanded.add(record.id)) {
                            _expanded.remove(record.id);
                          }
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({
    required this.record,
    required this.query,
    required this.expanded,
    required this.onToggle,
  });

  final SearchRecord record;
  final String query;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final isMessage = record.kind == SearchRecordKind.message;
    final leadingIcon = isMessage
        ? (record.message!.role == 'user'
              ? Icons.person_outline_rounded
              : Icons.auto_awesome_rounded)
        : _iconForActivity(record.activity!.type);
    final preview = record.kind == SearchRecordKind.message
        ? record.message!.text
        : _activityPreviewBody(record.activity!);
    final snippet = _SnippetText(
      body: searchQueryMatchRanges(preview, query).isEmpty
          ? record.haystack
          : preview,
      query: query,
    );
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: AppShapes.iconWell,
                  ),
                  child: Icon(
                    leadingIcon,
                    size: AppSizes.compactIcon,
                    color: isMessage
                        ? (record.message!.role == 'user'
                              ? colors.accent
                              : colors.textSecondary)
                        : colors.textSecondary,
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              record.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: AppWeights.emphasis,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            _formatRecordTime(record.createdAt),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.textTertiary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      snippet,
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: AppSizes.inlineIcon,
                  color: colors.textTertiary,
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: AppSpacing.compact),
              _SearchResultExpanded(record: record, query: query),
            ],
          ],
        ),
      ),
    );
  }
}

class _SnippetText extends StatelessWidget {
  const _SnippetText({required this.body, required this.query});

  final String body;
  final String query;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final baseStyle = theme.textTheme.bodySmall?.copyWith(
      color: colors.textSecondary,
      height: AppLineHeights.label,
    );
    final matches = searchQueryMatchRanges(body, query);
    if (matches.isEmpty) {
      final oneLine = body.replaceAll('\n', ' ').trim();
      final clipped = oneLine.length > 140
          ? '${oneLine.substring(0, 140)}…'
          : oneLine;
      return Text(
        clipped.isEmpty ? '—' : clipped,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }
    final focus = matches.first;
    const radius = 70;
    final start = (focus.start - radius).clamp(0, body.length);
    final end = (focus.end + radius).clamp(0, body.length);
    final snippet = body.substring(start, end).replaceAll('\n', ' ');
    final visibleMatches = matches
        .where((match) => match.end > start && match.start < end)
        .map(
          (match) => SearchQueryMatchRange(
            (match.start - start).clamp(0, snippet.length),
            (match.end - start).clamp(0, snippet.length),
          ),
        )
        .where((match) => match.end > match.start)
        .toList(growable: false);
    final spans = <TextSpan>[];
    if (start > 0) {
      spans.add(const TextSpan(text: '…'));
    }
    var cursor = 0;
    for (final match in visibleMatches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: snippet.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: snippet.substring(match.start, match.end),
          style: baseStyle?.copyWith(
            color: colors.textPrimary,
            fontWeight: AppWeights.title,
            backgroundColor: colors.accent.withValues(
              alpha: AppEmphasis.borderTint,
            ),
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < snippet.length) {
      spans.add(TextSpan(text: snippet.substring(cursor)));
    }
    if (end < body.length) {
      spans.add(const TextSpan(text: '…'));
    }
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: baseStyle, children: spans),
    );
  }
}

class _SearchResultExpanded extends StatelessWidget {
  const _SearchResultExpanded({required this.record, required this.query});

  final SearchRecord record;
  final String query;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (record.kind == SearchRecordKind.message) {
      final message = record.message!;
      return Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppShapes.panel,
          border: Border.all(color: colors.border),
        ),
        child: SelectableText(
          message.text.isEmpty ? '—' : message.text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colors.textPrimary,
            height: AppLineHeights.body,
          ),
        ),
      );
    }
    final activity = record.activity!;
    final meta = <Widget>[];
    void addLine(String label, String value) {
      if (value.trim().isEmpty) return;
      meta.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: RichText(
            text: TextSpan(
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              children: [
                TextSpan(
                  text: '$label ',
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: AppFontSizes.caption,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    addLine('Kind', _friendlyActivityType(activity.type));
    addLine('Status', activity.status);
    if ((activity.command ?? '').isNotEmpty) {
      addLine('Command', activity.command!);
    }
    if ((activity.toolName ?? '').isNotEmpty) {
      addLine('Tool', activity.toolName!);
    }
    if ((activity.toolTitle ?? '').isNotEmpty) {
      addLine('Title', activity.toolTitle!);
    }
    if ((activity.toolCategory ?? '').isNotEmpty) {
      addLine('Group', activity.toolCategory!);
    }
    if ((activity.toolAction ?? '').isNotEmpty) {
      addLine('Action', activity.toolAction!);
    }
    if ((activity.toolTarget ?? '').isNotEmpty) {
      addLine('Target', activity.toolTarget!);
    }
    if (activity.toolTargets.isNotEmpty) {
      addLine('Targets', activity.toolTargets.join('\n  '));
    }
    if ((activity.toolUrl ?? '').isNotEmpty) {
      addLine('Link', activity.toolUrl!);
    }
    if ((activity.toolQuery ?? '').isNotEmpty) {
      addLine('Search', activity.toolQuery!);
    }
    if ((activity.toolMode ?? '').isNotEmpty) {
      addLine('Mode', activity.toolMode!);
    }
    if ((activity.cwd ?? '').isNotEmpty) addLine('Folder', activity.cwd!);
    if ((activity.query ?? '').isNotEmpty) addLine('Query', activity.query!);
    if (activity.queries.isNotEmpty) {
      addLine('Queries', activity.queries.join(' · '));
    }
    if ((activity.targetUrl ?? '').isNotEmpty) {
      addLine('Page', activity.targetUrl!);
    }
    if ((activity.savedPath ?? '').isNotEmpty) {
      addLine('Saved file', activity.savedPath!);
    }
    if (activity.changes.isNotEmpty) {
      addLine('Files', activity.changes.map((c) => c.path).join('\n  '));
    }
    final output = (activity.output ?? '').trim();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.panel,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...meta,
          if (output.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.tight),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: AppShapes.iconWell,
                border: Border.all(color: colors.border),
              ),
              child: SelectableText(
                output.length > 4000
                    ? '…${output.substring(output.length - 4000)}'
                    : output,
                style: monoStyle(
                  color: colors.textPrimary,
                  fontSize: AppFontSizes.caption,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

IconData _iconForActivity(String type) {
  switch (type) {
    case 'command':
      return Icons.terminal_rounded;
    case 'tool':
      return Icons.extension_rounded;
    case 'file_change':
      return Icons.edit_note_rounded;
    case 'turn_diff':
      return Icons.difference_rounded;
    case 'web_search':
      return Icons.travel_explore_rounded;
    case 'image_generation':
      return Icons.image_rounded;
    default:
      return Icons.bolt_rounded;
  }
}

String _friendlyActivityType(String type) {
  return switch (type) {
    'command' => 'Command',
    'tool' => 'Tool',
    'file_change' => 'File change',
    'turn_diff' => 'Changes',
    'web_search' => 'Web search',
    'image_generation' => 'Image',
    _ => type.replaceAll('_', ' '),
  };
}

String _activityPreviewBody(SessionActivity activity) {
  switch (activity.type) {
    case 'command':
      final out = (activity.output ?? '').trim();
      return out.isEmpty ? (activity.command ?? '') : out;
    case 'tool':
      final out = (activity.output ?? '').trim();
      if (out.isNotEmpty) return out;
      return [
        if ((activity.toolTitle ?? '').isNotEmpty) activity.toolTitle!,
        if ((activity.toolName ?? '').isNotEmpty) activity.toolName!,
      ].join('\n');
    case 'file_change':
      return activity.changes.map((c) => c.path).join('\n');
    case 'turn_diff':
      return activity.changes.map((c) => c.path).join('\n');
    case 'web_search':
      return [
        if ((activity.query ?? '').isNotEmpty) activity.query!,
        ...activity.queries,
        if ((activity.targetUrl ?? '').isNotEmpty) activity.targetUrl!,
      ].join('\n');
    case 'image_generation':
      return activity.savedPath ?? '';
    default:
      return (activity.output ?? activity.command ?? '').trim();
  }
}

String _formatRecordTime(DateTime value) {
  final now = DateTime.now();
  final time =
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  if (_sameCalendarDay(value, now)) return time;
  final diffDays = now.difference(value).inDays;
  if (diffDays < 7 && diffDays >= 0) {
    return '${_weekdayShort(value.weekday)} · $time';
  }
  if (value.year == now.year) {
    return '${_monthShort(value.month)} ${value.day} · $time';
  }
  return '${_monthShort(value.month)} ${value.day} ${value.year}';
}

bool _sameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _weekdayShort(int w) {
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return names[(w - 1).clamp(0, 6)];
}

String _monthShort(int m) {
  const names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return names[(m - 1).clamp(0, 11)];
}
