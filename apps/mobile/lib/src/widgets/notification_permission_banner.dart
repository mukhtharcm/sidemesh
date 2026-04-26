import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../local_notification_service.dart';
import '../theme/app_colors.dart';

class NotificationPermissionBanner extends StatefulWidget {
  const NotificationPermissionBanner({
    super.key,
    this.margin = const EdgeInsets.fromLTRB(16, 6, 16, 8),
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Notifications were not enabled. You can turn them on later in system settings.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    final colors = context.colors;
    return Padding(
      padding: widget.margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.accentMuted,
          borderRadius: BorderRadius.circular(widget.compact ? 14 : 18),
          border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            widget.compact ? 12 : 14,
            widget.compact ? 10 : 12,
            widget.compact ? 8 : 10,
            widget.compact ? 10 : 12,
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BellBadge(colors: colors),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enable approval alerts',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Get notified when an agent session is waiting for permission.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: _EnableButton(
                  requesting: requesting,
                  onPressed: onEnable,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Dismiss',
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
                'Enable approval alerts',
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
          'Notify me when an agent needs approval.',
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
        Icons.notifications_active_outlined,
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
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        backgroundColor: colors.accent,
        foregroundColor: colors.accentOn,
      ),
      onPressed: requesting ? null : onPressed,
      icon: requesting
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accentOn,
              ),
            )
          : const Icon(Icons.notifications_rounded, size: 16),
      label: Text(requesting ? 'Opening...' : 'Enable'),
    );
  }
}
