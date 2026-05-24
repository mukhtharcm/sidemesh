/// Downloads the prebuilt ghostty_vte native library for the host platform.
///
/// Usage:
///   dart run ghostty_vte:setup [--tag ghostty_vte-v0.1.1] [--platform linux-x64]
///
/// The library is placed in `.prebuilt/<platform>/` at the project root,
/// where the build hook will find it automatically.
library;

import 'dart:io';

import 'package:ghostty_vte/src/hook/artifacts.dart';
import 'package:ghostty_vte/src/hook/asset_hashes.dart';
import 'package:ghostty_vte/src/hook/build_cache.dart';
import 'package:ghostty_vte/src/hook/dynamic_library.dart';

const _repo = 'kingwill101/dart_terminal';

Future<void> main(List<String> args) async {
  var tag = releaseTag;
  String? platform;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--tag':
      case '-t':
        tag = args[++i];
      case '--platform':
      case '-p':
        platform = args[++i];
      case '--help':
      case '-h':
        stdout.writeln(
          'Usage: dart run ghostty_vte:setup [options]\n'
          '\n'
          'Downloads the prebuilt ghostty_vte native library for your platform\n'
          'into .prebuilt/<platform>/ at your project root.\n'
          '\n'
          '  --tag, -t       Release tag (default: $releaseTag)\n'
          '  --platform, -p  e.g. linux-x64, macos-arm64 (default: auto-detect)\n',
        );
        return;
    }
  }

  platform ??= _hostPlatform();

  final artifact = vtePrebuiltArtifacts[platform];
  if (artifact == null) {
    stderr.writeln(
      'No prebuilt ghostty_vte artifact for platform "$platform".\n'
      'Available: ${vtePrebuiltArtifacts.keys.join(', ')}',
    );
    exitCode = 1;
    return;
  }

  final projectRoot = _findProjectRoot(Directory.current);
  final outDir = Directory('${projectRoot.path}/.prebuilt/$platform')
    ..createSync(recursive: true);

  stdout.writeln('ghostty_vte setup');
  stdout.writeln('  Release:  $tag');
  stdout.writeln('  Platform: $platform');
  stdout.writeln('  Target:   ${outDir.path}');
  stdout.writeln('');

  try {
    await _downloadAndExtract(tag, artifact, outDir);
    final clearedCaches = clearGhosttyVteHookCache(projectRoot);
    for (final path in clearedCaches) {
      stdout.writeln('  Cleared cache: $path');
    }
    stdout.writeln('Done. The build hook will use this library automatically.');
  } on Exception catch (e) {
    stderr.writeln('Failed: $e');
    exitCode = 1;
  }
}

// ── Download ────────────────────────────────────────────────────────

Future<void> _downloadAndExtract(
  String tag,
  String filename,
  Directory outDir,
) async {
  // Try gh CLI first (handles auth, private repos, URL encoding).
  final ghResult = await Process.run('gh', [
    'release',
    'download',
    tag,
    '--repo',
    _repo,
    '--pattern',
    filename,
    '--dir',
    outDir.path,
    '--clobber',
  ]);

  final tarPath = '${outDir.path}/$filename';

  if (ghResult.exitCode != 0) {
    // Fall back to curl with the direct URL.
    final encodedTag = Uri.encodeComponent(tag);
    final url =
        'https://github.com/$_repo/releases/download/$encodedTag/$filename';
    stdout.writeln('  gh CLI unavailable, trying curl...');

    final curlResult = await Process.run('curl', [
      '-fSL',
      '--retry',
      '3',
      '-o',
      tarPath,
      url,
    ]);
    if (curlResult.exitCode != 0) {
      throw Exception(
        'Download failed.\n'
        '  gh error: ${ghResult.stderr}\n'
        '  curl error: ${curlResult.stderr}',
      );
    }
  }

  // Extract.
  final extractResult = await Process.run('tar', [
    'xzf',
    tarPath,
    '-C',
    outDir.path,
  ]);
  if (extractResult.exitCode != 0) {
    throw Exception('tar extract failed: ${extractResult.stderr}');
  }

  // Clean up tarball.
  File(tarPath).deleteSync();

  // Verify the library exists.
  final files = outDir.listSync().whereType<File>().toList();
  if (files.isEmpty) {
    throw Exception('Archive extracted but no files found in ${outDir.path}');
  }

  final platformLabel = filename
      .replaceFirst('vte-', '')
      .replaceFirst('.tar.gz', '');
  final canonicalName = dynamicLibraryNameForPlatform(
    platformLabel,
    'ghostty-vt',
  );
  final selected = selectDynamicLibraryEntity(
    files,
    canonicalName: canonicalName,
  );
  if (selected == null) {
    throw Exception(
      'Archive extracted but no matching dynamic library was found for '
      '$platformLabel in ${outDir.path}',
    );
  }
  ensureDynamicLibraryFile(
    File(selected.path),
    canonicalName: canonicalName,
    sourceDescription: 'release artifact $filename',
  );

  for (final f in files) {
    stdout.writeln('  Extracted: ${f.path}');
  }
}

// ── Helpers ─────────────────────────────────────────────────────────

String _hostPlatform() {
  final os = Platform.operatingSystem;
  final arch = _hostArch();
  switch (os) {
    case 'linux':
      return 'linux-$arch';
    case 'macos':
      return 'macos-$arch';
    case 'windows':
      return 'windows-$arch';
    default:
      return '$os-$arch';
  }
}

String _hostArch() {
  if (Platform.isWindows) {
    final pa = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    return pa.contains('ARM') ? 'arm64' : 'x64';
  }
  final result = Process.runSync('uname', ['-m']);
  final machine = (result.stdout as String).trim();
  switch (machine) {
    case 'x86_64':
    case 'amd64':
      return 'x64';
    case 'aarch64':
    case 'arm64':
      return 'arm64';
    default:
      return machine;
  }
}

/// Find the consuming project root.
/// Prefers a monorepo root (pubspec.yaml + pkgs/), falls back to nearest
/// pubspec.yaml.
Directory _findProjectRoot(Directory start) {
  var dir = start.absolute;

  // First: look for monorepo root.
  var cursor = dir;
  while (true) {
    if (File('${cursor.path}/pubspec.yaml').existsSync() &&
        Directory('${cursor.path}/pkgs').existsSync()) {
      return cursor;
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) break;
    cursor = parent;
  }

  // Fallback: nearest pubspec.yaml.
  cursor = dir;
  while (true) {
    if (File('${cursor.path}/pubspec.yaml').existsSync()) {
      return cursor;
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) return start;
    cursor = parent;
  }
}
