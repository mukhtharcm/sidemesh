import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
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
    final baseBody = theme.textTheme.bodyMedium?.copyWith(
      color: textColor,
      height: 1.5,
    );
    final markdownText = _autoLinkBareUrlsForMarkdown(text);

    return GptMarkdown(
      markdownText,
      style: baseBody,
      followLinkColor: false,
      onLinkTap: (href, title) {
        if (href.isEmpty) return;
        _openLink(context, href);
      },
      linkBuilder: (context, linkText, url, style) {
        return Text.rich(
          TextSpan(
            children: [linkText],
            style: style.copyWith(
              color: colors.accent,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      },
      codeBuilder: (context, name, code, closed) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SyntaxCodeBlock(
            text: code.trimRight(),
            language: name.isEmpty ? null : name,
          ),
        );
      },
      highlightBuilder: (context, hlText, style) {
        final isPath = onOpenFile != null && _looksLikeFilePath(hlText);
        final displayStyle =
            monoStyle(
              color: isPath ? colors.textPrimary : colors.textSecondary,
              fontSize: 12.5,
            ).copyWith(
              decoration: isPath ? TextDecoration.underline : null,
              decorationColor: isPath ? colors.textSecondary : null,
            );
        if (isPath) {
          return GestureDetector(
            onTap: () => onOpenFile!(hlText),
            child: Text(hlText, style: displayStyle),
          );
        }
        return Text(hlText, style: displayStyle);
      },
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
