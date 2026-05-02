part of 'session_screen.dart';

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
    required this.onPickImages,
    required this.onPasteImage,
    required this.onNativePaste,
    required this.onRemoveAttachment,
    required this.onSelectSkill,
    required this.onRemoveSkill,
    required this.onSelectFile,
    required this.onRemoveFile,
    required this.onSend,
    required this.onDismiss,
    this.submitOnEnter = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
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
  final VoidCallback onPickImages;
  final Future<bool> Function() onPasteImage;
  final Future<bool> Function() onNativePaste;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<SkillSummary> onSelectSkill;
  final ValueChanged<String> onRemoveSkill;
  final ValueChanged<FsSearchResult> onSelectFile;
  final ValueChanged<String> onRemoveFile;
  final VoidCallback onSend;
  final VoidCallback onDismiss;
  final bool submitOnEnter;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isMacDesktop =
        submitOnEnter && defaultTargetPlatform == TargetPlatform.macOS;
    final enableDesktopSubmitShortcut = submitOnEnter;
    Widget field = TextField(
      controller: controller,
      focusNode: focusNode,
      minLines: 1,
      maxLines: 6,
      onTapOutside: isMacDesktop ? null : (_) => onDismiss(),
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: enableDesktopSubmitShortcut
            ? 'Message this session — Enter to send, Shift+Enter for newline'
            : 'Message this session',
        hintStyle: TextStyle(color: colors.textTertiary),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
    field = Actions(
      actions: <Type, Action<Intent>>{
        PasteTextIntent: ComposerPasteTextAction(onPasteImage: onNativePaste),
      },
      child: field,
    );
    if (enableDesktopSubmitShortcut) {
      // Desktop affordance: bare Enter sends, Shift+Enter inserts a newline.
      // Wrapping the TextField with CallbackShortcuts at a higher priority
      // than its default newline handler.
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
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        decoration: BoxDecoration(
          color: colors.canvas,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (supportsImageInput) ...[
              _ComposerAttachButton(enabled: !sending, onPressed: onPickImages),
              const SizedBox(width: 8),
              _ComposerPasteButton(
                enabled: !sending,
                onPressed: () => unawaited(onPasteImage()),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colors.composerBackground,
                  borderRadius: AppShapes.card,
                  border: Border.all(color: colors.border),
                ),
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (supportsSkillInput && activeSkillQuery != null) ...[
                      _ComposerSkillSuggestionTray(
                        query: activeSkillQuery!,
                        suggestions: skillSuggestions,
                        loading: loadingSkills,
                        error: skillError,
                        onSelectSkill: onSelectSkill,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (activeFileQuery != null) ...[
                      _ComposerFileSuggestionTray(
                        query: activeFileQuery!,
                        suggestions: fileSuggestions,
                        loading: loadingFileSearch,
                        error: fileError,
                        onSelectFile: onSelectFile,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (supportsSkillInput && skills.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: skills
                              .map(
                                (skill) => _ComposerSkillChip(
                                  mention: skill,
                                  onRemove: onRemoveSkill,
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (files.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: files
                              .map(
                                (file) => _ComposerFileChip(
                                  mention: file,
                                  onRemove: onRemoveFile,
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (attachments.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: attachments
                              .map(
                                (attachment) => _ComposerAttachmentChip(
                                  attachment: attachment,
                                  onRemove: onRemoveAttachment,
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    field,
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _SendButton(
              sending: sending,
              controller: controller,
              hasAttachments: attachments.isNotEmpty,
              hasSkills: skills.isNotEmpty || files.isNotEmpty,
              onSend: onSend,
            ),
          ],
        ),
      ),
    );
  }
}

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
          borderRadius: AppShapes.card,
          onTap: enabled ? onPressed : null,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: AppShapes.card,
              border: Border.all(color: colors.border),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.add_photo_alternate_rounded,
              color: enabled ? colors.accent : colors.textTertiary,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerPasteButton extends StatelessWidget {
  const _ComposerPasteButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: 'Paste image from clipboard',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppShapes.card,
          onTap: enabled ? onPressed : null,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: AppShapes.card,
              border: Border.all(color: colors.border),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.content_paste_rounded,
              color: enabled ? colors.accent : colors.textTertiary,
              size: 21,
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.sending,
    required this.controller,
    required this.hasAttachments,
    required this.hasSkills,
    required this.onSend,
  });

  final bool sending;
  final TextEditingController controller;
  final bool hasAttachments;
  final bool hasSkills;
  final VoidCallback onSend;

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
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: AppShapes.card,
            onTap: canSend ? onSend : null,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: AppShapes.card,
                boxShadow: showActive && canSend
                    ? [
                        BoxShadow(
                          color: colors.accent.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : const [],
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
                      color: canSend ? colors.accentOn : colors.textTertiary,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _ComposerAttachmentChip extends StatelessWidget {
  const _ComposerAttachmentChip({
    required this.attachment,
    required this.onRemove,
  });

  final _ComposerImageAttachment attachment;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              attachment.bytes,
              width: 36,
              height: 36,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatByteCount(attachment.byteLength),
                  style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => onRemove(attachment.id),
            borderRadius: AppShapes.input,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
        340.0,
        MediaQuery.sizeOf(context).height * 0.32,
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
    return InkWell(
      onTap: () => widget.onSelectSkill(skill),
      borderRadius: AppShapes.input,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.border),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 15,
                color: colors.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          skill.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: AppWeights.emphasis),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _SkillScopeBadge(skill: skill),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    skill.summaryDescription,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              skill.mentionToken,
              style: monoStyle(
                color: colors.textTertiary,
                fontSize: 11,
                fontWeight: AppWeights.body,
              ),
            ),
          ],
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

class _ComposerSkillChip extends StatelessWidget {
  const _ComposerSkillChip({required this.mention, required this.onRemove});

  final _ComposerSkillMention mention;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 15, color: colors.accent),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mention.skill.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  mention.tokenText,
                  style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => onRemove(mention.skill.path),
            borderRadius: AppShapes.input,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
  State<_ComposerFileSuggestionTray> createState() => _ComposerFileSuggestionTrayState();
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
            Icon(
              Icons.error_outline_rounded,
              size: 16,
              color: colors.danger,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.error!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.danger,
                ),
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
                'No files match "@${widget.query}".',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      final maxHeight = math.min(
        340.0,
        MediaQuery.sizeOf(context).height * 0.32,
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
    return InkWell(
      onTap: () => widget.onSelectFile(file),
      borderRadius: AppShapes.input,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              file.isDirectory
                  ? Icons.folder_rounded
                  : Icons.insert_drive_file_rounded,
              size: 16,
              color: colors.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                file.path,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerFileChip extends StatelessWidget {
  const _ComposerFileChip({
    required this.mention,
    required this.onRemove,
  });

  final _ComposerFileMention mention;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Chip(
      avatar: Icon(
        mention.file.isDirectory ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
        size: 14,
        color: colors.textTertiary,
      ),
      label: Text(
        mention.file.name,
        style: TextStyle(color: colors.textPrimary, fontSize: 12),
      ),
      backgroundColor: colors.surface,
      side: BorderSide(color: colors.border),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      onDeleted: () => onRemove(mention.file.path),
      deleteIconColor: colors.textTertiary,
    );
  }
}
