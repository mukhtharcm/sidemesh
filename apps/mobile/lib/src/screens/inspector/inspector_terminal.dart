import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models.dart';
import '../terminal_screen.dart';
import 'inspector_controller.dart';

InspectorSurface buildInspectorTerminalSurface({
  required String ownerKey,
  required HostProfile host,
  required ApiClient api,
  required SessionSummary session,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.terminal,
    ownerKey: ownerKey,
    title: 'Terminal',
    icon: Icons.terminal_rounded,
    bodyBuilder: (context) => TerminalPane(
      key: ValueKey('terminal:${host.id}:${session.id}:${session.cwd}'),
      host: host,
      api: api,
      cwd: session.cwd,
      sessionId: session.id,
      title: session.title,
      reuseExisting: true,
      compact: true,
    ),
  );
}
