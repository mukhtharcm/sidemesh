import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'composer_paste_text_action.dart';

@immutable
class AppComposerControl {
  const AppComposerControl({
    this.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.detail,
    this.enabled = true,
  });

  final Key? key;
  final IconData icon;
  final String label;
  final String tooltip;
  final String? detail;
  final bool enabled;
  final VoidCallback onPressed;
}

@immutable
class AppComposerContextItem {
  const AppComposerContextItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.onRemove,
    this.sublabel,
  });

  final String id;
  final Widget icon;
  final String label;
  final String? sublabel;
  final VoidCallback onRemove;
}

/// Shared adaptive composer used by both new and active sessions.
///
/// Callers own message state and optional context/suggestion surfaces. This
/// widget owns the stable input geometry, keyboard behavior, control rail, and
/// send affordance so those details cannot drift between session flows.
class AppComposer extends StatelessWidget {
  const AppComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
    this.enabled = true,
    this.autofocus = false,
    this.hintText = 'Reply here',
    this.desktopHintText,
    this.textFieldKey,
    this.sendButtonKey,
    this.sendSemanticsLabel = 'Send message',
    this.hasSendableContext = false,
    this.leading,
    this.controls = const <AppComposerControl>[],
    this.header,
    this.onDismiss,
    this.onNativePaste,
    this.submitOnEnter = false,
    this.maxLines = 6,
    this.textCapitalization = TextCapitalization.sentences,
    this.maxWidth = 920,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool enabled;
  final bool autofocus;
  final String hintText;
  final String? desktopHintText;
  final Key? textFieldKey;
  final Key? sendButtonKey;
  final String sendSemanticsLabel;
  final bool hasSendableContext;
  final Widget? leading;
  final List<AppComposerControl> controls;
  final Widget? header;
  final VoidCallback onSend;
  final VoidCallback? onDismiss;
  final Future<bool> Function()? onNativePaste;
  final bool submitOnEnter;
  final int maxLines;
  final TextCapitalization textCapitalization;
  final double maxWidth;

  bool get _isMacDesktop =>
      submitOnEnter && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colors.canvas,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?header,
            Padding(
              padding: EdgeInsets.fromLTRB(
                submitOnEnter ? AppSizes.desktopGutter : 14,
                submitOnEnter ? AppSpacing.sm : 6,
                submitOnEnter ? AppSizes.desktopGutter : 14,
                AppSpacing.sm,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: AnimatedBuilder(
                    animation: focusNode,
                    builder: (context, _) => _buildComposerSurface(
                      context,
                      focused: focusNode.hasFocus,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposerSurface(BuildContext context, {required bool focused}) {
    final colors = context.colors;
    final hintColor = readableTextOn(
      colors,
      background: colors.composerBackground,
      preferred: colors.textTertiary,
      additionalFallbacks: <Color>[colors.textSecondary],
    );
    Widget field = TextField(
      key: textFieldKey,
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      minLines: 1,
      maxLines: maxLines,
      textCapitalization: textCapitalization,
      onTapOutside: _isMacDesktop || onDismiss == null
          ? null
          : (_) => onDismiss!(),
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: submitOnEnter && desktopHintText != null
            ? desktopHintText
            : hintText,
        hintStyle: TextStyle(color: hintColor),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        fillColor: Colors.transparent,
        isDense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );

    final pasteHandler = onNativePaste;
    if (pasteHandler != null) {
      field = Actions(
        actions: <Type, Action<Intent>>{
          PasteTextIntent: ComposerPasteTextAction(onPasteImage: pasteHandler),
        },
        child: field,
      );
    }

    if (submitOnEnter) {
      field = CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): () {
            final canSend =
                controller.text.trim().isNotEmpty || hasSendableContext;
            if (!sending && enabled && canSend) onSend();
          },
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () {
            final selection = controller.selection;
            final text = controller.text;
            final start = selection.start < 0 ? text.length : selection.start;
            final end = selection.end < 0 ? text.length : selection.end;
            controller.value = TextEditingValue(
              text: '${text.substring(0, start)}\n${text.substring(end)}',
              selection: TextSelection.collapsed(offset: start + 1),
            );
          },
        },
        child: field,
      );
    }

    final textArea = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: submitOnEnter ? AppSpacing.xs : 6,
        vertical: 6,
      ),
      child: field,
    );

    return AnimatedContainer(
      duration: AppMotion.quick,
      curve: AppMotion.standard,
      decoration: BoxDecoration(
        color: colors.composerBackground,
        borderRadius: BorderRadius.circular(
          submitOnEnter ? AppRadii.control : AppRadii.surface,
        ),
        border: Border.all(
          color: focused
              ? colors.accent.withValues(alpha: 0.42)
              : colors.border.withValues(alpha: 0.82),
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          textArea,
          const SizedBox(height: AppSpacing.xs),
          _AppComposerToolbar(
            controller: controller,
            sending: sending,
            enabled: enabled,
            hasSendableContext: hasSendableContext,
            leading: leading,
            controls: controls,
            onSend: onSend,
            sendButtonKey: sendButtonKey,
            sendSemanticsLabel: sendSemanticsLabel,
            desktop: submitOnEnter,
          ),
        ],
      ),
    );
  }
}

class _AppComposerToolbar extends StatelessWidget {
  const _AppComposerToolbar({
    required this.controller,
    required this.sending,
    required this.enabled,
    required this.hasSendableContext,
    required this.leading,
    required this.controls,
    required this.onSend,
    required this.sendButtonKey,
    required this.sendSemanticsLabel,
    required this.desktop,
  });

  final TextEditingController controller;
  final bool sending;
  final bool enabled;
  final bool hasSendableContext;
  final Widget? leading;
  final List<AppComposerControl> controls;
  final VoidCallback onSend;
  final Key? sendButtonKey;
  final String sendSemanticsLabel;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 6)],
        Expanded(
          child: controls.isEmpty
              ? const SizedBox.shrink()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 4.0;
                    final totalSpacing = spacing * (controls.length - 1);
                    final availableWidth = constraints.maxWidth - totalSpacing;
                    final naturalWidth = availableWidth <= 0
                        ? 0.0
                        : availableWidth / controls.length;
                    final maxControlWidth = desktop || controls.length == 1
                        ? 164.0
                        : 122.0;
                    final controlWidth = naturalWidth > maxControlWidth
                        ? maxControlWidth
                        : naturalWidth;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (
                          var index = 0;
                          index < controls.length;
                          index++
                        ) ...[
                          SizedBox(
                            width: controlWidth,
                            child: _AppComposerControlButton(
                              control: controls[index],
                              compact: !desktop,
                            ),
                          ),
                          if (index != controls.length - 1)
                            const SizedBox(width: spacing),
                        ],
                      ],
                    );
                  },
                ),
        ),
        SizedBox(width: controls.isEmpty ? 0 : AppSpacing.sm),
        _AppComposerSendButton(
          key: sendButtonKey,
          controller: controller,
          sending: sending,
          enabled: enabled,
          hasSendableContext: hasSendableContext,
          onSend: onSend,
          semanticsLabel: sendSemanticsLabel,
          compact: desktop,
        ),
      ],
    );
  }
}

class _AppComposerControlButton extends StatelessWidget {
  const _AppComposerControlButton({
    required this.control,
    required this.compact,
  });

  final AppComposerControl control;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final background = colors.surfaceMuted;
    final iconColor = visibleUiColorOn(
      colors,
      background: background,
      preferred: colors.textSecondary,
    );
    final labelColor = readableTextOn(
      colors,
      background: background,
      preferred: colors.textPrimary,
    );
    final chevronColor = visibleUiColorOn(
      colors,
      background: background,
      preferred: colors.textSecondary,
    );
    final tooltip = control.detail == null
        ? control.tooltip
        : '${control.tooltip}: ${control.detail}';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: control.enabled,
        label: tooltip,
        child: Material(
          key: control.key,
          color: Colors.transparent,
          child: InkWell(
            borderRadius: AppShapes.badge,
            onTap: control.enabled ? control.onPressed : null,
            child: Opacity(
              opacity: control.enabled ? 1 : 0.48,
              child: Container(
                constraints: BoxConstraints(
                  minHeight: compact ? 44 : AppSizes.compactControl,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? AppSpacing.sm : 9,
                  vertical: compact ? 7 : 6,
                ),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: AppShapes.badge,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Icon(
                      control.icon,
                      size: compact ? 14 : 15,
                      color: iconColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        control.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: labelColor,
                          fontSize: compact ? 11 : 11.5,
                          fontWeight: AppWeights.title,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Icon(
                      Icons.expand_more_rounded,
                      size: AppSizes.compactIcon,
                      color: chevronColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppComposerAddButton extends StatelessWidget {
  const AppComposerAddButton({
    super.key,
    required this.enabled,
    required this.onPressed,
    this.tooltip = 'Add',
    this.icon = Icons.add_rounded,
    this.compact = false,
  });

  final bool enabled;
  final VoidCallback onPressed;
  final String tooltip;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconColor = visibleUiColorOn(
      colors,
      background: colors.composerBackground,
      preferred: enabled ? colors.accent : colors.textSecondary,
    );
    final size = compact ? AppSizes.compactControl : 44.0;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        onTap: enabled ? onPressed : null,
        excludeSemantics: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: AppShapes.badge,
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: iconColor, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class AppComposerContextShelf extends StatelessWidget {
  const AppComposerContextShelf({
    super.key,
    required this.items,
    this.desktop = false,
  });

  final List<AppComposerContextItem> items;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey('composer-context-shelf'),
      height: desktop ? 52 : 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) =>
            _AppComposerContextChip(item: items[index]),
      ),
    );
  }
}

class _AppComposerContextChip extends StatelessWidget {
  const _AppComposerContextChip({required this.item});

  final AppComposerContextItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = readableTextOn(
      colors,
      background: colors.surfaceMuted,
      preferred: colors.textPrimary,
    );
    final secondary = readableTextOn(
      colors,
      background: colors.surfaceMuted,
      preferred: colors.textTertiary,
      additionalFallbacks: <Color>[colors.textSecondary],
    );
    final iconForeground = visibleUiColorOn(
      colors,
      background: colors.surfaceMuted,
      preferred: colors.textSecondary,
    );
    final borderColor = visibleBorderOn(
      colors,
      background: colors.surfaceMuted,
      preferred: colors.border,
    );
    return Container(
      key: ValueKey('composer-context-item-${item.id}'),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.pill,
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item.icon,
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: item.sublabel == null ? 150 : 170,
            ),
            child: item.sublabel == null
                ? Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foreground,
                      fontWeight: AppWeights.emphasis,
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: foreground,
                          fontWeight: AppWeights.emphasis,
                        ),
                      ),
                      Text(
                        item.sublabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(color: secondary, fontSize: 10),
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Remove ${item.label}',
            child: IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              onPressed: item.onRemove,
              icon: Icon(Icons.close_rounded, size: 14, color: iconForeground),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppComposerSendButton extends StatelessWidget {
  const _AppComposerSendButton({
    super.key,
    required this.controller,
    required this.sending,
    required this.enabled,
    required this.hasSendableContext,
    required this.onSend,
    required this.semanticsLabel,
    required this.compact,
  });

  final TextEditingController controller;
  final bool sending;
  final bool enabled;
  final bool hasSendableContext;
  final VoidCallback onSend;
  final String semanticsLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final hasText = controller.text.trim().isNotEmpty;
        final canSend = enabled && !sending && (hasText || hasSendableContext);
        final showActive = sending || canSend;
        final background = sending
            ? colors.surfaceMuted
            : canSend
            ? colors.accent
            : colors.surfaceMuted;
        final activeForeground = readableActionForeground(
          colors,
          colors.accent,
        );
        final quietForeground = visibleUiColorOn(
          colors,
          background: colors.surfaceMuted,
          preferred: colors.textSecondary,
        );
        final quietBorder = visibleBorderOn(
          colors,
          background: colors.surfaceMuted,
          preferred: colors.border,
        );
        final hitSize = compact ? AppSizes.compactControl : AppSizes.control;
        final visibleSize = compact ? AppSizes.compactControl : 42.0;
        final radius = compact ? AppRadii.iconWell : AppRadii.action;
        return Semantics(
          label: semanticsLabel,
          button: true,
          enabled: canSend,
          onTap: canSend ? onSend : null,
          excludeSemantics: true,
          child: Tooltip(
            message: 'Send',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: canSend ? onSend : null,
                child: SizedBox(
                  width: hitSize,
                  height: hitSize,
                  child: Center(
                    child: Container(
                      width: visibleSize,
                      height: visibleSize,
                      decoration: BoxDecoration(
                        color: background,
                        borderRadius: BorderRadius.circular(radius),
                        border: showActive
                            ? null
                            : Border.all(color: quietBorder),
                      ),
                      alignment: Alignment.center,
                      child: sending
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: quietForeground,
                              ),
                            )
                          : Icon(
                              Icons.arrow_upward_rounded,
                              size: compact ? 19 : 22,
                              color: canSend
                                  ? activeForeground
                                  : quietForeground,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
