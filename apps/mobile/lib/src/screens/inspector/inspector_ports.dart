import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models.dart';
import '../port_forward_screen.dart';
import 'inspector_controller.dart';

InspectorSurface buildInspectorPortsSurface({
  required String ownerKey,
  required HostProfile host,
  required ApiClient api,
  required SessionSummary session,
  required bool supportsBrowserPreview,
  required bool supportsPortForwarding,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.ports,
    ownerKey: ownerKey,
    title: portForwardScreenTitle(
      supportsBrowserPreview: supportsBrowserPreview,
      supportsPortForwarding: supportsPortForwarding,
    ),
    icon: Icons.cable_rounded,
    bodyBuilder: (context) => PortForwardPane(
      key: ValueKey('ports:${host.id}:${session.id}:${session.cwd}'),
      host: host,
      api: api,
      cwd: session.cwd,
      sessionId: session.id,
      sessionTitle: session.title,
      supportsBrowserPreview: supportsBrowserPreview,
      supportsPortForwarding: supportsPortForwarding,
      previewPresentation: PortForwardPreviewPresentation.inline,
    ),
  );
}
