import 'dart:io';

Future<void> main(List<String> args) async {
  final packageRoot = Directory.current;
  final ghosttyRoot = _resolveGhosttySourceRoot(packageRoot);
  final outPath = args.isNotEmpty
      ? args.first
      : '${packageRoot.parent.path}/ghostty_vte_flutter/assets/ghostty-vt.wasm';

  final buildPrefix = Directory(
    '${packageRoot.path}/.dart_tool/ghostty-wasm-build',
  )..createSync(recursive: true);

  final buildArgs = <String>[
    'build',
    '-Demit-lib-vt=true',
    '-Dtarget=wasm32-freestanding',
    '-Doptimize=ReleaseFast',
    '-Dsimd=false',
    '--prefix',
    buildPrefix.path,
    '--summary',
    'failures',
  ];

  stdout.writeln('Building ghostty-vt.wasm from ${ghosttyRoot.path}...');
  final result = await Process.run(
    'zig',
    buildArgs,
    workingDirectory: ghosttyRoot.path,
    runInShell: true,
  );
  if (result.exitCode != 0) {
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
    throw StateError('Failed to build wasm module.');
  }

  final builtWasm = File('${buildPrefix.path}/bin/ghostty-vt.wasm');
  if (!builtWasm.existsSync()) {
    throw StateError('Expected wasm artifact at ${builtWasm.path}');
  }

  final outFile = File(outPath)..parent.createSync(recursive: true);
  await builtWasm.copy(outFile.path);
  stdout.writeln('Wasm module copied to ${outFile.path}');
}

Directory _resolveGhosttySourceRoot(Directory packageRoot) {
  final envPath = Platform.environment['GHOSTTY_SRC'];
  if (envPath != null && envPath.isNotEmpty) {
    final envDir = Directory(envPath);
    if (_isGhosttyRoot(envDir)) {
      return envDir;
    }
  }

  final submoduleDir = Directory('${packageRoot.path}/third_party/ghostty');
  if (_isGhosttyRoot(submoduleDir)) {
    return submoduleDir;
  }

  throw StateError(
    'Unable to locate Ghostty source root. Set GHOSTTY_SRC or initialize '
    'third_party/ghostty.',
  );
}

bool _isGhosttyRoot(Directory dir) {
  final buildZig = File('${dir.path}/build.zig');
  final vtHeader = File('${dir.path}/include/ghostty/vt.h');
  return buildZig.existsSync() && vtHeader.existsSync();
}
