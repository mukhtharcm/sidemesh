import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../theme/color_contrast.dart';
import 'app_snackbar.dart';
import 'syntax_code_block.dart';

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({
    super.key,
    required this.text,
    required this.textColor,
    this.backgroundColor,
    this.linkStyle,
    this.onOpenFile,
    this.host,
    this.api,
    this.sessionId,
  });

  final String text;
  final Color textColor;
  final Color? backgroundColor;
  final TextStyle? linkStyle;
  final void Function(String path)? onOpenFile;
  final HostProfile? host;
  final ApiClient? api;
  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final baseBody = theme.textTheme.bodyMedium?.copyWith(
      color: textColor,
      height: 1.5,
    );
    final markdownText = _autoLinkBareUrlsForMarkdown(text);
    final linkBackground = backgroundColor ?? colors.surface;
    final fallbackLinkColor = readableLinkOn(
      colors,
      background: linkBackground,
    );

    return GptMarkdown(
      markdownText,
      style: baseBody,
      followLinkColor: false,
      onLinkTap: (href, title) {
        if (href.isEmpty) return;
        final localPath = _localMarkdownPath(href);
        if (localPath != null && onOpenFile != null) {
          onOpenFile!(localPath);
          return;
        }
        _openLink(context, href);
      },
      linkBuilder: (context, linkText, url, style) {
        final linkColor = linkStyle?.color ?? fallbackLinkColor;
        final effectiveLinkStyle = style
            .merge(linkStyle)
            .copyWith(
              color: linkColor,
              decoration: linkStyle?.decoration ?? TextDecoration.underline,
              decorationColor: linkStyle?.decorationColor ?? linkColor,
              decorationThickness: linkStyle?.decorationThickness ?? 1.2,
            );
        return Text.rich(
          TextSpan(children: [linkText], style: effectiveLinkStyle),
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
      imageBuilder: (context, imageUrl, width, height) {
        return _MarkdownImage(
          source: imageUrl,
          width: width,
          height: height,
          host: host,
          api: api,
          sessionId: sessionId,
        );
      },
    );
  }
}

class _MarkdownImage extends StatefulWidget {
  const _MarkdownImage({
    required this.source,
    required this.width,
    required this.height,
    required this.host,
    required this.api,
    required this.sessionId,
  });

  final String source;
  final double? width;
  final double? height;
  final HostProfile? host;
  final ApiClient? api;
  final String? sessionId;

  @override
  State<_MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<_MarkdownImage> {
  ImageProvider<Object>? _provider;
  Object? _error;
  int _loadGeneration = 0;

  bool get _isLocal => _localMarkdownPath(widget.source) != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _MarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.host?.id != widget.host?.id ||
        oldWidget.host?.baseUrl != widget.host?.baseUrl ||
        oldWidget.host?.token != widget.host?.token ||
        oldWidget.api != widget.api ||
        oldWidget.sessionId != widget.sessionId) {
      _load();
    }
  }

  void _load() {
    final generation = ++_loadGeneration;
    _provider = null;
    _error = null;
    final source = widget.source.trim();
    final localPath = _localMarkdownPath(source);
    if (localPath != null) {
      final host = widget.host;
      final api = widget.api;
      if (host == null || api == null || (widget.sessionId ?? '').isEmpty) {
        _error = StateError('Image is not attached to a session workspace');
        return;
      }
      api
          .fetchFsBlob(host, localPath, sessionId: widget.sessionId)
          .then((bytes) {
            if (!mounted || generation != _loadGeneration) return;
            setState(() => _provider = MemoryImage(bytes));
          })
          .catchError((Object error) {
            if (!mounted || generation != _loadGeneration) return;
            setState(() => _error = error);
          });
      return;
    }
    if (source.startsWith('data:image/')) {
      try {
        final comma = source.indexOf(',');
        if (comma <= 0 || !source.substring(0, comma).contains(';base64')) {
          throw const FormatException('Unsupported image data URL');
        }
        final bytes = base64Decode(source.substring(comma + 1));
        _provider = MemoryImage(Uint8List.fromList(bytes));
      } catch (error) {
        _error = error;
      }
      return;
    }
    final uri = Uri.tryParse(source);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      _provider = NetworkImage(source);
      return;
    }
    _error = StateError('Unsupported image source');
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null) {
      return _MarkdownImageStatus(
        source: widget.source,
        loading: _error == null,
        onRetry: _error == null ? null : () => setState(_load),
      );
    }

    final maxWidth = (widget.width ?? 680).clamp(80, 680).toDouble();
    final maxHeight = (widget.height ?? 420).clamp(80, 420).toDouble();
    return Semantics(
      image: true,
      label: 'Image: ${_markdownImageLabel(widget.source)}',
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image(
            image: provider,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return _MarkdownImageStatus(source: widget.source, loading: true);
            },
            errorBuilder: (context, error, stackTrace) {
              return _MarkdownImageStatus(
                source: widget.source,
                loading: false,
                onRetry: _isLocal ? () => setState(_load) : null,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MarkdownImageStatus extends StatelessWidget {
  const _MarkdownImageStatus({
    required this.source,
    required this.loading,
    this.onRetry,
  });

  final String source;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = _markdownImageLabel(source);
    return Semantics(
      label: loading ? 'Loading image $label' : 'Image unavailable: $label',
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 180,
          maxWidth: 360,
          minHeight: 58,
          maxHeight: 72,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.accent,
                    ),
                  )
                else
                  Icon(
                    Icons.image_not_supported_outlined,
                    size: 20,
                    color: colors.textSecondary,
                  ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loading ? 'Loading image...' : 'Image unavailable',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: AppWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onRetry != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Retry image',
                    visualDensity: VisualDensity.compact,
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? _localMarkdownPath(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('<') && value.endsWith('>')) {
    value = value.substring(1, value.length - 1).trim();
  }
  final fileUri = Uri.tryParse(value);
  if (fileUri?.scheme == 'file') {
    try {
      return fileUri!.toFilePath();
    } catch (_) {
      return null;
    }
  }
  final isLocal =
      value.startsWith('/') ||
      value.startsWith('./') ||
      value.startsWith('../') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  if (!isLocal) return null;
  try {
    return Uri.decodeFull(value);
  } catch (_) {
    return value;
  }
}

String _markdownImageLabel(String source) {
  final local = _localMarkdownPath(source);
  if (local != null) {
    final normalized = local.replaceAll('\\', '/');
    final segments = normalized.split('/').where((part) => part.isNotEmpty);
    return segments.isEmpty ? local : segments.last;
  }
  final uri = Uri.tryParse(source);
  if (uri != null && uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.last;
  }
  return 'Image';
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
