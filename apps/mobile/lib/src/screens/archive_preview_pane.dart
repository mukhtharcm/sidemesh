import 'package:archive/archive.dart';
import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/mesh_widgets.dart';

const int archivePreviewMaxArchiveBytes = 16 * 1024 * 1024;
const int archivePreviewMaxEntries = 200;

class ArchivePreviewEntry {
  const ArchivePreviewEntry({
    required this.path,
    required this.isDirectory,
    required this.isSymbolicLink,
    required this.size,
  });

  final String path;
  final bool isDirectory;
  final bool isSymbolicLink;
  final int size;
}

class ArchivePreviewData {
  const ArchivePreviewData({
    required this.entries,
    required this.totalEntries,
    required this.directoryCount,
    required this.fileCount,
    required this.symbolicLinkCount,
    required this.totalUncompressedBytes,
  });

  final List<ArchivePreviewEntry> entries;
  final int totalEntries;
  final int directoryCount;
  final int fileCount;
  final int symbolicLinkCount;
  final int totalUncompressedBytes;

  int get displayedEntries => entries.length;
  int get hiddenEntryCount => totalEntries - displayedEntries;
  bool get truncated => hiddenEntryCount > 0;
}

bool looksLikeZipArchiveFile(String path, String? mimeHint) {
  final lowerPath = path.toLowerCase();
  if (lowerPath.endsWith('.zip')) {
    return true;
  }
  final mime = (mimeHint ?? '').trim().toLowerCase();
  return mime == 'application/zip' ||
      mime == 'application/x-zip-compressed' ||
      mime == 'multipart/x-zip';
}

ArchivePreviewData parseZipArchivePreview(
  List<int> bytes, {
  int maxEntries = archivePreviewMaxEntries,
}) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final files = List<ArchiveFile>.from(archive.files)
    ..sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
  final entries = <ArchivePreviewEntry>[];
  var directoryCount = 0;
  var fileCount = 0;
  var symbolicLinkCount = 0;
  var totalUncompressedBytes = 0;

  for (final file in files) {
    final isDirectory = !file.isFile && !file.isSymbolicLink;
    if (isDirectory) {
      directoryCount++;
    } else if (file.isSymbolicLink) {
      symbolicLinkCount++;
    } else {
      fileCount++;
      totalUncompressedBytes += file.size < 0 ? 0 : file.size;
    }

    if (entries.length >= maxEntries) {
      continue;
    }

    final name = file.name.trim().isEmpty ? '(unnamed entry)' : file.name;
    entries.add(
      ArchivePreviewEntry(
        path: name,
        isDirectory: isDirectory,
        isSymbolicLink: file.isSymbolicLink,
        size: file.size < 0 ? 0 : file.size,
      ),
    );
  }

  return ArchivePreviewData(
    entries: entries,
    totalEntries: files.length,
    directoryCount: directoryCount,
    fileCount: fileCount,
    symbolicLinkCount: symbolicLinkCount,
    totalUncompressedBytes: totalUncompressedBytes,
  );
}

class ArchivePreviewPane extends StatefulWidget {
  const ArchivePreviewPane({
    super.key,
    required this.host,
    required this.api,
    required this.path,
    required this.fileSize,
    required this.modifiedAtMs,
    this.agentProvider,
    this.sessionId,
    this.dense = false,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;
  final int fileSize;
  final int modifiedAtMs;
  final String? agentProvider;
  final String? sessionId;
  final bool dense;

  @override
  State<ArchivePreviewPane> createState() => _ArchivePreviewPaneState();
}

class _ArchivePreviewPaneState extends State<ArchivePreviewPane> {
  ArchivePreviewData? _preview;
  Object? _error;
  bool _loading = true;
  bool _skippedForSize = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ArchivePreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.fileSize != widget.fileSize ||
        oldWidget.modifiedAtMs != widget.modifiedAtMs) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _skippedForSize = false;
      _preview = null;
    });

    if (widget.fileSize > archivePreviewMaxArchiveBytes) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _skippedForSize = true;
      });
      return;
    }

    try {
      final bytes = await widget.api.fetchFsBlob(
        widget.host,
        widget.path,
        agentProvider: widget.agentProvider,
        sessionId: widget.sessionId,
      );
      final preview = parseZipArchivePreview(bytes);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return MeshLoader(label: 'Loading archive');
    }
    if (_skippedForSize) {
      return MeshEmptyState.compact(
        icon: Icons.archive_outlined,
        title: 'Archive preview skipped',
        body:
            'ZIP previews currently load archives up to ${_formatBytes(archivePreviewMaxArchiveBytes)}. This archive is ${_formatBytes(widget.fileSize)}.',
      );
    }
    if (_error != null) {
      return MeshEmptyState.compact(
        icon: Icons.archive_outlined,
        title: 'Could not preview archive',
        body: _archivePreviewErrorMessage(_error!),
        action: TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }

    final preview = _preview;
    if (preview == null || preview.totalEntries == 0) {
      return const MeshEmptyState.compact(
        icon: Icons.archive_outlined,
        title: 'Archive is empty',
      );
    }

    final colors = context.colors;
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: colors.textSecondary,
      fontWeight: AppWeights.body,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          [
            _countLabel(preview.fileCount, 'file'),
            _countLabel(preview.directoryCount, 'folder'),
            if (preview.symbolicLinkCount > 0)
              _countLabel(preview.symbolicLinkCount, 'link'),
            '${_formatBytes(preview.totalUncompressedBytes)} unpacked',
          ].join(' · '),
          style: subtitleStyle,
        ),
        if (preview.truncated) ...[
          const SizedBox(height: AppSpacing.sm),
          _ArchiveLimitBanner(
            dense: widget.dense,
            message:
                'Showing the first ${preview.displayedEntries} of ${preview.totalEntries} entries.',
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: MeshCard(
            tone: MeshCardTone.surface,
            padding: EdgeInsets.zero,
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.xs),
              itemCount: preview.entries.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: colors.border),
              itemBuilder: (context, index) {
                final entry = preview.entries[index];
                return MeshListRow(
                  key: ValueKey<String>('${index}_${entry.path}'),
                  dense: widget.dense,
                  framed: false,
                  leading: _ArchiveEntryIcon(entry: entry),
                  title: Text(
                    entry.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      color: colors.textPrimary,
                      fontSize: widget.dense
                          ? AppFontSizes.caption
                          : AppFontSizes.code,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                  meta: Text(
                    _archiveEntryMeta(entry),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  trailing: entry.isDirectory
                      ? null
                      : Text(
                          _formatBytes(entry.size),
                          style: monoStyle(
                            color: colors.textSecondary,
                            fontSize: AppFontSizes.caption,
                            fontWeight: AppWeights.emphasis,
                          ),
                        ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ArchiveEntryIcon extends StatelessWidget {
  const _ArchiveEntryIcon({required this.entry});

  final ArchivePreviewEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final icon = entry.isDirectory
        ? Icons.folder_rounded
        : entry.isSymbolicLink
        ? Icons.shortcut_rounded
        : Icons.insert_drive_file_rounded;
    final tint = entry.isDirectory
        ? colors.info
        : entry.isSymbolicLink
        ? colors.warning
        : colors.textSecondary;
    final fill = entry.isDirectory
        ? colors.infoMuted
        : entry.isSymbolicLink
        ? colors.warningMuted
        : colors.surfaceMuted;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: tint.withValues(alpha: AppEmphasis.soft)),
      ),
      child: Icon(icon, size: AppSizes.inlineIcon, color: tint),
    );
  }
}

class _ArchiveLimitBanner extends StatelessWidget {
  const _ArchiveLimitBanner({required this.message, required this.dense});

  final String message;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? AppSpacing.sm : AppSpacing.md,
        vertical: dense ? AppSpacing.sm : AppSpacing.compact,
      ),
      decoration: BoxDecoration(
        color: colors.warningMuted,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(
          color: colors.warning.withValues(alpha: AppEmphasis.borderTint),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: AppSizes.compactIcon,
            color: colors.warning,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

String _archiveEntryMeta(ArchivePreviewEntry entry) {
  if (entry.isDirectory) {
    return 'Folder';
  }
  if (entry.isSymbolicLink) {
    return 'Symbolic link';
  }
  return 'File';
}

String _archivePreviewErrorMessage(Object error) {
  if (error is ApiException ||
      error is ApiTimeoutException ||
      error.toString().contains('SocketException') ||
      error.toString().contains('TimeoutException')) {
    return friendlyError(error);
  }
  final raw = error.toString();
  final cleaned = raw
      .replaceFirst('ArchiveException: ', '')
      .replaceFirst('Exception: ', '')
      .trim();
  if (cleaned.isEmpty) {
    return 'This ZIP archive could not be previewed.';
  }
  if (cleaned.toLowerCase().contains('password') ||
      cleaned.toLowerCase().contains('encrypted')) {
    return 'This ZIP archive is encrypted and cannot be previewed here.';
  }
  return 'This ZIP archive could not be previewed: $cleaned';
}

String _countLabel(int count, String singular) {
  final plural = singular == 'entry' ? 'entries' : '${singular}s';
  return '$count ${count == 1 ? singular : plural}';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
