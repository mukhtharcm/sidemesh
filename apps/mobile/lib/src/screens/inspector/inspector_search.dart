import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
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
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.search,
    ownerKey: ownerKey,
    title: 'Search',
    icon: Icons.search_rounded,
    bodyBuilder: (context) {
      Widget buildPanel() => SearchPanel(
        controller: controller,
        focusNode: focusNode,
        records: recordsBuilder(),
        showDragHandle: false,
        showCloseButton: false,
      );
      if (refresh == null) return buildPanel();
      return ListenableBuilder(
        listenable: refresh,
        builder: (context, _) => buildPanel(),
      );
    },
  );
}

/// The search body — input pill, filter chips, and result list. Host
/// chrome (drag handle for bottom sheets, close button for the old
/// inline path) is opt-in via [showDragHandle] / [showCloseButton] so
/// the same widget can live inside the inspector pane or a sheet.
class SearchPanel extends StatefulWidget {
  const SearchPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.records,
    this.onClose,
    this.showDragHandle = false,
    this.showCloseButton = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<SearchRecord> records;
  final VoidCallback? onClose;
  final bool showDragHandle;
  final bool showCloseButton;

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
    final needle = _query.trim().toLowerCase();
    return widget.records.where((r) {
      final kindOk = switch (_filter) {
        _SearchFilter.all => true,
        _SearchFilter.messages => r.kind == SearchRecordKind.message,
        _SearchFilter.activities => r.kind == SearchRecordKind.activity,
      };
      if (!kindOk) return false;
      if (needle.isEmpty) return true;
      return r.haystack.contains(needle);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final results = _filteredRecords();
    final hasQuery = _query.trim().isNotEmpty;
    return Material(
      color: colors.canvas,
      shape: widget.showDragHandle
          ? const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showDragHandle)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: colors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      cursorColor: colors.accent,
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: 'Search transcript',
                        hintStyle: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 14,
                        ),
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.textPrimary,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                  if (hasQuery)
                    InkResponse(
                      radius: 16,
                      onTap: () {
                        widget.controller.clear();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  if (widget.showCloseButton) ...[
                    Container(
                      width: 1,
                      height: 18,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      color: colors.border,
                    ),
                    InkResponse(
                      radius: 18,
                      onTap: widget.onClose,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: Row(
              children: [
                _SearchFilterChip(
                  label: 'All',
                  selected: _filter == _SearchFilter.all,
                  onTap: () => setState(() => _filter = _SearchFilter.all),
                ),
                const SizedBox(width: 6),
                _SearchFilterChip(
                  label: 'Messages',
                  selected: _filter == _SearchFilter.messages,
                  onTap: () =>
                      setState(() => _filter = _SearchFilter.messages),
                ),
                const SizedBox(width: 6),
                _SearchFilterChip(
                  label: 'Activities',
                  selected: _filter == _SearchFilter.activities,
                  onTap: () =>
                      setState(() => _filter = _SearchFilter.activities),
                ),
                const Spacer(),
                Text(
                  hasQuery
                      ? '${results.length} match${results.length == 1 ? '' : 'es'}'
                      : '${results.length} entr${results.length == 1 ? 'y' : 'ies'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.border),
          Expanded(
            child: results.isEmpty
                ? _SearchPanelEmptyState(
                    query: _query.trim(),
                    totalRecords: widget.records.length,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: results.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: colors.border),
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
      ),
    );
  }
}

class _SearchFilterChip extends StatelessWidget {
  const _SearchFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.surfaceMuted,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? colors.accent : colors.border,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: selected ? colors.accentOn : colors.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchPanelEmptyState extends StatelessWidget {
  const _SearchPanelEmptyState({
    required this.query,
    required this.totalRecords,
  });

  final String query;
  final int totalRecords;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final hasQuery = query.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery ? Icons.search_off_rounded : Icons.search_rounded,
              color: colors.textTertiary,
              size: 36,
            ),
            const SizedBox(height: 10),
            Text(
              hasQuery
                  ? 'No matches for "$query"'
                  : 'Search messages and activities',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery
                  ? 'Try a different term or switch filter.'
                  : 'Searching $totalRecords loaded entries.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
              ),
            ),
          ],
        ),
      ),
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
    final snippet = _SnippetText(
      body: record.kind == SearchRecordKind.message
          ? record.message!.text
          : _activityPreviewBody(record.activity!),
      query: query,
    );
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    leadingIcon,
                    size: 16,
                    color: isMessage
                        ? (record.message!.role == 'user'
                              ? colors.accent
                              : colors.textSecondary)
                        : colors.textSecondary,
                  ),
                ),
                const SizedBox(width: 10),
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
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
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
                      const SizedBox(height: 4),
                      snippet,
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: colors.textTertiary,
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 10),
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
      height: 1.3,
    );
    final lowerBody = body.toLowerCase();
    final lowerQuery = query.toLowerCase();
    if (query.isEmpty || !lowerBody.contains(lowerQuery)) {
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
    final idx = lowerBody.indexOf(lowerQuery);
    const radius = 70;
    final start = (idx - radius).clamp(0, body.length);
    final end = (idx + query.length + radius).clamp(0, body.length);
    final leading = start > 0 ? '…' : '';
    final trailing = end < body.length ? '…' : '';
    final before = body.substring(start, idx).replaceAll('\n', ' ');
    final match = body.substring(idx, idx + query.length);
    final after = body
        .substring(idx + query.length, end)
        .replaceAll('\n', ' ');
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: '$leading$before'),
          TextSpan(
            text: match,
            style: baseStyle?.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w800,
              backgroundColor: colors.accent.withValues(alpha: 0.25),
            ),
          ),
          TextSpan(text: '$after$trailing'),
        ],
      ),
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
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border),
        ),
        child: SelectableText(
          message.text.isEmpty ? '—' : message.text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colors.textPrimary,
            height: 1.4,
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
          padding: const EdgeInsets.only(bottom: 4),
          child: RichText(
            text: TextSpan(
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
              ),
              children: [
                TextSpan(
                  text: '$label ',
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: monoStyle(color: colors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    addLine('type', activity.type);
    addLine('status', activity.status);
    if ((activity.command ?? '').isNotEmpty) {
      addLine('command', activity.command!);
    }
    if ((activity.toolName ?? '').isNotEmpty) {
      addLine('tool', activity.toolName!);
    }
    if ((activity.toolTitle ?? '').isNotEmpty) {
      addLine('title', activity.toolTitle!);
    }
    if ((activity.toolCategory ?? '').isNotEmpty) {
      addLine('tool category', activity.toolCategory!);
    }
    if ((activity.toolAction ?? '').isNotEmpty) {
      addLine('tool action', activity.toolAction!);
    }
    if ((activity.toolTarget ?? '').isNotEmpty) {
      addLine('tool target', activity.toolTarget!);
    }
    if (activity.toolTargets.isNotEmpty) {
      addLine('tool targets', activity.toolTargets.join('\n  '));
    }
    if ((activity.toolUrl ?? '').isNotEmpty) {
      addLine('tool url', activity.toolUrl!);
    }
    if ((activity.toolQuery ?? '').isNotEmpty) {
      addLine('tool query', activity.toolQuery!);
    }
    if ((activity.toolMode ?? '').isNotEmpty) {
      addLine('tool mode', activity.toolMode!);
    }
    if ((activity.cwd ?? '').isNotEmpty) addLine('cwd', activity.cwd!);
    if ((activity.query ?? '').isNotEmpty) addLine('query', activity.query!);
    if (activity.queries.isNotEmpty) {
      addLine('queries', activity.queries.join(' · '));
    }
    if ((activity.targetUrl ?? '').isNotEmpty) {
      addLine('url', activity.targetUrl!);
    }
    if ((activity.savedPath ?? '').isNotEmpty) {
      addLine('saved', activity.savedPath!);
    }
    if (activity.changes.isNotEmpty) {
      addLine(
        'paths',
        activity.changes.map((c) => c.path).join('\n  '),
      );
    }
    final output = (activity.output ?? '').trim();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...meta,
          if (output.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border),
              ),
              child: SelectableText(
                output.length > 4000
                    ? '…${output.substring(output.length - 4000)}'
                    : output,
                style: monoStyle(color: colors.textPrimary, fontSize: 12),
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
