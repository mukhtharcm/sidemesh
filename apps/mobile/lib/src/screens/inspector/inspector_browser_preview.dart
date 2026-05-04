import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models.dart';
import 'inspector_controller.dart';
import '../browser_preview_screen.dart';

InspectorSurface buildInspectorBrowserPreviewSurface({
  required String ownerKey,
  required HostProfile host,
  required ApiClient api,
  required HostBrowserPreviewInfo preview,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.browserPreview,
    ownerKey: ownerKey,
    title: preview.url,
    icon: Icons.open_in_browser_rounded,
    bodyBuilder: (context) => BrowserPreviewPane(
      host: host,
      api: api,
      preview: preview,
      showHeader: false,
    ),
  );
}
