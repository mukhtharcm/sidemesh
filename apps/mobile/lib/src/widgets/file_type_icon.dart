import 'package:flutter/material.dart' hide Icons;
import 'phosphor_icons.dart';

/// Maps a filename to a themed file-type icon.
///
/// Uses a compact, curated Phosphor map instead of importing a second icon
/// family just for the file browser.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon(this.filename, {super.key, this.size = 16});

  final String filename;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ext = _extension(filename);
    final colors = Theme.of(context).colorScheme;
    final icon = _iconForExtension(ext);
    final color = _colorForExtension(ext, colors);
    return Icon(icon, size: size, color: color);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _extension(String filename) {
  final name = filename.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
}

IconData _iconForExtension(String ext) => switch (ext) {
  'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'svg' => Icons.image_rounded,
  'mp3' || 'wav' || 'flac' || 'ogg' => Icons.audio_file_rounded,
  'mp4' || 'mov' || 'webm' => Icons.perm_media_rounded,
  'pdf' => Icons.picture_as_pdf_rounded,
  'zip' || 'tar' || 'gz' || 'tgz' || 'rar' || '7z' => Icons.archive_rounded,
  'db' || 'sqlite' || 'sql' || 'prisma' || 'surql' => Icons.storage_rounded,
  'json' || 'yaml' || 'yml' || 'toml' || 'ini' || 'env' || 'lock' =>
    Icons.tune_rounded,
  'md' || 'mdx' || 'txt' => Icons.description_rounded,
  'sh' || 'bash' || 'zsh' || 'fish' => Icons.terminal_rounded,
  'dart' ||
  'ts' ||
  'tsx' ||
  'js' ||
  'jsx' ||
  'html' ||
  'css' ||
  'scss' ||
  'rs' ||
  'go' ||
  'py' ||
  'rb' ||
  'java' ||
  'kt' ||
  'swift' ||
  'c' ||
  'cc' ||
  'cpp' ||
  'h' ||
  'hpp' ||
  'zig' ||
  'gleam' ||
  'mojo' ||
  'cairo' ||
  'move' ||
  'motoko' ||
  'v' ||
  'odin' ||
  'astro' ||
  'svelte' =>
    Icons.code_rounded,
  _ => Icons.insert_drive_file_rounded,
};

Color _colorForExtension(String ext, ColorScheme colors) => switch (ext) {
  'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'svg' =>
    colors.primary.withValues(alpha: 0.78),
  'db' || 'sqlite' || 'sql' || 'prisma' || 'surql' =>
    colors.secondary.withValues(alpha: 0.82),
  'json' || 'yaml' || 'yml' || 'toml' || 'ini' || 'env' || 'lock' =>
    colors.onSurface.withValues(alpha: 0.58),
  _ => colors.onSurface.withValues(alpha: 0.64),
};
