import 'package:flutter/material.dart';
import 'package:flutter_smooth_markdown/flutter_smooth_markdown.dart' as smooth;
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/widgets/markdown_content.dart';
import 'package:sidemesh_mobile/src/widgets/syntax_code_block.dart';

void main() {
  testWidgets('renders fenced code blocks with the Sidemesh code widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Host(
        child: MarkdownContent(
          text: '```dart\nvoid main() {}\n```',
          textColor: ThemeVariant.codexAmber.light.textPrimary,
        ),
      ),
    );

    expect(find.byType(SyntaxCodeBlock), findsOneWidget);
    expect(find.textContaining('void main'), findsOneWidget);
  });

  testWidgets('normalizes tilde fences for the SmoothMarkdown parser', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Host(
        child: MarkdownContent(
          text: '~~~dart\nfinal ok = true;\n~~~',
          textColor: ThemeVariant.codexAmber.light.textPrimary,
        ),
      ),
    );

    expect(find.byType(SyntaxCodeBlock), findsOneWidget);
    expect(find.textContaining('final ok'), findsOneWidget);
  });

  testWidgets('keeps inline file paths tappable', (tester) async {
    String? openedPath;

    await tester.pumpWidget(
      _Host(
        child: MarkdownContent(
          text: 'Open `lib/main.dart` please.',
          textColor: ThemeVariant.codexAmber.light.textPrimary,
          onOpenFile: (path) => openedPath = path,
        ),
      ),
    );

    await tester.tap(find.text('lib/main.dart'));

    expect(openedPath, 'lib/main.dart');
  });

  testWidgets('renders mermaid fences with the native diagram widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Host(
        child: MarkdownContent(
          text: '''
```mermaid
flowchart TD
  A[Start] --> B[Done]
```
''',
          textColor: ThemeVariant.codexAmber.light.textPrimary,
        ),
      ),
    );

    expect(find.byType(smooth.MermaidDiagram), findsOneWidget);
  });
}

class _Host extends StatelessWidget {
  const _Host({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildLightTheme(ThemeVariant.codexAmber.light),
      home: Scaffold(body: Center(child: child)),
    );
  }
}
