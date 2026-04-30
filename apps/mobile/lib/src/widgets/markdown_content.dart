import 'package:flutter/material.dart';
import 'package:flutter_smooth_markdown/flutter_smooth_markdown.dart' as smooth;
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'app_snackbar.dart';
import 'syntax_code_block.dart';

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({
    super.key,
    required this.text,
    required this.textColor,
    this.onOpenFile,
  });

  final String text;
  final Color textColor;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final baseBody =
        theme.textTheme.bodyMedium?.copyWith(color: textColor, height: 1.5) ??
        TextStyle(color: textColor, height: 1.5);
    final markdownText = _normalizeTildeFencesForSmoothMarkdown(
      _autoLinkBareUrlsForMarkdown(text),
    );
    final inlineCodeStyle = monoStyle(color: colors.accent, fontSize: 12.5)
        .copyWith(
          backgroundColor: colors.accentMuted.withValues(alpha: 0.22),
          decorationColor: colors.accent,
        );

    return smooth.SmoothMarkdown(
      data: markdownText,
      styleSheet: _styleSheetFor(context, baseBody, inlineCodeStyle),
      onTapLink: (href) {
        if (href.trim().isEmpty) return;
        _openLink(context, href);
      },
      codeBuilder: (code, language) {
        final normalizedLanguage = _normalizedCodeLanguage(language);
        if (normalizedLanguage == 'mermaid') {
          return _MermaidCodeBlock(
            code: code.trimRight(),
            textColor: textColor,
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SyntaxCodeBlock(
            text: code.trimRight(),
            language: language?.trim().isEmpty ?? true
                ? null
                : language?.trim(),
          ),
        );
      },
      builderRegistry: smooth.BuilderRegistry()
        ..register(
          'inline_code',
          _SidemeshInlineCodeBuilder(
            onOpenFile: onOpenFile,
            style: inlineCodeStyle,
          ),
        ),
    );
  }
}

smooth.MarkdownStyleSheet _styleSheetFor(
  BuildContext context,
  TextStyle baseBody,
  TextStyle inlineCodeStyle,
) {
  final theme = Theme.of(context);
  final colors = context.colors;
  final headerColor = baseBody.color ?? colors.textPrimary;
  final codeStyle = monoStyle(color: colors.codeForeground, fontSize: 12.5);

  return smooth.MarkdownStyleSheet.fromTheme(theme).copyWith(
    textStyle: baseBody,
    paragraphStyle: baseBody,
    h1Style: baseBody.copyWith(
      color: headerColor,
      fontSize: 24,
      fontWeight: FontWeight.w800,
      height: 1.25,
      letterSpacing: -0.35,
    ),
    h2Style: baseBody.copyWith(
      color: headerColor,
      fontSize: 21,
      fontWeight: FontWeight.w800,
      height: 1.28,
      letterSpacing: -0.25,
    ),
    h3Style: baseBody.copyWith(
      color: headerColor,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.32,
    ),
    h4Style: baseBody.copyWith(
      color: headerColor,
      fontSize: 16,
      fontWeight: FontWeight.w700,
      height: 1.35,
    ),
    h5Style: baseBody.copyWith(
      color: headerColor,
      fontSize: 14.5,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
    h6Style: baseBody.copyWith(
      color: colors.textSecondary,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1.4,
    ),
    blockquoteStyle: baseBody.copyWith(color: colors.textSecondary),
    codeBlockStyle: codeStyle,
    inlineCodeStyle: inlineCodeStyle,
    linkStyle: baseBody.copyWith(
      color: colors.accent,
      decoration: TextDecoration.underline,
      decorationColor: colors.accent,
    ),
    boldStyle: baseBody.copyWith(fontWeight: FontWeight.w800),
    italicStyle: baseBody.copyWith(fontStyle: FontStyle.italic),
    strikethroughStyle: baseBody.copyWith(
      decoration: TextDecoration.lineThrough,
    ),
    listBulletStyle: baseBody,
    tableHeaderStyle: baseBody.copyWith(fontWeight: FontWeight.w800),
    tableCellStyle: baseBody,
    blockquoteDecoration: BoxDecoration(
      color: colors.surfaceMuted.withValues(alpha: 0.55),
      border: Border(left: BorderSide(color: colors.accent, width: 3)),
      borderRadius: BorderRadius.circular(12),
    ),
    codeBlockDecoration: BoxDecoration(
      color: colors.codeBackground,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: colors.codeBorder),
    ),
    tableBorder: TableBorder.all(color: colors.border),
    tableHeaderDecoration: BoxDecoration(color: colors.surfaceMuted),
    tableOddRowDecoration: BoxDecoration(color: colors.surface),
    tableEvenRowDecoration: BoxDecoration(color: colors.surfaceMuted),
    horizontalRuleColor: colors.border,
    horizontalRuleThickness: 1,
    blockSpacing: 12,
    listIndent: 22,
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    codeBlockPadding: const EdgeInsets.all(12),
    tableCellPadding: const EdgeInsets.all(8),
  );
}

class _SidemeshInlineCodeBuilder extends smooth.MarkdownWidgetBuilder {
  const _SidemeshInlineCodeBuilder({
    required this.onOpenFile,
    required this.style,
  });

  final void Function(String path)? onOpenFile;
  final TextStyle style;

  @override
  bool canBuild(smooth.MarkdownNode node) => node is smooth.InlineCodeNode;

  @override
  Widget build(
    smooth.MarkdownNode node,
    smooth.MarkdownStyleSheet styleSheet,
    smooth.MarkdownRenderContext context,
  ) {
    final code = (node as smooth.InlineCodeNode).code;
    final isPath = onOpenFile != null && _looksLikeFilePath(code);
    final displayStyle = style.copyWith(
      decoration: isPath ? TextDecoration.underline : style.decoration,
    );
    final child = Text(code, style: displayStyle);
    if (!isPath) return child;
    return GestureDetector(onTap: () => onOpenFile!(code), child: child);
  }
}

class _MermaidCodeBlock extends StatelessWidget {
  const _MermaidCodeBlock({required this.code, required this.textColor});

  final String code;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final diagramStyle = smooth.MermaidStyle(
      backgroundColor: colors.surfaceElevated.toARGB32(),
      defaultNodeStyle: smooth.NodeStyle(
        fillColor: colors.surfaceMuted.toARGB32(),
        strokeColor: colors.accent.toARGB32(),
        textColor: colors.textPrimary.toARGB32(),
      ),
      defaultEdgeStyle: smooth.EdgeStyle(
        strokeColor: colors.textSecondary.toARGB32(),
      ),
      fontFamily: 'SpaceGrotesk',
      themeMode: Theme.of(context).brightness == Brightness.dark
          ? smooth.MermaidThemeMode.dark
          : smooth.MermaidThemeMode.light,
      nodeSpacingX: 46,
      nodeSpacingY: 46,
      padding: 18,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: colors.surfaceElevated,
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(12),
          child: smooth.MermaidDiagram(
            code: code,
            style: diagramStyle,
            errorBuilder: (context, error) =>
                SyntaxCodeBlock(text: code, language: 'mermaid'),
            loadingBuilder: (context) => Text(
              'Rendering diagram...',
              style: monoStyle(color: textColor, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openLink(BuildContext context, String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    showAppSnackBar(context, 'Could not open link');
  }
}

String _autoLinkBareUrlsForMarkdown(String text) {
  if (text.isEmpty || !_urlRegExp.hasMatch(text)) {
    return text;
  }

  final output = StringBuffer();
  final fenceMatches = _fencedCodeRegExp.allMatches(text).toList();
  var cursor = 0;

  for (final match in fenceMatches) {
    if (match.start > cursor) {
      output.write(
        _autoLinkBareUrlsOutsideInlineCode(text.substring(cursor, match.start)),
      );
    }
    output.write(match.group(0)!);
    cursor = match.end;
  }

  if (cursor < text.length) {
    output.write(_autoLinkBareUrlsOutsideInlineCode(text.substring(cursor)));
  }

  return output.toString();
}

String _normalizeTildeFencesForSmoothMarkdown(String text) {
  if (text.isEmpty || !text.contains('~~~')) return text;

  final lines = text.split('\n');
  final output = <String>[];
  var insideBacktickFence = false;
  var insideTildeFence = false;

  for (final line in lines) {
    final trimmedLeft = line.trimLeft();
    if (!insideTildeFence && trimmedLeft.startsWith('```')) {
      insideBacktickFence = !insideBacktickFence;
      output.add(line);
      continue;
    }

    if (!insideBacktickFence && trimmedLeft.startsWith('~~~')) {
      final indent = line.substring(0, line.length - trimmedLeft.length);
      output.add('$indent```${trimmedLeft.substring(3)}');
      insideTildeFence = !insideTildeFence;
      continue;
    }

    output.add(line);
  }

  return output.join('\n');
}

String? _normalizedCodeLanguage(String? language) {
  final trimmed = language?.trim().toLowerCase();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.split(RegExp(r'\s+')).first;
}

String _autoLinkBareUrlsOutsideInlineCode(String text) {
  if (text.isEmpty || !_urlRegExp.hasMatch(text)) {
    return text;
  }

  final output = StringBuffer();
  final inlineCodeMatches = _inlineCodeRegExp.allMatches(text).toList();
  var cursor = 0;

  for (final match in inlineCodeMatches) {
    if (match.start > cursor) {
      output.write(
        _wrapBareUrlsAsMarkdownLinks(text.substring(cursor, match.start)),
      );
    }
    output.write(match.group(0)!);
    cursor = match.end;
  }

  if (cursor < text.length) {
    output.write(_wrapBareUrlsAsMarkdownLinks(text.substring(cursor)));
  }

  return output.toString();
}

String _wrapBareUrlsAsMarkdownLinks(String text) {
  if (text.isEmpty || !_urlRegExp.hasMatch(text)) {
    return text;
  }

  final output = StringBuffer();
  var cursor = 0;
  for (final match in _bareMarkdownUrlRegExp.allMatches(text)) {
    final raw = match.group(0);
    if (raw == null || raw.isEmpty) continue;
    if (match.start > cursor) {
      output.write(text.substring(cursor, match.start));
    }

    final trimmed = raw.replaceAll(RegExp(r'[),.!?;:\]]+$'), '');
    if (trimmed.isEmpty) {
      output.write(raw);
      cursor = match.end;
      continue;
    }

    final trailing = raw.substring(trimmed.length);
    final href = trimmed.startsWith('www.') ? 'https://$trimmed' : trimmed;
    output.write('[$trimmed]($href)');
    output.write(trailing);
    cursor = match.end;
  }

  if (cursor < text.length) {
    output.write(text.substring(cursor));
  }

  return output.toString();
}

bool _looksLikeFilePath(String text) {
  if (text.isEmpty) return false;
  if (text.startsWith('http://') || text.startsWith('https://')) return false;
  if (!text.contains('/')) return false;
  if (text.startsWith('./') || text.startsWith('../')) return true;
  if (text.startsWith('/')) {
    return _hasKnownExtension(text);
  }
  return _hasKnownExtension(text);
}

bool _hasKnownExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  final ext = path.substring(dot + 1).toLowerCase();
  const knownExts = {
    'dart',
    'ts',
    'tsx',
    'js',
    'mjs',
    'cjs',
    'jsx',
    'json',
    'yaml',
    'yml',
    'toml',
    'md',
    'markdown',
    'html',
    'htm',
    'xml',
    'svg',
    'css',
    'scss',
    'less',
    'py',
    'go',
    'rs',
    'rb',
    'java',
    'kt',
    'swift',
    'c',
    'h',
    'cpp',
    'cc',
    'cxx',
    'cs',
    'sh',
    'bash',
    'zsh',
    'fish',
    'txt',
    'env',
    'lock',
    'gradle',
    'properties',
    'proto',
    'graphql',
    'sql',
  };
  return knownExts.contains(ext);
}

final RegExp _urlRegExp = RegExp(
  r'(https?:\/\/[^\s<>]+|www\.[^\s<>]+)',
  caseSensitive: false,
);

final RegExp _bareMarkdownUrlRegExp = RegExp(
  r'(?<!\]\()(?<!\[)(https?:\/\/[^\s<>]+|www\.[^\s<>]+)',
  caseSensitive: false,
);
final RegExp _fencedCodeRegExp = RegExp(
  r'(```[\s\S]*?```|~~~[\s\S]*?~~~)',
  multiLine: true,
);
final RegExp _inlineCodeRegExp = RegExp(r'(``[^`\n]*``|`[^`\n]*`)');
