import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models.dart';
import '../browser_tabs_screen.dart';
import 'inspector_controller.dart';

InspectorSurface buildInspectorBrowserTabsSurface({
  required String ownerKey,
  required HostProfile host,
  required ApiClient api,
  required SessionSummary session,
  BrowserTabOpened? onBrowserOpened,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.browserTabs,
    ownerKey: ownerKey,
    title: 'Browser',
    icon: Icons.open_in_browser_rounded,
    bodyBuilder: (context) => BrowserTabsPane(
      key: ValueKey('browser-tabs:${host.id}:${session.id}:${session.cwd}'),
      host: host,
      api: api,
      cwd: session.cwd,
      sessionId: session.id,
      presentation: BrowserTabsPresentation.inline,
      onBrowserOpened: onBrowserOpened,
    ),
  );
}
