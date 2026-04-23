/// Data classes for the workspace filesystem browser / viewer.
class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.isFile,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final bool isFile;

  factory FsEntry.fromJson(Map<String, dynamic> json) => FsEntry(
        name: (json['name'] ?? '').toString(),
        path: (json['path'] ?? '').toString(),
        isDirectory: json['isDirectory'] == true,
        isFile: json['isFile'] == true,
      );
}

class FsListing {
  const FsListing({required this.path, required this.entries});

  final String path;
  final List<FsEntry> entries;

  factory FsListing.fromJson(Map<String, dynamic> json) => FsListing(
        path: (json['path'] ?? '').toString(),
        entries: (json['entries'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(FsEntry.fromJson)
                .toList() ??
            const [],
      );
}

class FsFile {
  const FsFile({
    required this.path,
    required this.size,
    required this.binary,
    required this.truncated,
    required this.modifiedAtMs,
    required this.mimeHint,
    required this.encoding,
    required this.contents,
  });

  final String path;
  final int size;
  final bool binary;
  final bool truncated;
  final int modifiedAtMs;
  final String mimeHint;
  final String encoding;
  final String contents;

  factory FsFile.fromJson(Map<String, dynamic> json) => FsFile(
        path: (json['path'] ?? '').toString(),
        size: (json['size'] as num?)?.toInt() ?? 0,
        binary: json['binary'] == true,
        truncated: json['truncated'] == true,
        modifiedAtMs: (json['modifiedAtMs'] as num?)?.toInt() ?? 0,
        mimeHint: (json['mimeHint'] ?? '').toString(),
        encoding: (json['encoding'] ?? 'utf8').toString(),
        contents: (json['contents'] ?? '').toString(),
      );
}

class FsMetadata {
  const FsMetadata({
    required this.path,
    required this.isDirectory,
    required this.isFile,
    required this.isSymlink,
    required this.createdAtMs,
    required this.modifiedAtMs,
  });

  final String path;
  final bool isDirectory;
  final bool isFile;
  final bool isSymlink;
  final int createdAtMs;
  final int modifiedAtMs;

  factory FsMetadata.fromJson(Map<String, dynamic> json) => FsMetadata(
        path: (json['path'] ?? '').toString(),
        isDirectory: json['isDirectory'] == true,
        isFile: json['isFile'] == true,
        isSymlink: json['isSymlink'] == true,
        createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
        modifiedAtMs: (json['modifiedAtMs'] as num?)?.toInt() ?? 0,
      );
}

class FsChangeEvent {
  const FsChangeEvent({
    required this.watchId,
    required this.path,
    required this.changedPaths,
  });

  final String watchId;
  final String path;
  final List<String> changedPaths;
}
