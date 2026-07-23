part of 'session_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// _Composer
// Three-zone layout:
//   Zone 3 — Suggestion trays (skill / file, above the shelf, animated in/out)
//   Zone 2 — Context shelf   (chips: images, skills, files – horizontal scroll)
//   Zone 1 — The bar          (text field | toolbar with context/model/send)
// ─────────────────────────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.attachments,
    required this.skills,
    required this.files,
    required this.activeSkillQuery,
    required this.skillSuggestions,
    required this.loadingSkills,
    required this.skillError,
    required this.activeFileQuery,
    required this.fileSuggestions,
    required this.loadingFileSearch,
    required this.fileError,
    required this.sending,
    required this.supportsImageInput,
    required this.supportsSkillInput,
    required this.supportsFileMentions,
    required this.onPickImages,
    required this.onNativePaste,
    required this.onRemoveAttachment,
    required this.onSelectSkill,
    required this.onRemoveSkill,
    required this.onSelectFile,
    required this.onRemoveFile,
    required this.onSend,
    required this.onDismiss,
    this.onAddSkillTrigger,
    this.onAddFileTrigger,
    this.modelLabel,
    this.modelDetail,
    this.modelCustomized = false,
    this.onModelTap,
    this.thinkingLabel,
    this.thinkingDetail,
    this.thinkingCustomized = false,
    this.onThinkingTap,
    this.submitOnEnter = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  final List<ComposerImageAttachment> attachments;
  final List<_ComposerSkillMention> skills;
  final List<_ComposerFileMention> files;

  final String? activeSkillQuery;
  final List<SkillSummary> skillSuggestions;
  final bool loadingSkills;
  final String? skillError;

  final String? activeFileQuery;
  final List<FsSearchResult> fileSuggestions;
  final bool loadingFileSearch;
  final String? fileError;

  final bool sending;
  final bool supportsImageInput;
  final bool supportsSkillInput;

  /// Whether @file-mention is supported by the current provider.
  final bool supportsFileMentions;

  final VoidCallback onPickImages;
  final Future<bool> Function() onNativePaste;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<SkillSummary> onSelectSkill;
  final ValueChanged<String> onRemoveSkill;
  final ValueChanged<FsSearchResult> onSelectFile;
  final ValueChanged<String> onRemoveFile;
  final VoidCallback onSend;
  final VoidCallback onDismiss;

  /// Inserts a `$` trigger into the text field and focuses it (mobile + button).
  final VoidCallback? onAddSkillTrigger;

  /// Inserts a `@` trigger into the text field and focuses it (mobile + button).
  final VoidCallback? onAddFileTrigger;

  final String? modelLabel;
  final String? modelDetail;
  final bool modelCustomized;
  final VoidCallback? onModelTap;
  final String? thinkingLabel;
  final String? thinkingDetail;
  final bool thinkingCustomized;
  final VoidCallback? onThinkingTap;

  final bool submitOnEnter;

  @override
  Widget build(BuildContext context) {
    final isDesktop = submitOnEnter;
    final bool showPlusButton =
        !isDesktop &&
        (supportsImageInput || supportsSkillInput || supportsFileMentions);
    final bool showModelButton = modelLabel != null && onModelTap != null;
    final bool showThinkingButton =
        thinkingLabel != null && onThinkingTap != null;
    final controls = <AppComposerControl>[
      if (showModelButton)
        AppComposerControl(
          icon: Icons.memory_rounded,
          label: modelLabel!,
          detail: modelDetail,
          customized: modelCustomized,
          tooltip: 'Choose model',
          onPressed: onModelTap!,
        ),
      if (showThinkingButton)
        AppComposerControl(
          icon: Icons.psychology_alt_rounded,
          label: thinkingLabel!,
          detail: thinkingDetail,
          customized: thinkingCustomized,
          tooltip: 'Choose thinking level',
          onPressed: onThinkingTap!,
        ),
    ];
    final hasContext =
        attachments.isNotEmpty || skills.isNotEmpty || files.isNotEmpty;
    final leading = isDesktop && supportsImageInput
        ? _ComposerAttachButton(enabled: !sending, onPressed: onPickImages)
        : showPlusButton
        ? _ComposerPlusButton(
            enabled: !sending,
            supportsImageInput: supportsImageInput,
            supportsSkillInput: supportsSkillInput,
            supportsFileMentions: supportsFileMentions,
            onPickImages: onPickImages,
            onAddSkillTrigger: onAddSkillTrigger,
            onAddFileTrigger: onAddFileTrigger,
          )
        : null;

    return AppComposer(
      controller: controller,
      focusNode: focusNode,
      sending: sending,
      onSend: onSend,
      onDismiss: onDismiss,
      onNativePaste: onNativePaste,
      submitOnEnter: submitOnEnter,
      desktopHintText:
          'Reply here. Press Enter to send, Shift+Enter for a new line',
      hasSendableContext: hasContext,
      leading: leading,
      controls: controls,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: AppMotion.quick,
            curve: AppMotion.standard,
            child: (supportsSkillInput && activeSkillQuery != null)
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    child: _ComposerSkillSuggestionTray(
                      query: activeSkillQuery!,
                      suggestions: skillSuggestions,
                      loading: loadingSkills,
                      error: skillError,
                      onSelectSkill: onSelectSkill,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          AnimatedSize(
            duration: AppMotion.quick,
            curve: AppMotion.standard,
            child: activeFileQuery != null
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    child: _ComposerFileSuggestionTray(
                      query: activeFileQuery!,
                      suggestions: fileSuggestions,
                      loading: loadingFileSearch,
                      error: fileError,
                      onSelectFile: onSelectFile,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          AnimatedSize(
            duration: AppMotion.reveal,
            curve: AppMotion.standard,
            child: hasContext
                ? _ComposerContextShelf(
                    attachments: attachments,
                    skills: skills,
                    files: files,
                    onRemoveAttachment: onRemoveAttachment,
                    onRemoveSkill: onRemoveSkill,
                    onRemoveFile: onRemoveFile,
                    isDesktop: isDesktop,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone 2: Context shelf
// ─────────────────────────────────────────────────────────────────────────────

class _ComposerContextShelf extends StatelessWidget {
  const _ComposerContextShelf({
    required this.attachments,
    required this.skills,
    required this.files,
    required this.onRemoveAttachment,
    required this.onRemoveSkill,
    required this.onRemoveFile,
    required this.isDesktop,
  });

  final List<ComposerImageAttachment> attachments;
  final List<_ComposerSkillMention> skills;
  final List<_ComposerFileMention> files;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<String> onRemoveSkill;
  final ValueChanged<String> onRemoveFile;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shelfAccent = visibleUiColorOn(
      colors,
      background: colors.surfaceMuted,
      preferred: colors.accent,
    );
    final shelfSecondary = visibleUiColorOn(
      colors,
      background: colors.surfaceMuted,
      preferred: colors.textSecondary,
    );

    final duplicateFileNames = _duplicateFileNameKeys(
      files.map((item) => item.file),
    );

    return AppComposerContextShelf(
      desktop: isDesktop,
      items: <AppComposerContextItem>[
        for (final a in attachments)
          AppComposerContextItem(
            id: 'image-${a.id}',
            icon: isDesktop
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      a.bytes,
                      width: 20,
                      height: 20,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  )
                : Icon(Icons.image_rounded, size: 14, color: shelfSecondary),
            label: a.name,
            sublabel: isDesktop ? _formatByteCount(a.byteLength) : null,
            onRemove: () => onRemoveAttachment(a.id),
          ),
        for (final s in skills)
          AppComposerContextItem(
            id: 'skill-${s.skill.path}',
            icon: Icon(
              Icons.auto_awesome_rounded,
              size: 14,
              color: shelfAccent,
            ),
            label: s.tokenText,
            onRemove: () => onRemoveSkill(s.skill.path),
          ),
        for (final f in files)
          AppComposerContextItem(
            id: 'file-${f.file.path}',
            icon: Icon(
              f.file.isDirectory
                  ? Icons.folder_rounded
                  : Icons.insert_drive_file_rounded,
              size: 14,
              color: shelfSecondary,
            ),
            label: _fileShelfLabel(
              f.file,
              showParent:
                  duplicateFileNames.contains(_fileNameKey(f.file)) &&
                  !isDesktop,
            ),
            sublabel: isDesktop ? _compactFileParentPath(f.file) : null,
            onRemove: () => onRemoveFile(f.file.path),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone 1 buttons
// ─────────────────────────────────────────────────────────────────────────────

/// Mobile-only: single `+` button that opens a context action sheet.
/// Replaces the separate attach + paste buttons so the bar stays compact.
class _ComposerPlusButton extends StatelessWidget {
  const _ComposerPlusButton({
    required this.enabled,
    required this.supportsImageInput,
    required this.supportsSkillInput,
    required this.supportsFileMentions,
    required this.onPickImages,
    this.onAddSkillTrigger,
    this.onAddFileTrigger,
  });

  final bool enabled;
  final bool supportsImageInput;
  final bool supportsSkillInput;
  final bool supportsFileMentions;
  final VoidCallback onPickImages;
  final VoidCallback? onAddSkillTrigger;
  final VoidCallback? onAddFileTrigger;

  void _handleTap(BuildContext context) {
    // Collect available options.
    final options = <(IconData, String, VoidCallback)>[
      if (supportsImageInput)
        (Icons.add_photo_alternate_rounded, 'Attach image', onPickImages),
      if (supportsSkillInput && onAddSkillTrigger != null)
        (Icons.auto_awesome_rounded, 'Insert skill', onAddSkillTrigger!),
      if (supportsFileMentions && onAddFileTrigger != null)
        (Icons.insert_drive_file_rounded, 'Mention file', onAddFileTrigger!),
    ];

    if (options.isEmpty) return;

    // If there's only one option, fire it directly — no sheet needed.
    if (options.length == 1) {
      options.first.$3();
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      builder: (ctx) {
        final colors = ctx.colors;
        return MeshBottomSheetScaffold(
          icon: Icons.add_rounded,
          title: 'Add something',
          description:
              'Attach an image, insert a skill, or mention a file in this message.',
          maxWidth: 560,
          maxHeightFactor: 0.48,
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: [
              for (final option in options)
                MeshListRow(
                  framed: false,
                  dense: true,
                  radius: AppRadii.control,
                  leading: Icon(option.$1, color: colors.accent),
                  title: Text(option.$2),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    option.$3();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppComposerAddButton(
      enabled: enabled,
      onPressed: () => _handleTap(context),
    );
  }
}

/// Desktop-only: dedicated image-attach button (kept from original).
class _ComposerAttachButton extends StatelessWidget {
  const _ComposerAttachButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AppComposerAddButton(
      enabled: enabled,
      onPressed: onPressed,
      tooltip: 'Attach images',
      icon: Icons.add_photo_alternate_rounded,
      compact: true,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone 3: Skill suggestion tray
// ─────────────────────────────────────────────────────────────────────────────

class _ComposerSkillSuggestionTray extends StatefulWidget {
  const _ComposerSkillSuggestionTray({
    required this.query,
    required this.suggestions,
    required this.loading,
    required this.error,
    required this.onSelectSkill,
  });

  final String query;
  final List<SkillSummary> suggestions;
  final bool loading;
  final String? error;
  final ValueChanged<SkillSummary> onSelectSkill;

  @override
  State<_ComposerSkillSuggestionTray> createState() =>
      _ComposerSkillSuggestionTrayState();
}

class _ComposerSkillSuggestionTrayState
    extends State<_ComposerSkillSuggestionTray> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget child;
    if (widget.loading) {
      child = const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: _ComposerSuggestionTrayLoadingState(
          badgeCount: 1,
          showTrailing: true,
        ),
      );
    } else if (widget.suggestions.isEmpty) {
      final message = widget.error == null || widget.error!.trim().isEmpty
          ? 'No skills match "\$${widget.query}".'
          : 'Couldn\'t load skills: ${widget.error}';
      child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 16,
              color: colors.textTertiary,
            ),
            const SizedBox(width: 8),
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
    } else {
      final maxHeight = math.min(
        300.0,
        MediaQuery.sizeOf(context).height * 0.40,
      );
      child = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: widget.suggestions.length > 4,
          child: ListView.builder(
            controller: _scrollController,
            primary: false,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: widget.suggestions.length,
            itemBuilder: (context, index) =>
                _buildSkillRow(context, widget.suggestions[index]),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _buildSkillRow(BuildContext context, SkillSummary skill) {
    final colors = context.colors;
    return MeshListRow(
      framed: false,
      dense: true,
      radius: AppRadii.control,
      onTap: () => widget.onSelectSkill(skill),
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppShapes.action,
          border: Border.all(color: colors.border),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.auto_awesome_rounded, size: 15, color: colors.accent),
      ),
      title: Text(
        skill.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontWeight: AppWeights.emphasis),
      ),
      subtitle: Text(
        skill.summaryDescription,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
      ),
      badges: [_SkillScopeBadge(skill: skill)],
      trailing: Text(
        skill.mentionToken,
        style: monoStyle(
          color: colors.textTertiary,
          fontSize: 11,
          fontWeight: AppWeights.body,
        ),
      ),
    );
  }
}

class _SkillScopeBadge extends StatelessWidget {
  const _SkillScopeBadge({required this.skill});

  final SkillSummary skill;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isWorkspace = skill.scope == 'repo';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isWorkspace ? colors.accentMuted : colors.surfaceMuted,
        borderRadius: AppShapes.pill,
        border: Border.all(
          color: isWorkspace
              ? colors.accent.withValues(alpha: 0.35)
              : colors.border,
        ),
      ),
      child: Text(
        skill.scopeLabel,
        style: monoStyle(
          color: isWorkspace ? colors.accent : colors.textTertiary,
          fontSize: 10,
          fontWeight: AppWeights.emphasis,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone 3: File suggestion tray
// ─────────────────────────────────────────────────────────────────────────────

class _ComposerFileSuggestionTray extends StatefulWidget {
  const _ComposerFileSuggestionTray({
    required this.query,
    required this.suggestions,
    required this.loading,
    required this.error,
    required this.onSelectFile,
  });

  final String query;
  final List<FsSearchResult> suggestions;
  final bool loading;
  final String? error;
  final ValueChanged<FsSearchResult> onSelectFile;

  @override
  State<_ComposerFileSuggestionTray> createState() =>
      _ComposerFileSuggestionTrayState();
}

class _ComposerFileSuggestionTrayState
    extends State<_ComposerFileSuggestionTray> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget child;
    if (widget.loading && widget.suggestions.isEmpty) {
      child = const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: _ComposerSuggestionTrayLoadingState(showTrailing: false),
      );
    } else if (widget.error != null && widget.error!.trim().isNotEmpty) {
      child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: colors.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.error!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.danger),
              ),
            ),
          ],
        ),
      );
    } else if (widget.suggestions.isEmpty) {
      child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 16,
              color: colors.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.query.trim().isEmpty
                    ? 'Type after "@" to search files.'
                    : 'No files match "@${widget.query}".',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        ),
      );
    } else {
      final duplicateNames = _duplicateFileNameKeys(widget.suggestions);
      final maxHeight = math.min(
        300.0,
        MediaQuery.sizeOf(context).height * 0.40,
      );
      child = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: widget.suggestions.length > 6,
          child: ListView.builder(
            controller: _scrollController,
            primary: false,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: widget.suggestions.length,
            itemBuilder: (context, index) {
              final file = widget.suggestions[index];
              return _buildFileRow(
                context,
                file,
                ambiguousName: duplicateNames.contains(_fileNameKey(file)),
              );
            },
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _buildFileRow(
    BuildContext context,
    FsSearchResult file, {
    required bool ambiguousName,
  }) {
    final colors = context.colors;
    return MeshListRow(
      framed: false,
      dense: true,
      radius: AppRadii.control,
      onTap: () => widget.onSelectFile(file),
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppShapes.action,
          border: Border.all(color: colors.border),
        ),
        alignment: Alignment.center,
        child: Icon(
          file.isDirectory
              ? Icons.folder_rounded
              : Icons.insert_drive_file_rounded,
          size: 15,
          color: colors.textTertiary,
        ),
      ),
      title: Text(
        _fileDisplayName(file),
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontWeight: AppWeights.emphasis),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _compactFileParentPath(file, maxSegments: ambiguousName ? 4 : 3),
        style: monoStyle(color: colors.textTertiary, fontSize: 11),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _ComposerSuggestionTrayLoadingState extends StatelessWidget {
  const _ComposerSuggestionTrayLoadingState({
    this.badgeCount = 0,
    required this.showTrailing,
  });

  final int badgeCount;
  final bool showTrailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        MeshListRowSkeleton(
          dense: true,
          framed: false,
          titleWidthFactor: 0.46,
          subtitleWidthFactor: 0.72,
          badgeCount: badgeCount,
          showTrailing: showTrailing,
        ),
        const SizedBox(height: 4),
        MeshListRowSkeleton(
          dense: true,
          framed: false,
          titleWidthFactor: 0.58,
          subtitleWidthFactor: 0.64,
          badgeCount: badgeCount,
          showTrailing: showTrailing,
        ),
        const SizedBox(height: 4),
        MeshListRowSkeleton(
          dense: true,
          framed: false,
          titleWidthFactor: 0.4,
          subtitleWidthFactor: 0.7,
          badgeCount: badgeCount,
          showTrailing: showTrailing,
        ),
      ],
    );
  }
}

Set<String> _duplicateFileNameKeys(Iterable<FsSearchResult> files) {
  final counts = <String, int>{};
  for (final file in files) {
    final key = _fileNameKey(file);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return {
    for (final entry in counts.entries)
      if (entry.value > 1) entry.key,
  };
}

String _fileNameKey(FsSearchResult file) =>
    _fileDisplayName(file).toLowerCase();

String _fileShelfLabel(FsSearchResult file, {required bool showParent}) {
  final name = _fileDisplayName(file);
  if (!showParent) {
    return name;
  }
  return '$name · ${_compactFileParentPath(file, maxSegments: 2)}';
}

String _fileDisplayName(FsSearchResult file) {
  final name = file.name.trim();
  if (name.isNotEmpty) {
    return name;
  }
  var path = file.path.trim();
  while (path.endsWith('/') && path.length > 1) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) {
    return 'file';
  }
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

String _compactFileParentPath(FsSearchResult file, {int maxSegments = 3}) {
  final parent = _fileParentPath(file.path);
  if (parent.isEmpty) {
    return 'workspace root';
  }
  return _compactPath(parent, maxSegments: maxSegments);
}

String _fileParentPath(String rawPath) {
  var path = rawPath.trim();
  while (path.endsWith('/') && path.length > 1) {
    path = path.substring(0, path.length - 1);
  }
  final slash = path.lastIndexOf('/');
  if (slash < 0) {
    return '';
  }
  if (slash == 0) {
    return '/';
  }
  return path.substring(0, slash);
}

String _compactPath(String rawPath, {int maxSegments = 3}) {
  final path = rawPath.trim();
  if (path.isEmpty || path == '/') {
    return path;
  }
  final segments = path.split('/').where((part) => part.isNotEmpty).toList();
  if (segments.isEmpty) {
    return path;
  }
  final visible = segments.length > maxSegments
      ? segments.sublist(segments.length - maxSegments)
      : segments;
  final prefix = segments.length > maxSegments
      ? '.../'
      : path.startsWith('/')
      ? '/'
      : '';
  return '$prefix${visible.join('/')}';
}

String _fileMentionToken(FsSearchResult file) {
  final path = file.path.trim();
  if (!file.isDirectory) {
    return '@$path';
  }
  var directoryPath = path;
  while (directoryPath.endsWith('/') && directoryPath.length > 1) {
    directoryPath = directoryPath.substring(0, directoryPath.length - 1);
  }
  return '@$directoryPath/';
}

// ─────────────────────────────────────────────────────────────────────────────
// Composer query and mention state
// ─────────────────────────────────────────────────────────────────────────────

class _ComposerSkillMention {
  const _ComposerSkillMention({required this.skill, required this.tokenText});

  final SkillSummary skill;
  final String tokenText;

  @override
  bool operator ==(Object other) {
    return other is _ComposerSkillMention &&
        other.skill.path == skill.path &&
        other.tokenText == tokenText;
  }

  @override
  int get hashCode => Object.hash(skill.path, tokenText);
}

class _ComposerFileMention {
  const _ComposerFileMention({required this.file, required this.tokenText});

  final FsSearchResult file;
  final String tokenText;

  @override
  bool operator ==(Object other) {
    return other is _ComposerFileMention &&
        other.file.path == file.path &&
        other.tokenText == tokenText;
  }

  @override
  int get hashCode => Object.hash(file.path, tokenText);
}

class _ActiveComposerSkillQuery {
  const _ActiveComposerSkillQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

class _ActiveComposerFileQuery {
  const _ActiveComposerFileQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}
