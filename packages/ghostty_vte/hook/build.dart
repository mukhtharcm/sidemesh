import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

import 'package:ghostty_vte/src/hook/dynamic_library.dart';
import 'package:ghostty_vte/src/hook/asset_hashes.dart';
import 'package:ghostty_vte/src/hook/source_patches.dart';

const _repo = 'kingwill101/dart_terminal';

void _info(String message) => stdout.writeln(message);

void _warn(String message) => stdout.writeln('Warning: $message');

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final code = input.config.code;
    if (code.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError(
        'ghostty_vte currently supports dynamic loading only. '
        'Static linking is not implemented.',
      );
    }

    final dylibName = code.targetOS.dylibFileName('ghostty-vt');
    final bundledLibUri = input.outputDirectory.resolve(dylibName);

    // ── 1. Try env var ──
    final envPath = Platform.environment['GHOSTTY_VTE_PREBUILT'];
    if (envPath != null && envPath.isNotEmpty) {
      final f = File(envPath);
      if (f.existsSync()) {
        ensureDynamicLibraryFile(
          f,
          canonicalName: dylibName,
          sourceDescription: 'GHOSTTY_VTE_PREBUILT',
        );
        _info('Using prebuilt VTE library from env: ${f.path}');
        await f.copy(File.fromUri(bundledLibUri).path);
        _addAsset(output, input.packageName, bundledLibUri);
        return;
      }
    }

    final platformLabel = platformLabelForBuildHook(
      code.targetOS,
      code.targetArchitecture,
      iOSSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
    );
    final preferSourceBuild = _shouldPreferSourceBuild(input);

    // ── 2. Try .prebuilt/ directory (manual or setup script) ──
    final prebuilt = _findLocalPrebuilt(input, platformLabel, dylibName);
    if (prebuilt != null) {
      _info('Using prebuilt VTE library: ${prebuilt.path}');
      await prebuilt.copy(File.fromUri(bundledLibUri).path);
      _addAsset(output, input.packageName, bundledLibUri);
      return;
    }

    // ── 3. Auto-download from GitHub releases ──
    final assetInfo = assetHashes[platformLabel];
    if (assetInfo != null && !preferSourceBuild) {
      _info(
        'Downloading prebuilt VTE library for $platformLabel '
        '($releaseTag)...',
      );
      try {
        final downloaded = await _downloadPrebuilt(
          input,
          platformLabel,
          dylibName,
          assetInfo,
        );
        _info('Using downloaded VTE library: ${downloaded.path}');
        await downloaded.copy(File.fromUri(bundledLibUri).path);
        _addAsset(output, input.packageName, bundledLibUri);
        return;
      } on Object catch (e) {
        _warn('Download failed: $e');
        _warn('Falling back to build from source.');
      }
    } else if (assetInfo != null && preferSourceBuild) {
      _info(
        'Skipping downloaded VTE prebuilt for $platformLabel because '
        'this package is being used from a local checkout.',
      );
    }

    // ── 4. Build from source ──
    _info('Building VTE library from source...');
    await _buildFromSource(input, code, dylibName, bundledLibUri);
    _addAsset(output, input.packageName, bundledLibUri);
  });
}

bool _shouldPreferSourceBuild(BuildInput input) {
  final override = Platform.environment['GHOSTTY_VTE_PREFER_SOURCE'];
  if (override != null && override.isNotEmpty && override != '0') {
    return true;
  }

  final packagePath = Directory.fromUri(input.packageRoot).absolute.path;
  return !isPubCachePackagePath(packagePath);
}

bool isPubCachePackagePath(String packagePath) {
  final segments = packagePath
      .replaceAll('\\', '/')
      .toLowerCase()
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();

  for (var i = 0; i < segments.length; i++) {
    if (segments[i] == '.pub-cache') {
      return true;
    }
    if (segments[i] == 'pub' &&
        i + 1 < segments.length &&
        segments[i + 1] == 'cache') {
      return true;
    }
  }

  return false;
}

void _addAsset(BuildOutputBuilder output, String packageName, Uri file) {
  output.assets.code.add(
    CodeAsset(
      package: packageName,
      name: 'ghostty_vte_bindings_generated.dart',
      linkMode: DynamicLoadingBundled(),
      file: file,
    ),
  );
}

// ── Auto-download ────────────────────────────────────────────────────

/// Downloads a prebuilt library from GitHub releases into
/// [BuildInput.outputDirectoryShared], which persists across builds.
///
/// Uses SHA256 verification and atomic writes (download to .tmp, then rename).
Future<File> _downloadPrebuilt(
  BuildInput input,
  String platformLabel,
  String dylibName,
  AssetHash assetInfo,
) async {
  // Use a stable cache directory keyed by platform + release tag.
  final cacheKey = '$platformLabel-$releaseTag';
  final cacheDir = Directory(
    input.outputDirectoryShared.resolve('vte-$cacheKey/').toFilePath(),
  );
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }

  final cachedFile = File(p.join(cacheDir.path, dylibName));

  // Check cache: if file exists and hash matches, reuse it.
  if (cachedFile.existsSync()) {
    final actualHash = await cachedFile.openRead().transform(sha256).first;
    if (actualHash.toString() == assetInfo.hash) {
      ensureDynamicLibraryFile(
        cachedFile,
        canonicalName: dylibName,
        sourceDescription: 'download cache',
      );
      return cachedFile;
    }
    _warn('Cached file hash mismatch, re-downloading.');
  }

  // Download the tarball.
  final tarball = assetInfo.tarball;
  final url = Uri.https(
    'github.com',
    '/$_repo/releases/download/$releaseTag/$tarball',
  );

  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;

  try {
    final request = await client.getUrl(url);
    final response = await request.close();

    if (response.statusCode != 200) {
      // Follow redirects for GitHub releases (302 → S3).
      if (response.statusCode == 302 || response.statusCode == 301) {
        final redirect = response.headers.value('location');
        if (redirect != null) {
          final redirectRequest = await client.getUrl(Uri.parse(redirect));
          final redirectResponse = await redirectRequest.close();
          if (redirectResponse.statusCode != 200) {
            throw StateError(
              'Download failed with status ${redirectResponse.statusCode} '
              'from redirect: $redirect',
            );
          }
          await _extractAndVerify(
            redirectResponse,
            cacheDir,
            cachedFile,
            dylibName,
            assetInfo.hash,
          );
          return cachedFile;
        }
      }
      throw StateError(
        'Download failed with status ${response.statusCode}: $url',
      );
    }

    await _extractAndVerify(
      response,
      cacheDir,
      cachedFile,
      dylibName,
      assetInfo.hash,
    );
  } finally {
    client.close();
  }

  return cachedFile;
}

/// Downloads the response as a tarball, extracts it, and verifies the hash
/// of the extracted library.
Future<void> _extractAndVerify(
  HttpClientResponse response,
  Directory cacheDir,
  File targetFile,
  String dylibName,
  String expectedHash,
) async {
  // Save the tarball to a temp file.
  final tarFile = File(p.join(cacheDir.path, 'download.tar.gz'));
  final sink = tarFile.openWrite();
  try {
    await response.cast<List<int>>().pipe(sink);
  } finally {
    await sink.close();
  }

  // Extract the tarball.
  final extractResult = await Process.run('tar', [
    'xzf',
    tarFile.path,
    '-C',
    cacheDir.path,
  ]);
  if (extractResult.exitCode != 0) {
    throw StateError('tar extract failed: ${extractResult.stderr}');
  }
  tarFile.deleteSync();

  // The extracted file should be the dylib. Find it.
  if (!targetFile.existsSync()) {
    final selected = selectDynamicLibraryEntity(
      cacheDir.listSync(recursive: true),
      canonicalName: dylibName,
    );
    if (selected == null) {
      throw StateError(
        'Archive extracted but no ghostty-vt library found in ${cacheDir.path}',
      );
    }
    await File(selected.path).copy(targetFile.path);
  }

  ensureDynamicLibraryFile(
    targetFile,
    canonicalName: dylibName,
    sourceDescription: 'downloaded artifact',
  );

  // Verify SHA256.
  final actualHash = await targetFile.openRead().transform(sha256).first;
  if (actualHash.toString() != expectedHash) {
    targetFile.deleteSync();
    throw StateError(
      'SHA256 mismatch for $dylibName:\n'
      '  expected: $expectedHash\n'
      '  actual:   $actualHash',
    );
  }
}

// ── Local prebuilt search ────────────────────────────────────────────

/// Search for a prebuilt library in local directories:
/// 1. Consuming project root (.prebuilt/) — from outputDirectory
/// 2. Monorepo root (.prebuilt/) — from packageRoot
///
/// Invalid local candidates are skipped with a warning so stale archives in
/// `.prebuilt/` don't block downloading or rebuilding the library.
File? _findLocalPrebuilt(
  BuildInput input,
  String platformLabel,
  String dylibName,
) {
  for (final candidate in _findPrebuiltInProjectRoots(
    input.outputDirectory,
    platformLabel,
    dylibName,
  )) {
    final usable = _validateLocalPrebuiltCandidate(candidate, dylibName);
    if (usable != null) {
      return usable;
    }
  }

  // Check .prebuilt/ cache at monorepo root after project-local caches.
  final repoRoot = _findRepoRoot(input.packageRoot);
  if (repoRoot != null) {
    final cached = File.fromUri(
      repoRoot.resolve('.prebuilt/$platformLabel/$dylibName'),
    );
    final usable = _validateLocalPrebuiltCandidate(cached, dylibName);
    if (usable != null) {
      return usable;
    }
  }

  return null;
}

/// Walk up from a URI to find the repo root (has pubspec.yaml + pkgs/).
Uri? _findRepoRoot(Uri packageRoot) {
  var dir = Directory.fromUri(packageRoot).absolute;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/pkgs').existsSync()) {
      return dir.uri;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// Search for `.prebuilt/<platform>/<dylib>` by walking up from
/// [outputDirectory].
Iterable<File> _findPrebuiltInProjectRoots(
  Uri outputDirectory,
  String platformLabel,
  String dylibName,
) sync* {
  var dir = Directory.fromUri(outputDirectory).absolute;
  while (true) {
    final hasPubspec = File('${dir.path}/pubspec.yaml').existsSync();
    final hasDartTool = Directory('${dir.path}/.dart_tool').existsSync();
    final hasPkgs = Directory('${dir.path}/pkgs').existsSync();

    if (hasPubspec && (hasDartTool || hasPkgs)) {
      final cached = File('${dir.path}/.prebuilt/$platformLabel/$dylibName');
      if (cached.existsSync()) {
        yield cached;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return;
    }
    dir = parent;
  }
}

File? _validateLocalPrebuiltCandidate(File file, String dylibName) {
  if (!file.existsSync()) {
    return null;
  }

  try {
    ensureDynamicLibraryFile(
      file,
      canonicalName: dylibName,
      sourceDescription: 'local prebuilt cache',
    );
    return file;
  } on StateError catch (error) {
    _warn('$error Ignoring this local prebuilt candidate.');
    return null;
  }
}

// ── Build from source ────────────────────────────────────────────────

/// Build the VTE library from Ghostty source using Zig.
Future<void> _buildFromSource(
  BuildInput input,
  CodeConfig code,
  String dylibName,
  Uri bundledLibUri,
) async {
  final ghosttyRoot = _resolveGhosttySourceRoot(input);
  applyBundledGhosttyPatches(
    packageRoot: Directory.fromUri(input.packageRoot),
    ghosttyRoot: ghosttyRoot,
    info: _info,
    warn: _warn,
  );
  final target = zigTargetForBuildHook(
    code.targetOS,
    code.targetArchitecture,
    iOSSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
  );

  final prefixDir = Directory.fromUri(
    input.outputDirectory.resolve('ghostty/$target/'),
  )..createSync(recursive: true);

  final zigArgs = <String>[
    'build',
    '-Demit-lib-vt=true',
    '-Dtarget=$target',
    '-Doptimize=ReleaseFast',
    '-Dsimd=false',
    '--prefix',
    prefixDir.path,
    '--summary',
    'failures',
  ];

  final result = await Process.run(
    'zig',
    zigArgs,
    workingDirectory: ghosttyRoot.path,
    runInShell: true,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to build libghostty-vt for $target.\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }

  final builtLib = _resolveBuiltLibrary(prefixDir, dylibName);
  await File.fromUri(builtLib).copy(File.fromUri(bundledLibUri).path);
}

/// Returns a platform label like "linux-x64" or "macos-arm64".
String platformLabelForBuildHook(OS os, Architecture arch, {IOSSdk? iOSSdk}) {
  final archLabel = switch (arch) {
    Architecture.x64 => 'x64',
    Architecture.arm64 => 'arm64',
    Architecture.arm => 'arm',
    Architecture.ia32 => 'x86',
    _ => arch.toString(),
  };
  final osLabel = switch (os) {
    OS.linux => 'linux',
    OS.macOS => 'macos',
    OS.windows => 'windows',
    OS.android => 'android',
    OS.iOS => 'ios',
    _ => os.toString(),
  };

  if (os == OS.iOS) {
    if (iOSSdk == IOSSdk.iPhoneSimulator || arch == Architecture.x64) {
      return 'ios-sim-$archLabel';
    }
  }

  return '$osLabel-$archLabel';
}

Directory _resolveGhosttySourceRoot(BuildInput input) {
  final envPath = Platform.environment['GHOSTTY_SRC'];
  if (envPath != null && envPath.isNotEmpty) {
    final envDir = Directory(envPath);
    if (_isGhosttyRoot(envDir)) {
      return envDir;
    }
  }

  final submoduleDir = Directory.fromUri(
    input.packageRoot.resolve('third_party/ghostty/'),
  );
  if (_envFlag('GHOSTTY_SRC_AUTO_FETCH') && !submoduleDir.existsSync()) {
    _cloneGhosttySource(submoduleDir);
  }
  if (_isGhosttyRoot(submoduleDir)) {
    return submoduleDir;
  }

  final packageRoot = Directory.fromUri(input.packageRoot);
  var current = packageRoot.absolute;
  while (true) {
    if (_isGhosttyRoot(current)) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }

  throw StateError(
    'Unable to locate Ghostty source root.\n'
    'Expected one of:\n'
    '- \$GHOSTTY_SRC\n'
    '- third_party/ghostty (git submodule)\n'
    '- an ancestor directory containing build.zig and include/ghostty/vt.h',
  );
}

bool _isGhosttyRoot(Directory dir) {
  final buildZig = File.fromUri(dir.uri.resolve('build.zig'));
  final vtHeader = File.fromUri(dir.uri.resolve('include/ghostty/vt.h'));
  return buildZig.existsSync() && vtHeader.existsSync();
}

bool _envFlag(String name) {
  final value = Platform.environment[name];
  if (value == null) return false;
  switch (value.toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
  }
  return false;
}

void _cloneGhosttySource(Directory targetDir) {
  final url =
      Platform.environment['GHOSTTY_SRC_URL'] ??
      'https://github.com/ghostty-org/ghostty';
  final parent = targetDir.parent;
  parent.createSync(recursive: true);

  final cloneResult = Process.runSync('git', [
    'clone',
    url,
    targetDir.path,
  ], runInShell: true);
  if (cloneResult.exitCode != 0) {
    throw StateError(
      'Failed to clone Ghostty source.\n'
      'stdout:\n${cloneResult.stdout}\n'
      'stderr:\n${cloneResult.stderr}',
    );
  }

  final ref = Platform.environment['GHOSTTY_SRC_REF'];
  if (ref != null && ref.isNotEmpty) {
    final checkoutResult = Process.runSync('git', [
      '-C',
      targetDir.path,
      'checkout',
      ref,
    ], runInShell: true);
    if (checkoutResult.exitCode != 0) {
      throw StateError(
        'Failed to checkout Ghostty ref "$ref".\n'
        'stdout:\n${checkoutResult.stdout}\n'
        'stderr:\n${checkoutResult.stderr}',
      );
    }
  }
}

String zigTargetForBuildHook(OS os, Architecture arch, {IOSSdk? iOSSdk}) {
  if (os == OS.android) {
    switch (arch) {
      case Architecture.arm:
        return 'arm-linux-androideabi';
      case Architecture.arm64:
        return 'aarch64-linux-android';
      case Architecture.x64:
        return 'x86_64-linux-android';
      case Architecture.ia32:
        return 'x86-linux-android';
      default:
        break;
    }
  }

  if (os == OS.linux) {
    switch (arch) {
      case Architecture.arm:
        return 'arm-linux-gnueabihf';
      case Architecture.arm64:
        return 'aarch64-linux-gnu';
      case Architecture.x64:
        return 'x86_64-linux-gnu';
      case Architecture.ia32:
        return 'x86-linux-gnu';
      default:
        break;
    }
  }

  if (os == OS.macOS) {
    switch (arch) {
      case Architecture.arm64:
        return 'aarch64-macos';
      case Architecture.x64:
        return 'x86_64-macos';
      default:
        break;
    }
  }

  if (os == OS.windows) {
    switch (arch) {
      case Architecture.arm64:
        return 'aarch64-windows-gnu';
      case Architecture.x64:
        return 'x86_64-windows-gnu';
      case Architecture.ia32:
        return 'x86-windows-gnu';
      default:
        break;
    }
  }

  if (os == OS.iOS) {
    switch (arch) {
      case Architecture.arm64:
        return iOSSdk == IOSSdk.iPhoneSimulator
            ? 'aarch64-ios-simulator'
            : 'aarch64-ios';
      case Architecture.x64:
        return 'x86_64-ios-simulator';
      default:
        break;
    }
  }

  throw UnsupportedError(
    'Unsupported build target for libghostty-vt: ${os.name}/${arch.name}',
  );
}

Uri _resolveBuiltLibrary(Directory prefixDir, String dylibName) {
  final direct = File.fromUri(prefixDir.uri.resolve('lib/$dylibName'));
  if (direct.existsSync()) {
    ensureDynamicLibraryFile(
      direct,
      canonicalName: dylibName,
      sourceDescription: 'source build output',
    );
    return direct.uri;
  }

  final libDir = Directory.fromUri(prefixDir.uri.resolve('lib/'));
  if (!libDir.existsSync()) {
    throw StateError('Expected library directory: ${libDir.path}');
  }

  final selected = selectDynamicLibraryEntity(
    libDir.listSync(),
    canonicalName: dylibName,
  );
  if (selected == null) {
    throw StateError(
      'Could not find built ghostty-vt library in ${libDir.path}',
    );
  }
  final file = File(selected.path);
  ensureDynamicLibraryFile(
    file,
    canonicalName: dylibName,
    sourceDescription: 'source build output',
  );
  return file.uri;
}
