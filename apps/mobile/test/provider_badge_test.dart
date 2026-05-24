import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/provider_badge.dart';

void main() {
  testWidgets('AgentProviderBadge renders known provider labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: const Scaffold(body: AgentProviderBadge(providerKind: 'copilot')),
      ),
    );

    expect(find.text('GitHub Copilot'), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('AgentProviderBadge renders nothing without a provider', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(ThemeVariant.codexAmber.light),
        home: const Scaffold(body: AgentProviderBadge(providerKind: null)),
      ),
    );

    expect(find.byType(SizedBox), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });
}
