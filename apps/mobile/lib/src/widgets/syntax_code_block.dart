import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A code block that renders syntax-highlighted text with the Sidemesh
/// terminal aesthetic.
///
/// - Dark theme: atom-one-dark syntax palette.
/// - Light theme: GitHub light syntax palette.
/// - Language is optional; when unknown we fall back to plaintext.
class SyntaxCodeBlock extends StatelessWidget {
  const SyntaxCodeBlock({
    super.key,
    required this.text,
    this.language,
    this.showLanguageBadge = true,
    this.padding = const EdgeInsets.fromLTRB(14, 12, 14, 12),
  });

  final String text;
  final String? language;
  final bool showLanguageBadge;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = isDark ? _tuneTheme(atomOneDarkTheme, colors)
                         : _tuneTheme(githubTheme, colors);
    final lang = _normalizeLanguage(language);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.codeBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showLanguageBadge && lang != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colors.border),
                    ),
                    child: Text(
                      lang,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ).copyWith(letterSpacing: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: padding,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: HighlightView(
                text,
                language: lang ?? 'plaintext',
                theme: theme,
                padding: EdgeInsets.zero,
                textStyle: monoStyle(
                  color: colors.codeForeground,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, TextStyle> _tuneTheme(
  Map<String, TextStyle> base,
  AppColors colors,
) {
  return {
    ...base,
    'root': (base['root'] ?? const TextStyle()).copyWith(
      backgroundColor: Colors.transparent,
      color: colors.codeForeground,
    ),
  };
}

/// Best-effort language normalization.  Returns null when we should fall back
/// to plaintext.
String? _normalizeLanguage(String? language) {
  if (language == null) {
    return null;
  }
  final lower = language.toLowerCase().trim();
  if (lower.isEmpty) {
    return null;
  }
  return switch (lower) {
    'js' || 'mjs' || 'cjs' => 'javascript',
    'ts' || 'tsx' => 'typescript',
    'jsx' => 'javascript',
    'py' => 'python',
    'rb' => 'ruby',
    'rs' => 'rust',
    'kt' || 'kts' => 'kotlin',
    'md' => 'markdown',
    'yml' => 'yaml',
    'sh' || 'bash' || 'zsh' => 'bash',
    'dockerfile' => 'dockerfile',
    'html' || 'htm' => 'xml',
    _ => lower,
  };
}

/// Detect a language hint from a file path or a shell command.
String? detectLanguage({String? path, String? command}) {
  if (path != null && path.isNotEmpty) {
    final dot = path.lastIndexOf('.');
    if (dot != -1 && dot < path.length - 1) {
      return path.substring(dot + 1).toLowerCase();
    }
    final lower = path.toLowerCase();
    if (lower.endsWith('dockerfile')) {
      return 'dockerfile';
    }
    if (lower.endsWith('makefile')) {
      return 'makefile';
    }
  }
  if (command != null && command.isNotEmpty) {
    return 'bash';
  }
  return null;
}
