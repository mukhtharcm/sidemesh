part of 'session_screen.dart';

class _StopAgentPill extends StatelessWidget {
  const _StopAgentPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = readableTextOn(
      colors,
      background: colors.danger,
      preferred: colors.accentOn,
    );
    return Material(
      color: colors.danger,
      shape: const StadiumBorder(),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.24),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.stop_circle_rounded,
                size: 16,
                color: foreground,
              ),
              const SizedBox(width: 6),
              Text(
                'Stop agent',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
