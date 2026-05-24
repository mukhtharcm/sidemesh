import 'dart:io';

import 'package:ffigen/ffigen.dart' as ffigen;
import 'package:logging/logging.dart';

Future<void> main() async {
  final packageRoot = _packageRoot();
  final ghosttyRoot = _resolveGhosttySourceRoot(packageRoot);
  final ghosttyHeader = File.fromUri(
    ghosttyRoot.uri.resolve('include/ghostty/vt.h'),
  );
  if (!ghosttyHeader.existsSync()) {
    throw StateError('Missing header: ${ghosttyHeader.path}');
  }

  final configFile = File.fromUri(
    packageRoot.uri.resolve('.dart_tool/ghostty_vte_ffigen.yaml'),
  );
  configFile.parent.createSync(recursive: true);
  configFile.writeAsStringSync(
    _renderConfig(
      outputPath: File.fromUri(
        packageRoot.uri.resolve('lib/ghostty_vte_bindings_generated.dart'),
      ).path,
      headerPath: ghosttyHeader.path,
      includeGlobPath:
          '${Directory.fromUri(ghosttyRoot.uri.resolve('include/ghostty')).path}/vt/**.h',
      includePath: Directory.fromUri(ghosttyRoot.uri.resolve('include/')).path,
      clangIncludePath: _clangIncludePath(),
    ),
  );

  final logger = _createLogger();
  final config = ffigen.YamlConfig.fromFile(configFile, logger);
  config.configAdapter().generate(logger: logger);

  _postProcessGeneratedBindings(
    File.fromUri(
      packageRoot.uri.resolve('lib/ghostty_vte_bindings_generated.dart'),
    ),
  );
}

Directory _packageRoot() {
  return Directory.fromUri(Platform.script.resolve('../'));
}

Directory _resolveGhosttySourceRoot(Directory packageRoot) {
  final envPath = Platform.environment['GHOSTTY_SRC'];
  if (envPath != null && envPath.isNotEmpty) {
    final envDir = Directory(envPath);
    if (_isGhosttyRoot(envDir)) {
      return envDir;
    }
  }

  final submoduleDir = Directory.fromUri(
    packageRoot.uri.resolve('third_party/ghostty/'),
  );
  if (_isGhosttyRoot(submoduleDir)) {
    return submoduleDir;
  }

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
    'Unable to locate Ghostty source root for ffigen.\n'
    'Set GHOSTTY_SRC or initialize third_party/ghostty submodule.',
  );
}

bool _isGhosttyRoot(Directory dir) {
  final buildZig = File.fromUri(dir.uri.resolve('build.zig'));
  final vtHeader = File.fromUri(dir.uri.resolve('include/ghostty/vt.h'));
  return buildZig.existsSync() && vtHeader.existsSync();
}

String? _clangIncludePath() {
  final result = Process.runSync('clang', const <String>[
    '-print-resource-dir',
  ], runInShell: true);
  if (result.exitCode != 0) {
    return null;
  }
  final resource = (result.stdout as String).trim();
  if (resource.isEmpty) {
    return null;
  }
  final includeDir = Directory.fromUri(
    Directory(resource).uri.resolve('include/'),
  );
  if (!includeDir.existsSync()) {
    return null;
  }
  return includeDir.path;
}

String _renderConfig({
  required String outputPath,
  required String headerPath,
  required String includeGlobPath,
  required String includePath,
  required String? clangIncludePath,
}) {
  final lines = <String>[
    'name: GhosttyVtBindings',
    'description: Bindings for libghostty-vt C API.',
    "output: '${_yamlQuote(outputPath)}'",
    'headers:',
    '  entry-points:',
    "    - '${_yamlQuote(headerPath)}'",
    '  include-directives:',
    "    - '${_yamlQuote(includeGlobPath)}'",
    'compiler-opts:',
    "  - '-I${_yamlQuote(includePath)}'",
    if (clangIncludePath != null) "  - '-I${_yamlQuote(clangIncludePath)}'",
    'ffi-native:',
    'silence-enum-warning: true',
    'preamble: |',
    '  // ignore_for_file: always_specify_types',
    '  // ignore_for_file: camel_case_types',
    '  // ignore_for_file: non_constant_identifier_names',
    '  // ignore_for_file: unused_field',
    'comments:',
    '  style: any',
    '  length: full',
  ];
  return '${lines.join('\n')}\n';
}

String _yamlQuote(String value) {
  return value.replaceAll('\\', '/').replaceAll("'", "''");
}

Logger _createLogger() {
  Logger.root.level = Level.INFO;
  final logger = Logger('ghostty_vte.ffigen');
  logger.onRecord.listen((record) {
    final stream = record.level >= Level.SEVERE ? stderr : stdout;
    stream.writeln('[${record.level.name}] ${record.message}');
  });
  return logger;
}

void _postProcessGeneratedBindings(File file) {
  final original = file.readAsStringSync();
  final patched = original.replaceAll(
    'GhosttyColorRgb[256]',
    '`GhosttyColorRgb[256]`',
  );
  if (patched != original) {
    file.writeAsStringSync(patched);
  }
}
