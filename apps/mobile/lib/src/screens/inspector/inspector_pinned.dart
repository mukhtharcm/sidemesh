import 'package:flutter/material.dart' hide Icons;
import '../../widgets/phosphor_icons.dart';

import '../../session_pins_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/mesh_widgets.dart';
import 'inspector_controller.dart';

/// Builds an [InspectorSurface] that hosts the pinned-messages list in
/// pane 3. Passes [refresh] through so the body rebuilds when the pins
/// store notifies (pin/unpin from elsewhere in the app).
InspectorSurface buildInspectorPinnedSurface({
  required String ownerKey,
  required List<PinnedSessionMessage> Function() pinsBuilder,
  required ValueChanged<PinnedSessionMessage> onOpen,
  required ValueChanged<PinnedSessionMessage> onUnpin,
  Listenable? refresh,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.pinned,
    ownerKey: ownerKey,
    title: 'Saved messages',
    icon: Icons.push_pin_rounded,
    bodyBuilder: (context) {
      Widget buildPanel() => PinnedListPanel(
        pins: pinsBuilder(),
        onOpen: onOpen,
        onUnpin: onUnpin,
      );
      if (refresh == null) return buildPanel();
      return ListenableBuilder(
        listenable: refresh,
        builder: (context, _) => buildPanel(),
      );
    },
  );
}

/// Vertical, full-width list of pinned messages. Used both as the body
/// of the desktop inspector surface and as the body of the mobile
/// bottom sheet, so the two surfaces render identical content.
class PinnedListPanel extends StatelessWidget {
  const PinnedListPanel({
    super.key,
    required this.pins,
    required this.onOpen,
    required this.onUnpin,
  });

  final List<PinnedSessionMessage> pins;
  final ValueChanged<PinnedSessionMessage> onOpen;
  final ValueChanged<PinnedSessionMessage> onUnpin;

  @override
  Widget build(BuildContext context) {
    if (pins.isEmpty) {
      return const MeshEmptyState.compact(
        icon: Icons.push_pin_rounded,
        title: 'Nothing saved yet',
        body: 'Pin a message to keep it easy to find.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: pins.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final pin = pins[index];
        return _PinnedListTile(
          pin: pin,
          onOpen: () => onOpen(pin),
          onUnpin: () => onUnpin(pin),
        );
      },
    );
  }
}

class _PinnedListTile extends StatelessWidget {
  const _PinnedListTile({
    required this.pin,
    required this.onOpen,
    required this.onUnpin,
  });

  final PinnedSessionMessage pin;
  final VoidCallback onOpen;
  final VoidCallback onUnpin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final roleIcon = pin.role == 'assistant'
        ? Icons.smart_toy_rounded
        : Icons.person_outline_rounded;
    return MeshSurface(
      onTap: onOpen,
      radius: AppRadii.control,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(roleIcon, size: 14, color: colors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  pin.roleLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: AppWeights.emphasis,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Tooltip(
                message: 'Unpin',
                child: InkResponse(
                  radius: 22,
                  onTap: onUnpin,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: colors.textTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            pin.preview,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textPrimary,
              height: 1.35,
            ),
          ),
          if (pin.attachmentCount > 0 || pin.textTruncated) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (pin.attachmentCount > 0)
                  MeshPill(
                    label:
                        '${pin.attachmentCount} attachment'
                        '${pin.attachmentCount == 1 ? '' : 's'}',
                    icon: Icons.attachment_rounded,
                  ),
                if (pin.textTruncated)
                  const MeshPill(
                    label: 'truncated',
                    icon: Icons.content_cut_rounded,
                    tone: MeshPillTone.warning,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
