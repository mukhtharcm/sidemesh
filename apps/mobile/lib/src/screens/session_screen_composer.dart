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
    required this.isFocused,
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

  /// Whether the text field currently has focus; drives the animated pill style.
  final bool isFocused;

  final List<_ComposerImageAttachment> attachments;
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
    final colors = context.colors;
    final isMacDesktop =
        submitOnEnter && defaultTargetPlatform == TargetPlatform.macOS;
    final isDesktop = submitOnEnter;

    // ── Zone 1: text field ──────────────────────────────────────────────────
    Widget field = TextField(
      controller: controller,
      focusNode: focusNode,
      minLines: 1,
      maxLines: 6,
      onTapOutside: isMacDesktop ? null : (_) => onDismiss(),
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: submitOnEnter
            ? 'Reply here. Press Enter to send, Shift+Enter for a new line'
            : 'Reply here',
        hintStyle: TextStyle(color: colors.textTertiary),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        fillColor: Colors.transparent,
        isDense: true,
        // Padding is handled by the animated pill container below.
        contentPadding: EdgeInsets.zero,
      ),
    );

    field = Actions(
      actions: <Type, Action<Intent>>{
        PasteTextIntent: ComposerPasteTextAction(onPasteImage: onNativePaste),
      },
      child: field,
    );

    if (submitOnEnter) {
      field = CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (!sending) onSend();
          },
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () {
            final selection = controller.selection;
            final text = controller.text;
            final start = selection.start < 0 ? text.length : selection.start;
            final end = selection.end < 0 ? text.length : selection.end;
            final before = text.substring(0, start);
            final after = text.substring(end);
            final next = '$before\n$after';
            controller.value = TextEditingValue(
              text: next,
              selection: TextSelection.collapsed(offset: start + 1),
            );
          },
        },
        child: field,
      );
    }

    // ── Zone 1: bar row ─────────────────────────────────────────────────────
    final bool showPlusButton =
        !isDesktop &&
        (supportsImageInput || supportsSkillInput || supportsFileMentions);
    final bool showModelButton = modelLabel != null && onModelTap != null;
    final bool showThinkingButton =
        thinkingLabel != null && onThinkingTap != null;

    final modelControlButton = showModelButton
        ? _ComposerModelButton(
            label: modelLabel!,
            detail: modelDetail,
            customized: modelCustomized,
            icon: Icons.memory_rounded,
            tooltipLabel: 'Choose model',
            onPressed: onModelTap!,
            compact: !isDesktop,
          )
        : null;
    final thinkingControlButton = showThinkingButton
        ? _ComposerModelButton(
            label: thinkingLabel!,
            detail: thinkingDetail,
            customized: thinkingCustomized,
            icon: Icons.psychology_alt_rounded,
            tooltipLabel: 'Choose thinking level',
            onPressed: onThinkingTap!,
            compact: !isDesktop,
          )
        : null;
    final controlButtons = <Widget>[
      ?modelControlButton,
      ?thinkingControlButton,
    ];

    final textArea = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 4 : 6,
        vertical: isFocused ? 10 : 8,
      ),
      child: field,
    );

    final toolbarRow = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Paste remains available through native shortcuts/menu; the visible
        // action here is only for adding new context.
        if (isDesktop && supportsImageInput) ...[
          _ComposerAttachButton(enabled: !sending, onPressed: onPickImages),
          const SizedBox(width: 6),
        ] else if (showPlusButton) ...[
          _ComposerPlusButton(
            enabled: !sending,
            supportsImageInput: supportsImageInput,
            supportsSkillInput: supportsSkillInput,
            supportsFileMentions: supportsFileMentions,
            onPickImages: onPickImages,
            onAddSkillTrigger: onAddSkillTrigger,
            onAddFileTrigger: onAddFileTrigger,
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: controlButtons.isEmpty
              ? const SizedBox.shrink()
              : Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: controlButtons,
                ),
        ),
        SizedBox(width: controlButtons.isEmpty ? 0 : 8),
        _SendButton(
          sending: sending,
          controller: controller,
          hasAttachments: attachments.isNotEmpty,
          hasSkills: skills.isNotEmpty || files.isNotEmpty,
          onSend: onSend,
          compact: isDesktop,
        ),
      ],
    );

    final barContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        textArea,
        SizedBox(height: isDesktop ? 6 : 8),
        toolbarRow,
      ],
    );

    final barRow = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: colors.composerBackground,
        borderRadius: BorderRadius.circular(isDesktop ? 10 : AppRadii.control),
        border: Border.all(
          color: isFocused
              ? colors.accent.withValues(alpha: 0.42)
              : colors.border.withValues(alpha: 0.82),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 10 : 9,
        isDesktop ? 8 : 9,
        isDesktop ? 10 : 9,
        isDesktop ? 8 : 9,
      ),
      child: barContent,
    );

    final hasContext =
        attachments.isNotEmpty || skills.isNotEmpty || files.isNotEmpty;

    return SafeArea(
      top: false,
      child: Container(
        // Use BoxDecoration so the top border is drawn as decoration inside
        // the box bounds — adds zero height unlike a child Container.
        decoration: BoxDecoration(
          color: colors.canvas,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Zone 3a: Skill suggestion tray ─────────────────────────────
            // Lives *above* the context shelf so it overlays the conversation
            // list visually without being clipped by the pill.
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
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

            // ── Zone 3b: File suggestion tray ──────────────────────────────
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
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

            // ── Zone 2: Context shelf ──────────────────────────────────────
            // Horizontal scroll row of flat chips; smoothly animates in/out.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
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

            // ── Zone 1: The bar ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: barRow,
            ),
          ],
        ),
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

  final List<_ComposerImageAttachment> attachments;
  final List<_ComposerSkillMention> skills;
  final List<_ComposerFileMention> files;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<String> onRemoveSkill;
  final ValueChanged<String> onRemoveFile;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    // Build chip list: images first, then skills, then file mentions.
    final chips = <Widget>[
      for (final a in attachments)
        _ComposerShelfChip(
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
              : Icon(
                  Icons.image_rounded,
                  size: 14,
                  color: colors.textSecondary,
                ),
          label: a.name,
          // Show file size as sublabel only on desktop where space allows.
          sublabel: isDesktop ? _formatByteCount(a.byteLength) : null,
          onRemove: () => onRemoveAttachment(a.id),
        ),
      for (final s in skills)
        _ComposerShelfChip(
          icon: Icon(
            Icons.auto_awesome_rounded,
            size: 14,
            color: colors.accent,
          ),
          label: s.tokenText,
          onRemove: () => onRemoveSkill(s.skill.path),
        ),
      for (final f in files)
        _ComposerShelfChip(
          icon: Icon(
            f.file.isDirectory
                ? Icons.folder_rounded
                : Icons.insert_drive_file_rounded,
            size: 14,
            color: colors.textTertiary,
          ),
          label: f.file.name,
          onRemove: () => onRemoveFile(f.file.path),
        ),
    ];

    return SizedBox(
      // Slightly taller on desktop to give room for sublabels.
      height: isDesktop ? 52 : 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        itemCount: chips.length,
        separatorBuilder: (_, index) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) => chips[i],
      ),
    );
  }
}

/// A compact pill-shaped chip for the context shelf.
/// Replaces the taller, richer desktop-style chips in the old pill interior.
class _ComposerShelfChip extends StatelessWidget {
  const _ComposerShelfChip({
    required this.icon,
    required this.label,
    required this.onRemove,
    this.sublabel,
  });

  final Widget icon;
  final String label;
  final String? sublabel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.pill,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.only(left: 8, right: 4, top: 4, bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: sublabel != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: AppWeights.emphasis,
                        ),
                      ),
                      Text(
                        sublabel!,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  )
                : Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: AppShapes.pill,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
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
    final colors = context.colors;
    return Tooltip(
      message: 'Add',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppShapes.badge,
          onTap: enabled ? () => _handleTap(context) : null,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.surfaceMuted.withValues(alpha: 0.56),
              borderRadius: AppShapes.badge,
              border: Border.all(color: colors.border),
            ),
            child: Icon(
              Icons.add_rounded,
              color: enabled ? colors.textSecondary : colors.textTertiary,
              size: 21,
            ),
          ),
        ),
      ),
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
    final colors = context.colors;
    return Tooltip(
      message: 'Attach images',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppShapes.badge,
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(
              Icons.add_photo_alternate_rounded,
              color: enabled ? colors.accent : colors.textTertiary,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerModelButton extends StatelessWidget {
  const _ComposerModelButton({
    required this.label,
    required this.detail,
    required this.customized,
    required this.icon,
    required this.tooltipLabel,
    required this.onPressed,
    this.compact = false,
  });

  final String label;
  final String? detail;
  final bool customized;
  final IconData icon;
  final String tooltipLabel;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final maxWidth = compact ? 136.0 : 154.0;
    final minHeight = compact ? 32.0 : 34.0;
    return Tooltip(
      message: detail == null ? tooltipLabel : '$tooltipLabel: $detail',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppShapes.badge,
          onTap: onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              minHeight: minHeight,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 9,
              vertical: compact ? 6 : 6,
            ),
            decoration: BoxDecoration(
              color: customized
                  ? colors.accentMuted
                  : colors.surfaceMuted.withValues(alpha: 0.56),
              borderRadius: AppShapes.badge,
              border: Border.all(
                color: customized
                    ? colors.accent.withValues(alpha: 0.38)
                    : colors.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: compact ? 14 : 15,
                  color: customized ? colors.accent : colors.textSecondary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      color: colors.textPrimary,
                      fontSize: compact ? 11 : 11.5,
                      fontWeight: AppWeights.title,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_more_rounded,
                  size: 16,
                  color: colors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Send button
// ─────────────────────────────────────────────────────────────────────────────

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.sending,
    required this.controller,
    required this.hasAttachments,
    required this.hasSkills,
    required this.onSend,
    this.compact = false,
  });

  final bool sending;
  final TextEditingController controller;
  final bool hasAttachments;
  final bool hasSkills;
  final VoidCallback onSend;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final hasText = controller.text.trim().isNotEmpty;
        final canSend = !sending && (hasText || hasAttachments || hasSkills);
        final showActive = sending || canSend;
        final bgColor = sending
            ? colors.surfaceMuted
            : (canSend ? colors.accent : colors.surfaceMuted);
        final size = compact ? 36.0 : 40.0;
        final radius = compact ? AppRadii.iconWell : AppRadii.action;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(radius),
            onTap: canSend ? onSend : null,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(radius),
                border: showActive
                    ? null
                    : Border.all(color: colors.border),
              ),
              alignment: Alignment.center,
              child: sending
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.textSecondary,
                      ),
                    )
                  : Icon(
                      Icons.arrow_upward_rounded,
                      size: compact ? 19 : 24,
                      color: canSend ? colors.accentOn : colors.textTertiary,
                    ),
            ),
          ),
        );
      },
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
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
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
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
        ),
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
            itemBuilder: (context, index) =>
                _buildFileRow(context, widget.suggestions[index]),
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

  Widget _buildFileRow(BuildContext context, FsSearchResult file) {
    final colors = context.colors;
    return MeshListRow(
      framed: false,
      dense: true,
      radius: AppRadii.control,
      onTap: () => widget.onSelectFile(file),
      leading: Icon(
        file.isDirectory
            ? Icons.folder_rounded
            : Icons.insert_drive_file_rounded,
        size: 16,
        color: colors.textTertiary,
      ),
      title: Text(
        file.path,
        style: TextStyle(color: colors.textPrimary, fontSize: 13),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data models (unchanged from original)
// ─────────────────────────────────────────────────────────────────────────────

class _ComposerImageAttachment {
  const _ComposerImageAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.dataUrl,
  });

  final String id;
  final String name;
  final String mimeType;
  final Uint8List bytes;
  final String dataUrl;

  int get byteLength => bytes.length;
}

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

class _PreparedDraftImage {
  const _PreparedDraftImage({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

class _ComposerImagePickerConfig {
  const _ComposerImagePickerConfig({
    required this.type,
    this.allowedExtensions,
    this.requestPhotoLibraryAccess = false,
  });

  final FileType type;
  final List<String>? allowedExtensions;
  final bool requestPhotoLibraryAccess;
}

class _DraftImageAppendResult {
  const _DraftImageAppendResult._({
    required this.totalBytes,
    required this.added,
    required this.shouldStop,
  });

  const _DraftImageAppendResult.added(int totalBytes)
    : this._(totalBytes: totalBytes, added: true, shouldStop: false);

  const _DraftImageAppendResult.skipped(int totalBytes)
    : this._(totalBytes: totalBytes, added: false, shouldStop: false);

  const _DraftImageAppendResult.stop(int totalBytes)
    : this._(totalBytes: totalBytes, added: false, shouldStop: true);

  final int totalBytes;
  final bool added;
  final bool shouldStop;
}

class _ClipboardImageData {
  const _ClipboardImageData({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}
