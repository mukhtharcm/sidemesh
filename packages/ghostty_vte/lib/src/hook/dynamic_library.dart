import 'dart:io';

String dynamicLibraryNameForPlatform(String platformLabel, String libraryStem) {
  final normalized = platformLabel.toLowerCase();
  if (normalized.startsWith('windows-')) {
    return '$libraryStem.dll';
  }
  if (normalized.startsWith('macos-') || normalized.startsWith('ios-')) {
    return 'lib$libraryStem.dylib';
  }
  if (normalized.startsWith('linux-') || normalized.startsWith('android-')) {
    return 'lib$libraryStem.so';
  }
  throw UnsupportedError('Unsupported platform label: $platformLabel');
}

FileSystemEntity? selectDynamicLibraryEntity(
  Iterable<FileSystemEntity> entities, {
  required String canonicalName,
}) {
  final matches =
      entities
          .where(
            (entity) => _matchesDynamicLibraryName(
              _basename(entity.path),
              canonicalName,
            ),
          )
          .toList()
        ..sort((a, b) {
          final aName = _basename(a.path);
          final bName = _basename(b.path);
          final rank = _matchRank(
            aName,
            canonicalName,
          ).compareTo(_matchRank(bName, canonicalName));
          if (rank != 0) {
            return rank;
          }
          return aName.compareTo(bName);
        });

  if (matches.isEmpty) {
    return null;
  }
  return matches.first;
}

void ensureDynamicLibraryFile(
  File file, {
  required String canonicalName,
  String? sourceDescription,
}) {
  if (!file.existsSync()) {
    throw StateError('Dynamic library not found: ${file.path}');
  }

  final raf = file.openSync();
  List<int> header;
  try {
    header = raf.readSync(8);
  } finally {
    raf.closeSync();
  }

  final valid = switch (_formatForName(canonicalName)) {
    _DynamicLibraryFormat.elf => _startsWith(header, const [
      0x7F,
      0x45,
      0x4C,
      0x46,
    ]),
    _DynamicLibraryFormat.pe => _startsWith(header, const [0x4D, 0x5A]),
    _DynamicLibraryFormat.machO => _isMachOHeader(header),
  };

  if (valid) {
    return;
  }

  final context = sourceDescription == null ? '' : ' from $sourceDescription';
  throw StateError(
    'Expected ${file.path}$context to be a dynamic library matching '
    '$canonicalName, but its header was ${_hexHeader(header)}.',
  );
}

bool _matchesDynamicLibraryName(String basename, String canonicalName) {
  if (basename == canonicalName) {
    return true;
  }

  if (canonicalName.endsWith('.so')) {
    return basename.startsWith('$canonicalName.');
  }

  if (canonicalName.endsWith('.dylib')) {
    final stem = canonicalName.substring(
      0,
      canonicalName.length - '.dylib'.length,
    );
    return basename.startsWith('$stem.') && basename.endsWith('.dylib');
  }

  return false;
}

int _matchRank(String basename, String canonicalName) {
  if (basename == canonicalName) {
    return 0;
  }

  if (canonicalName.endsWith('.so') && basename.startsWith('$canonicalName.')) {
    return 1;
  }

  if (canonicalName.endsWith('.dylib') &&
      basename.endsWith('.dylib') &&
      basename.startsWith(
        canonicalName.substring(0, canonicalName.length - '.dylib'.length),
      )) {
    return 1;
  }

  return 2;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  if (index == -1) {
    return normalized;
  }
  return normalized.substring(index + 1);
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }

  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

bool _isMachOHeader(List<int> bytes) {
  if (bytes.length < 4) {
    return false;
  }

  const validPrefixes = <List<int>>[
    [0xFE, 0xED, 0xFA, 0xCE],
    [0xCE, 0xFA, 0xED, 0xFE],
    [0xFE, 0xED, 0xFA, 0xCF],
    [0xCF, 0xFA, 0xED, 0xFE],
    [0xCA, 0xFE, 0xBA, 0xBE],
    [0xBE, 0xBA, 0xFE, 0xCA],
    [0xCA, 0xFE, 0xBA, 0xBF],
    [0xBF, 0xBA, 0xFE, 0xCA],
  ];

  return validPrefixes.any((prefix) => _startsWith(bytes, prefix));
}

String _hexHeader(List<int> bytes) {
  if (bytes.isEmpty) {
    return '<empty>';
  }
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
}

_DynamicLibraryFormat _formatForName(String canonicalName) {
  if (canonicalName.endsWith('.so')) {
    return _DynamicLibraryFormat.elf;
  }
  if (canonicalName.endsWith('.dll')) {
    return _DynamicLibraryFormat.pe;
  }
  if (canonicalName.endsWith('.dylib')) {
    return _DynamicLibraryFormat.machO;
  }
  throw UnsupportedError('Unsupported dynamic library name: $canonicalName');
}

enum _DynamicLibraryFormat { elf, pe, machO }
