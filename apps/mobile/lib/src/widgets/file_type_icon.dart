import 'package:file_icon/file_icon.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

/// Maps a filename to a themed file-type icon.
///
/// Uses the [file_icon] Seti UI font set (252 extensions, same as VS Code's
/// built-in sidebar) as the primary source.  A hand-curated override map
/// covers newer extensions that [file_icon] doesn't know about, rendered with
/// a matching [HugeIcons] glyph and the ambient [colorScheme] colours so they
/// stay consistent with the rest of the UI.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon(this.filename, {super.key, this.size = 16});

  final String filename;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ext = _extension(filename);
    final override = _hugeIconForExtension(ext, size, context);
    if (override != null) return override;
    return FileIcon(filename, size: size);
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

/// Returns a [HugeIcon] for newer / niche extensions not in the Seti UI set,
/// or [null] to fall through to [file_icon].
Widget? _hugeIconForExtension(
  String ext,
  double size,
  BuildContext context,
) {
  final cs = Theme.of(context).colorScheme;

  Widget code() => HugeIcon(
    icon: HugeIcons.strokeRoundedCode,
    size: size,
    color: cs.primary.withValues(alpha: 0.75),
  );
  Widget db() => HugeIcon(
    icon: HugeIcons.strokeRoundedDatabase01,
    size: size,
    color: cs.secondary.withValues(alpha: 0.8),
  );
  Widget cfg() => HugeIcon(
    icon: HugeIcons.strokeRoundedConfiguration01,
    size: size,
    color: cs.onSurface.withValues(alpha: 0.55),
  );
  Widget lock() => HugeIcon(
    icon: HugeIcons.strokeRoundedLock,
    size: size,
    color: cs.onSurface.withValues(alpha: 0.45),
  );

  return switch (ext) {
    // New compiled / systems languages
    'zig' => code(),
    'gleam' => code(),
    'mojo' => code(),
    'cairo' => code(),
    'move' => code(),
    'motoko' => code(),
    'v' => code(),
    'odin' => code(),

    // New web / fullstack frameworks
    'astro' => code(),
    'svelte' => code(),
    'mdx' => code(),

    // Config / build formats
    'nix' => cfg(),
    'kdl' => cfg(),
    'dhall' => cfg(),
    'pkl' => cfg(),
    'cue' => cfg(),
    'hcl' => cfg(),
    'tf' => cfg(),

    // Database / query
    'prisma' => db(),
    'surql' => db(),
    'flux' => db(),

    // Lock files (package-lock.json, yarn.lock, etc.)
    'lock' => lock(),

    _ => null,
  };
}
