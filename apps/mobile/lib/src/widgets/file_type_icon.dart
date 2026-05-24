import 'package:file_icon/file_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Maps a filename to a file-type icon with a lightweight fallback layer.
///
/// [file_icon] remains the primary source because it already covers most common
/// file extensions with the Seti icon set. For a small set of modern file
/// types that package doesn't recognize well, we provide local branded SVG
/// fallbacks. Everything else uses simple Material icons so we don't need a
/// separate large icon dependency.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon(this.filename, {super.key, this.size = 16});

  final String filename;
  final double size;

  @override
  Widget build(BuildContext context) {
    final lower = filename.toLowerCase();
    final ext = _extension(lower);
    final asset = _svgFallbackForExtension(ext);
    if (asset != null) {
      return _SvgFileTypeIcon(
        asset: asset.assetPath,
        size: size,
        color: asset.color,
      );
    }

    final material =
        _materialFallbackForFilename(lower) ?? _materialFallbackForExtension(ext);
    if (material != null) {
      return Icon(material.icon, size: size, color: material.color(context));
    }

    return FileIcon(lower, size: size);
  }
}

String _extension(String filename) {
  final name = filename.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot + 1) : '';
}

_SvgFileTypeAsset? _svgFallbackForExtension(String ext) {
  return switch (ext) {
    'astro' => const _SvgFileTypeAsset(
      'assets/icons/filetypes/astro.svg',
      color: Color(0xFFFF5D01),
    ),
    'svelte' => const _SvgFileTypeAsset(
      'assets/icons/filetypes/svelte.svg',
      color: Color(0xFFFF3E00),
    ),
    'zig' => const _SvgFileTypeAsset(
      'assets/icons/filetypes/zig.svg',
      color: Color(0xFFF7A41D),
    ),
    'nix' => const _SvgFileTypeAsset(
      'assets/icons/filetypes/nixos.svg',
      color: Color(0xFF5277C3),
    ),
    'tf' => const _SvgFileTypeAsset(
      'assets/icons/filetypes/terraform.svg',
      color: Color(0xFF844FBA),
    ),
    'prisma' => const _SvgFileTypeAsset(
      'assets/icons/filetypes/prisma.svg',
      color: Color(0xFF2D3748),
    ),
    'mdx' => const _SvgFileTypeAsset('assets/icons/filetypes/mdx.svg'),
    _ => null,
  };
}

_MaterialFileTypeAsset? _materialFallbackForFilename(String filename) {
  return switch (filename) {
    'pnpm-lock.yaml' ||
    'package-lock.json' ||
    'cargo.lock' ||
    'composer.lock' ||
    'bun.lock' => _MaterialFileTypeAsset.lock,
    _ => null,
  };
}

_MaterialFileTypeAsset? _materialFallbackForExtension(String ext) {
  return switch (ext) {
    'gleam' ||
    'mojo' ||
    'cairo' ||
    'move' ||
    'motoko' ||
    'v' ||
    'odin' => _MaterialFileTypeAsset.code,
    'hcl' ||
    'kdl' ||
    'dhall' ||
    'pkl' ||
    'cue' => _MaterialFileTypeAsset.config,
    'surql' || 'flux' => _MaterialFileTypeAsset.database,
    'lock' => _MaterialFileTypeAsset.lock,
    _ => null,
  };
}

final class _SvgFileTypeIcon extends StatelessWidget {
  const _SvgFileTypeIcon({
    required this.asset,
    required this.size,
    this.color,
  });

  final String asset;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        color ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72);
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
    );
  }
}

final class _SvgFileTypeAsset {
  const _SvgFileTypeAsset(this.assetPath, {this.color});

  final String assetPath;
  final Color? color;
}

final class _MaterialFileTypeAsset {
  const _MaterialFileTypeAsset._(
    this.icon,
    this.color,
  );

  final IconData icon;
  final Color Function(BuildContext context) color;

  static final code = _MaterialFileTypeAsset._(
    Icons.code_rounded,
    (context) => Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.78),
  );

  static final config = _MaterialFileTypeAsset._(
    Icons.settings_suggest_rounded,
    (context) => Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.62),
  );

  static final database = _MaterialFileTypeAsset._(
    Icons.storage_rounded,
    (context) => Theme.of(
      context,
    ).colorScheme.secondary.withValues(alpha: 0.82),
  );

  static final lock = _MaterialFileTypeAsset._(
    Icons.lock_rounded,
    (context) => Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.52),
  );
}
