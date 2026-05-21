import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models.dart';
import 'inspector_controller.dart';
import '../browser_preview_screen.dart';
import '../../app_icons.dart';

InspectorSurface buildInspectorBrowserPreviewSurface({
  required String ownerKey,
  required HostProfile host,
  required ApiClient api,
  required HostBrowserPreviewInfo preview,
  VoidCallback? onOpenInWindow,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.browserPreview,
    ownerKey: ownerKey,
    title: preview.url,
    icon: AppIcons.open_in_browser_rounded,
    actionsBuilder: onOpenInWindow == null
        ? null
        : (context) => <Widget>[
            IconButton(
              tooltip: 'Open in separate window',
              onPressed: onOpenInWindow,
              icon: const Icon(AppIcons.open_in_new_rounded, size: 18),
              visualDensity: VisualDensity.compact,
            ),
          ],
    bodyBuilder: (context) => BrowserPreviewPane(
      host: host,
      api: api,
      preview: preview,
      showHeader: false,
    ),
  );
}
