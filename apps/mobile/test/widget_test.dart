import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sidemesh_mobile/main.dart';

void main() {
  testWidgets('renders app shell', (tester) async {
    await tester.pumpWidget(const SidemeshApp());

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Recent'), findsWidgets);
    expect(find.text('Inbox'), findsWidgets);
    expect(find.text('Hosts'), findsWidgets);
  });
}
