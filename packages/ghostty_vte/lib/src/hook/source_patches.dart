import 'dart:io';

typedef PatchLogger = void Function(String message);

const List<String> bundledGhosttyPatchPaths = <String>[
  'patches/ghostty-libvt-link-libc.patch',
];

void applyBundledGhosttyPatches({
  required Directory packageRoot,
  required Directory ghosttyRoot,
  PatchLogger? info,
  PatchLogger? warn,
}) {
  for (final relativePath in bundledGhosttyPatchPaths) {
    final patchFile = File.fromUri(packageRoot.uri.resolve(relativePath));
    if (!patchFile.existsSync()) {
      throw StateError('Missing bundled patch: ${patchFile.path}');
    }
    applyPatchFile(
      patchFile: patchFile,
      workingDirectory: ghosttyRoot,
      info: info,
      warn: warn,
    );
  }
}

void applyPatchFile({
  required File patchFile,
  required Directory workingDirectory,
  PatchLogger? info,
  PatchLogger? warn,
}) {
  final alreadyApplied = Process.runSync(
    'git',
    <String>['apply', '--reverse', '--check', patchFile.path],
    workingDirectory: workingDirectory.path,
    runInShell: true,
  );
  if (alreadyApplied.exitCode == 0) {
    info?.call(
      'Source patch already applied: ${patchFile.uri.pathSegments.last}',
    );
    return;
  }

  final check = Process.runSync(
    'git',
    <String>['apply', '--check', patchFile.path],
    workingDirectory: workingDirectory.path,
    runInShell: true,
  );
  if (check.exitCode != 0) {
    throw StateError(
      'Failed to validate patch ${patchFile.path}.\n'
      'stdout:\n${check.stdout}\n'
      'stderr:\n${check.stderr}',
    );
  }

  final apply = Process.runSync(
    'git',
    <String>['apply', patchFile.path],
    workingDirectory: workingDirectory.path,
    runInShell: true,
  );
  if (apply.exitCode != 0) {
    throw StateError(
      'Failed to apply patch ${patchFile.path}.\n'
      'stdout:\n${apply.stdout}\n'
      'stderr:\n${apply.stderr}',
    );
  }

  info?.call('Applied source patch: ${patchFile.uri.pathSegments.last}');
  if (warn != null &&
      (apply.stdout as String).trim().isNotEmpty &&
      (apply.stderr as String).trim().isNotEmpty) {
    warn('Patch emitted output while applying ${patchFile.path}.');
  }
}
