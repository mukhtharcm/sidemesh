import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../local_notification_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../theme/color_contrast.dart';
import 'app_snackbar.dart';

class NotificationPermissionBanner extends StatefulWidget {
  const NotificationPermissionBanner({
    super.key,
    this.margin = const EdgeInsets.fromLTRB(16, 2, 16, 4),
    this.compact = false,
  });

  final EdgeInsetsGeometry margin;
  final bool compact;

  @override
  State<NotificationPermissionBanner> createState() =>
      _NotificationPermissionBannerState();
}

class _NotificationPermissionBannerState
    extends State<NotificationPermissionBanner> {
  static const _dismissedKey =
      'sidemesh_notifications_permission_banner_dismissed_v1';

  bool _visible = false;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = LocalNotificationService.instance;
    if (!service.isSupported) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_dismissedKey) ?? false) return;

    final granted = await service.checkPermissions();
    if (!mounted || granted) return;
    setState(() => _visible = true);
  }

  Future<void> _dismiss() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dismissedKey, true);
    if (mounted) {
      setState(() => _visible = false);
    }
  }

  Future<void> _enable() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final granted = await LocalNotificationService.instance
        .requestPermissions();
    if (!mounted) return;
    setState(() => _requesting = false);
    if (granted) {
      await _dismiss();
      return;
    }
    await _dismiss();
    if (!mounted) return;
    showAppSnackBar(
      context,
      'Notifications are still off. You can turn them on later in system settings.',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    return Padding(
      padding: widget.margin,
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surfaceMuted,
          borderRadius: AppShapes.input,
        ),
        padding: EdgeInsets.fromLTRB(
          widget.compact ? 10 : 12,
          widget.compact ? 8 : 6,
          widget.compact ? 6 : 4,
          widget.compact ? 8 : 6,
        ),
        child: widget.compact
            ? _CompactBannerBody(
                requesting: _requesting,
                onEnable: _enable,
                onDismiss: _dismiss,
              )
            : _BannerBody(
                requesting: _requesting,
                onEnable: _enable,
                onDismiss: _dismiss,
              ),
      ),
    );
  }
}

class _BannerBody extends StatelessWidget {
  const _BannerBody({
    required this.requesting,
    required this.onEnable,
    required this.onDismiss,
  });

  final bool requesting;
  final VoidCallback onEnable;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _BellBadge(colors: colors, size: 24),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Approval alerts',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textPrimary,
              fontWeight: AppWeights.emphasis,
            ),
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          onPressed: requesting ? null : onEnable,
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: requesting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Enable'),
        ),
        IconButton(
          tooltip: 'Dismiss',
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          visualDensity: VisualDensity.compact,
          onPressed: onDismiss,
          icon: Icon(Icons.close_rounded, color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _CompactBannerBody extends StatelessWidget {
  const _CompactBannerBody({
    required this.requesting,
    required this.onEnable,
    required this.onDismiss,
  });

  final bool requesting;
  final VoidCallback onEnable;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BellBadge(colors: colors, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Turn on alerts',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            InkResponse(
              radius: 16,
              onTap: onDismiss,
              child: Icon(
                Icons.close_rounded,
                size: 17,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Get a notification when an agent finishes or needs your attention.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 10),
        _EnableButton(requesting: requesting, onPressed: onEnable),
      ],
    );
  }
}

class _BellBadge extends StatelessWidget {
  const _BellBadge({required this.colors, this.size = 34});

  final AppColors colors;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.35),
        border: Border.all(color: colors.accent.withValues(alpha: 0.28)),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.notifications_active_rounded,
        size: size * 0.55,
        color: colors.accent,
      ),
    );
  }
}

class _EnableButton extends StatelessWidget {
  const _EnableButton({required this.requesting, required this.onPressed});

  final bool requesting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = readableActionForeground(colors, colors.accent);
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        backgroundColor: colors.accent,
        foregroundColor: foreground,
      ),
      onPressed: requesting ? null : onPressed,
      icon: requesting
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : const Icon(Icons.notifications_rounded, size: 16),
      label: Text(requesting ? 'Opening...' : 'Turn on'),
    );
  }
}
