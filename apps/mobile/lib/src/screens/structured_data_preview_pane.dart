import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/mesh_widgets.dart';
import '../app_icons.dart';

enum StructuredDataFormat { json, yaml }

extension StructuredDataFormatLabel on StructuredDataFormat {
  String get label => switch (this) {
    StructuredDataFormat.json => 'JSON',
    StructuredDataFormat.yaml => 'YAML',
  };
}

StructuredDataFormat? structuredDataFormatForFile(
  String path,
  String? mimeHint,
) {
  final lowerPath = path.toLowerCase();
  if (lowerPath.endsWith('.json')) return StructuredDataFormat.json;
  if (lowerPath.endsWith('.yaml') || lowerPath.endsWith('.yml')) {
    return StructuredDataFormat.yaml;
  }

  final lowerMime = (mimeHint ?? '').trim().toLowerCase();
  if (lowerMime.contains('json')) return StructuredDataFormat.json;
  if (lowerMime.contains('yaml') || lowerMime.contains('yml')) {
    return StructuredDataFormat.yaml;
  }
  return null;
}

class StructuredDataPreviewPane extends StatelessWidget {
  const StructuredDataPreviewPane({
    super.key,
    required this.format,
    required this.contents,
    this.dense = false,
  });

  final StructuredDataFormat format;
  final String contents;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final result = _parseStructuredDataPreview(format, contents);
    final document = result.document;
    final body = switch (result.state) {
      _StructuredPreviewState.ready when document != null =>
        _StructuredTreeBody(root: document.root, dense: dense),
      _StructuredPreviewState.empty => MeshEmptyState.compact(
        icon: AppIcons.data_object_rounded,
        title: 'Empty ${format.label} file',
        body: 'There is no structured data to preview yet.',
      ),
      _StructuredPreviewState.error => MeshEmptyState.compact(
        icon: AppIcons.error_outline_rounded,
        title: 'Could not parse ${format.label}',
        body:
            '${result.message ?? 'This file is not valid ${format.label}.'} The raw text view is still available.',
      ),
      _ => const SizedBox.shrink(),
    };

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StructuredPreviewHeader(
            format: format,
            document: document,
            state: result.state,
            dense: dense,
          ),
          Divider(height: 1, color: colors.border),
          body,
        ],
      ),
    );
  }
}

enum _StructuredPreviewState { ready, empty, error }

class _StructuredPreviewResult {
  const _StructuredPreviewResult._({
    required this.state,
    this.document,
    this.message,
  });

  const _StructuredPreviewResult.ready(_StructuredDocument document)
    : this._(state: _StructuredPreviewState.ready, document: document);

  const _StructuredPreviewResult.empty()
    : this._(state: _StructuredPreviewState.empty);

  const _StructuredPreviewResult.error(String message)
    : this._(state: _StructuredPreviewState.error, message: message);

  final _StructuredPreviewState state;
  final _StructuredDocument? document;
  final String? message;
}

class _StructuredDocument {
  const _StructuredDocument({required this.root});

  final StructuredDataNode root;
}

sealed class StructuredDataNode {
  const StructuredDataNode();
}

class StructuredDataMapNode extends StructuredDataNode {
  const StructuredDataMapNode(this.entries);

  final List<StructuredDataMapEntry> entries;
}

class StructuredDataListNode extends StructuredDataNode {
  const StructuredDataListNode(this.items);

  final List<StructuredDataNode> items;
}

class StructuredDataScalarNode extends StructuredDataNode {
  const StructuredDataScalarNode(this.value);

  final Object? value;
}

class StructuredDataMapEntry {
  const StructuredDataMapEntry({required this.label, required this.value});

  final String label;
  final StructuredDataNode value;
}

_StructuredPreviewResult _parseStructuredDataPreview(
  StructuredDataFormat format,
  String contents,
) {
  if (contents.trim().isEmpty) {
    return const _StructuredPreviewResult.empty();
  }

  try {
    final value = switch (format) {
      StructuredDataFormat.json => jsonDecode(contents),
      StructuredDataFormat.yaml => loadYaml(contents),
    };
    return _StructuredPreviewResult.ready(
      _StructuredDocument(root: _nodeFromDynamic(value)),
    );
  } on YamlException catch (error) {
    return _StructuredPreviewResult.error(_formatYamlError(error));
  } on FormatException catch (error) {
    return _StructuredPreviewResult.error(_formatJsonError(error));
  } catch (error) {
    return _StructuredPreviewResult.error(error.toString());
  }
}

StructuredDataNode _nodeFromDynamic(Object? value) {
  if (value is YamlMap) {
    return StructuredDataMapNode(
      value.entries
          .map(
            (entry) => StructuredDataMapEntry(
              label: _mapKeyLabel(entry.key),
              value: _nodeFromDynamic(entry.value),
            ),
          )
          .toList(growable: false),
    );
  }
  if (value is Map) {
    return StructuredDataMapNode(
      value.entries
          .map(
            (entry) => StructuredDataMapEntry(
              label: _mapKeyLabel(entry.key),
              value: _nodeFromDynamic(entry.value),
            ),
          )
          .toList(growable: false),
    );
  }
  if (value is YamlList) {
    return StructuredDataListNode(
      value.map(_nodeFromDynamic).toList(growable: false),
    );
  }
  if (value is List) {
    return StructuredDataListNode(
      value.map(_nodeFromDynamic).toList(growable: false),
    );
  }
  if (value is DateTime) {
    return StructuredDataScalarNode(value.toIso8601String());
  }
  return StructuredDataScalarNode(value);
}

String _mapKeyLabel(Object? key) {
  if (key == null) return 'null';
  if (key is DateTime) return key.toIso8601String();
  final text = key.toString();
  return text.isEmpty ? '""' : text;
}

String _formatJsonError(FormatException error) {
  final message = error.message.trim();
  if (message.isNotEmpty) return message;
  return 'This file is not valid JSON.';
}

String _formatYamlError(YamlException error) {
  final message = error.toString().trim();
  if (message.startsWith('YamlException: ')) {
    return message.substring('YamlException: '.length);
  }
  return message.isEmpty ? 'This file is not valid YAML.' : message;
}

class _StructuredPreviewHeader extends StatelessWidget {
  const _StructuredPreviewHeader({
    required this.format,
    required this.document,
    required this.state,
    required this.dense,
  });

  final StructuredDataFormat format;
  final _StructuredDocument? document;
  final _StructuredPreviewState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final root = document?.root;
    final title = '${format.label} structure';
    final subtitle = switch (state) {
      _StructuredPreviewState.ready when root != null =>
        '${_nodeKindLabel(root)} • ${_nodeSummary(root)}',
      _StructuredPreviewState.empty => 'empty file',
      _StructuredPreviewState.error => 'parse error',
      _ => '',
    };

    return Padding(
      padding: dense
          ? const EdgeInsets.fromLTRB(12, 12, 12, 10)
          : const EdgeInsets.fromLTRB(14, 14, 14, 12),
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
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StructuredTypeChip(label: subtitle),
              if (root != null && !_isScalarNode(root))
                Text(
                  'Expand rows to inspect nested values.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StructuredTreeBody extends StatelessWidget {
  const _StructuredTreeBody({required this.root, required this.dense});

  final StructuredDataNode root;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final children = _childrenForNode(root);
    if (children.isEmpty) {
      return MeshEmptyState.compact(
        icon: AppIcons.account_tree_rounded,
        title: 'No entries here',
        body: 'This ${_nodeKindLabel(root)} does not contain any values yet.',
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 4 : 6),
      child: _StructuredChildList(children: children, depth: 0, dense: dense),
    );
  }
}

List<MapEntry<String, StructuredDataNode>> _childrenForNode(
  StructuredDataNode node,
) {
  if (node is StructuredDataMapNode) {
    return node.entries
        .map(
          (entry) =>
              MapEntry<String, StructuredDataNode>(entry.label, entry.value),
        )
        .toList(growable: false);
  }
  if (node is StructuredDataListNode) {
    return List<MapEntry<String, StructuredDataNode>>.generate(
      node.items.length,
      (index) =>
          MapEntry<String, StructuredDataNode>('[$index]', node.items[index]),
      growable: false,
    );
  }
  return <MapEntry<String, StructuredDataNode>>[
    MapEntry<String, StructuredDataNode>('root', node),
  ];
}

bool _isScalarNode(StructuredDataNode node) => node is StructuredDataScalarNode;

String _nodeKindLabel(StructuredDataNode node) {
  if (node is StructuredDataMapNode) return 'object';
  if (node is StructuredDataListNode) return 'list';
  return 'value';
}

String _nodeSummary(StructuredDataNode node) {
  if (node is StructuredDataMapNode) {
    final count = node.entries.length;
    if (count == 0) return 'empty object';
    return '$count ${count == 1 ? 'key' : 'keys'}';
  }
  if (node is StructuredDataListNode) {
    final count = node.items.length;
    if (count == 0) return 'empty list';
    return '$count ${count == 1 ? 'item' : 'items'}';
  }
  return _scalarKindLabel((node as StructuredDataScalarNode).value);
}

String _scalarKindLabel(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return 'boolean';
  if (value is num) return 'number';
  if (value is String) return 'string';
  return 'value';
}

String _scalarValueLabel(Object? value) {
  if (value == null) return 'null';
  if (value is String) {
    return value.isEmpty ? '(empty string)' : value;
  }
  return value.toString();
}

double _rowInset(int depth, bool dense) => (dense ? 12 : 14) + (depth * 18);

class _StructuredChildList extends StatelessWidget {
  const _StructuredChildList({
    required this.children,
    required this.depth,
    required this.dense,
  });

  final List<MapEntry<String, StructuredDataNode>> children;
  final int depth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0)
            Divider(
              height: 1,
              indent: _rowInset(depth, dense),
              color: colors.border,
            ),
          _StructuredNodeTile(
            label: children[index].key,
            node: children[index].value,
            depth: depth,
            dense: dense,
          ),
        ],
      ],
    );
  }
}

class _StructuredNodeTile extends StatelessWidget {
  const _StructuredNodeTile({
    required this.label,
    required this.node,
    required this.depth,
    required this.dense,
  });

  final String label;
  final StructuredDataNode node;
  final int depth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (node is StructuredDataMapNode) {
      final mapNode = node as StructuredDataMapNode;
      if (mapNode.entries.isEmpty) {
        return _StructuredSummaryTile(
          label: label,
          summary: 'empty object',
          kind: 'object',
          depth: depth,
          dense: dense,
        );
      }
      return _StructuredBranchTile(
        label: label,
        node: mapNode,
        depth: depth,
        dense: dense,
      );
    }
    if (node is StructuredDataListNode) {
      final listNode = node as StructuredDataListNode;
      if (listNode.items.isEmpty) {
        return _StructuredSummaryTile(
          label: label,
          summary: 'empty list',
          kind: 'list',
          depth: depth,
          dense: dense,
        );
      }
      return _StructuredBranchTile(
        label: label,
        node: listNode,
        depth: depth,
        dense: dense,
      );
    }
    return _StructuredScalarTile(
      label: label,
      value: (node as StructuredDataScalarNode).value,
      depth: depth,
      dense: dense,
    );
  }
}

class _StructuredBranchTile extends StatelessWidget {
  const _StructuredBranchTile({
    required this.label,
    required this.node,
    required this.depth,
    required this.dense,
  });

  final String label;
  final StructuredDataNode node;
  final int depth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.fromLTRB(
          _rowInset(depth, dense),
          dense ? 6 : 8,
          12,
          dense ? 6 : 8,
        ),
        childrenPadding: EdgeInsets.only(bottom: dense ? 4 : 6),
        visualDensity: VisualDensity.compact,
        iconColor: colors.textSecondary,
        collapsedIconColor: colors.textSecondary,
        title: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: AppWeights.emphasis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _StructuredTypeChip(label: _nodeKindLabel(node)),
          ],
        ),
        subtitle: Text(
          _nodeSummary(node),
          style: monoStyle(color: colors.textSecondary, fontSize: 10.5),
        ),
        children: [
          _StructuredChildList(
            children: _childrenForNode(node),
            depth: depth + 1,
            dense: dense,
          ),
        ],
      ),
    );
  }
}

class _StructuredSummaryTile extends StatelessWidget {
  const _StructuredSummaryTile({
    required this.label,
    required this.summary,
    required this.kind,
    required this.depth,
    required this.dense,
  });

  final String label;
  final String summary;
  final String kind;
  final int depth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _rowInset(depth, dense),
        dense ? 10 : 12,
        12,
        dense ? 10 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StructuredTypeChip(label: kind),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            summary,
            style: monoStyle(color: colors.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _StructuredScalarTile extends StatelessWidget {
  const _StructuredScalarTile({
    required this.label,
    required this.value,
    required this.depth,
    required this.dense,
  });

  final String label;
  final Object? value;
  final int depth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final displayValue = _scalarValueLabel(value);
    final isEmpty = displayValue == 'null' || displayValue == '(empty string)';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _rowInset(depth, dense),
        dense ? 10 : 12,
        12,
        dense ? 10 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StructuredTypeChip(label: _scalarKindLabel(value)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            displayValue,
            style: monoStyle(
              color: isEmpty ? colors.textSecondary : colors.textPrimary,
              fontSize: 12.5,
            ).copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _StructuredTypeChip extends StatelessWidget {
  const _StructuredTypeChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadii.badge),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: monoStyle(
          color: colors.textSecondary,
          fontSize: 10.5,
          fontWeight: AppWeights.emphasis,
        ),
      ),
    );
  }
}
