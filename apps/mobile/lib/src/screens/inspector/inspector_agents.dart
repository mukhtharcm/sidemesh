import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models.dart';
import '../agent_runs_screen.dart';
import 'inspector_controller.dart';

InspectorSurface buildInspectorAgentsSurface({
  required String ownerKey,
  required HostProfile host,
  required SessionSummary session,
  required ApiClient api,
}) {
  return InspectorSurface(
    kind: InspectorSurfaceKind.agents,
    ownerKey: ownerKey,
    title: 'Agents',
    icon: Icons.account_tree_rounded,
    bodyBuilder: (_) => AgentRunsView(host: host, session: session, api: api),
  );
}
