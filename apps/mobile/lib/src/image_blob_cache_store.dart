import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app_directories.dart';
import 'models.dart';

class ImageBlobCacheStore {
  ImageBlobCacheStore._();

  static final ImageBlobCacheStore instance = ImageBlobCacheStore._();

  static const _cacheFolderName = 'sidemesh_image_blobs_v1';
  static const _indexKey = 'sidemesh_image_blob_cache_index_v1';
  static const _maxEntries = 500;
  static const _maxWebEntries = 100;
  static const _maxTotalBytes = 200 * 1024 * 1024;
  static const _ttl = Duration(days: 30);

  final Map<String, Future<File>> _inFlight = <String, Future<File>>{};
  final Map<String, Future<ImageProvider<Object>>> _webInFlight =
      <String, Future<ImageProvider<Object>>>{};
  final Map<String, Uint8List> _webCache = <String, Uint8List>{};
  Future<void> _indexMutation = Future<void>.value();
  var _clearGeneration = 0;

  Future<File> load({
    required HostProfile host,
    required String path,
    required ApiClient api,
    String? sessionId,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Use loadImageProvider on the web.');
    }
    final key = _cacheKey(host, path, sessionId: sessionId);
    final cached = await _loadCachedFile(key);
    if (cached != null) {
      return cached;
    }

    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }

    final request = _fetchAndStore(
      host: host,
      path: path,
      api: api,
      key: key,
      generation: _clearGeneration,
      sessionId: sessionId,
    );
    _inFlight[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_inFlight[key], request)) {
        _inFlight.remove(key);
      }
    }
  }

  Future<ImageProvider<Object>> loadImageProvider({
    required HostProfile host,
    required String path,
    required ApiClient api,
    String? sessionId,
  }) async {
    if (!kIsWeb) {
      return FileImage(
        await load(host: host, path: path, api: api, sessionId: sessionId),
      );
    }
    final key = _cacheKey(host, path, sessionId: sessionId);
    final cachedBytes = _webCache.remove(key);
    if (cachedBytes != null) {
      _webCache[key] = cachedBytes;
      return MemoryImage(cachedBytes);
    }
    final existing = _webInFlight[key];
    if (existing != null) return existing;
    final generation = _clearGeneration;
    final request = api
        .fetchFsBlob(host, path, sessionId: sessionId)
        .then<ImageProvider<Object>>((bytes) {
          if (generation == _clearGeneration) {
            _webCache[key] = bytes;
            while (_webCache.length > _maxWebEntries) {
              _webCache.remove(_webCache.keys.first);
            }
          }
          return MemoryImage(bytes);
        });
    _webInFlight[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_webInFlight[key], request)) {
        _webInFlight.remove(key);
      }
    }
  }

  Future<void> clearHost(HostProfile host) async {
    if (kIsWeb) {
      _clearGeneration += 1;
      final prefix = _cacheKeyPrefix(host);
      _webCache.removeWhere((key, _) => key.startsWith(prefix));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final dir = await _cacheDir();
    final prefix = _cacheKeyPrefix(host);
    await _runIndexMutation(() async {
      _clearGeneration += 1;
      final index = await _loadIndex(prefs);
      final kept = <_ImageCacheIndexEntry>[];
      for (final entry in index) {
        if (entry.key.startsWith(prefix)) {
          await _deleteFileIfExists(_fileFor(dir, entry.key));
        } else {
          kept.add(entry);
        }
      }
      await _deleteFilesWithPrefix(dir, prefix);
      await _saveIndex(prefs, kept);
    });
  }

  Future<void> clearAll() async {
    if (kIsWeb) {
      _clearGeneration += 1;
      _webCache.clear();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final dir = await _cacheDir();
    await _runIndexMutation(() async {
      _clearGeneration += 1;
      await _deleteDirectoryIfExists(dir);
      await prefs.remove(_indexKey);
    });
  }

  Future<File?> _loadCachedFile(String key) async {
    if (kIsWeb) return null;
    final prefs = await SharedPreferences.getInstance();
    final dir = await _cacheDir();
    final file = _fileFor(dir, key);
    if (!await file.exists()) {
      await _removeIndexEntry(prefs, key);
      return null;
    }

    final index = await _loadIndex(prefs);
    _ImageCacheIndexEntry? entry;
    for (final item in index) {
      if (item.key == key) {
        entry = item;
        break;
      }
    }
    if (entry == null || DateTime.now().difference(entry.cachedAt) > _ttl) {
      await _deleteFileIfExists(file);
      await _removeIndexEntry(prefs, key);
      return null;
    }

    await _touchIndexEntry(prefs, key);
    return file;
  }

  Future<File> _fetchAndStore({
    required HostProfile host,
    required String path,
    required ApiClient api,
    required String key,
    required int generation,
    required String? sessionId,
  }) async {
    final bytes = await api.fetchFsBlob(host, path, sessionId: sessionId);
    if (generation != _clearGeneration) {
      return _writeTransientFile(key, bytes);
    }

    final dir = await _cacheDir();
    final file = _fileFor(dir, key);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes, flush: true);

    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    var stored = false;
    try {
      await _runIndexMutation(() async {
        if (generation != _clearGeneration) return;
        if (await file.exists()) {
          await file.delete();
        }
        await temp.rename(file.path);
        await _updateIndex(
          prefs,
          _ImageCacheIndexEntry(
            key: key,
            sizeBytes: bytes.length,
            cachedAt: now,
            lastUsedAt: now,
          ),
        );
        stored = true;
      });
    } catch (error) {
      await _deleteFileIfExists(temp);
      rethrow;
    }
    if (!stored) {
      await _deleteFileIfExists(temp);
      return _writeTransientFile(key, bytes);
    }
    return file;
  }

  Future<File> _writeTransientFile(String key, List<int> bytes) async {
    final dir = await Directory.systemTemp.createTemp('sidemesh_image_blob_');
    final file = File('${dir.path}/$key.blob');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<Directory> _cacheDir() async {
    final root = await getSidemeshApplicationCacheDirectory();
    final dir = Directory('${root.path}/$_cacheFolderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  File _fileFor(Directory dir, String key) => File('${dir.path}/$key.blob');

  String _cacheKeyPrefix(HostProfile host) =>
      '${_stableHash('${host.id}\n${_hostFingerprint(host)}')}-';

  String _cacheKey(HostProfile host, String path, {String? sessionId}) =>
      '${_cacheKeyPrefix(host)}${_stableHash('${sessionId ?? ''}\n$path')}';

  String _hostFingerprint(HostProfile host) {
    final endpoint = _normalizedBaseUrl(host.baseUrl);
    return _stableHash('$endpoint\n${host.token}');
  }

  String _normalizedBaseUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      return trimmed;
    }
    final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path == '/'
        ? ''
        : uri.path.replaceFirst(RegExp(r'/$'), '');
    return '$scheme://$host$port$path';
  }

  String _stableHash(String input) {
    var fnv = 0x811c9dc5;
    var djb = 5381;
    for (final codeUnit in input.codeUnits) {
      fnv ^= codeUnit;
      fnv = (fnv * 0x01000193) & 0xffffffff;
      djb = (((djb << 5) + djb) ^ codeUnit) & 0xffffffff;
    }
    return '${fnv.toRadixString(16).padLeft(8, '0')}${djb.toRadixString(16).padLeft(8, '0')}';
  }

  Future<List<_ImageCacheIndexEntry>> _loadIndex(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) {
      return const <_ImageCacheIndexEntry>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return const <_ImageCacheIndexEntry>[];
      }
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(_ImageCacheIndexEntry.fromJson)
          .where((entry) => entry.key.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      await prefs.remove(_indexKey);
      return const <_ImageCacheIndexEntry>[];
    }
  }

  Future<void> _saveIndex(
    SharedPreferences prefs,
    List<_ImageCacheIndexEntry> entries,
  ) async {
    if (entries.isEmpty) {
      await prefs.remove(_indexKey);
      return;
    }
    await prefs.setString(
      _indexKey,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }

  Future<void> _touchIndexEntry(SharedPreferences prefs, String key) async {
    await _runIndexMutation(() async {
      final now = DateTime.now();
      final updated = (await _loadIndex(prefs))
          .map(
            (entry) =>
                entry.key == key ? entry.copyWith(lastUsedAt: now) : entry,
          )
          .toList(growable: false);
      await _saveIndex(prefs, updated);
    });
  }

  Future<void> _updateIndex(
    SharedPreferences prefs,
    _ImageCacheIndexEntry entry,
  ) async {
    final updated = [
      ...(await _loadIndex(prefs)).where((item) => item.key != entry.key),
      entry,
    ];
    await _prune(prefs, updated);
  }

  Future<void> _removeIndexEntry(SharedPreferences prefs, String key) async {
    await _runIndexMutation(() async {
      final updated = (await _loadIndex(
        prefs,
      )).where((entry) => entry.key != key).toList(growable: false);
      await _saveIndex(prefs, updated);
    });
  }

  Future<void> _runIndexMutation(Future<void> Function() mutate) {
    final next = _indexMutation.then((_) => mutate());
    _indexMutation = next.catchError((_) {});
    return next;
  }

  Future<void> _prune(
    SharedPreferences prefs,
    List<_ImageCacheIndexEntry> index,
  ) async {
    final dir = await _cacheDir();
    final now = DateTime.now();
    final valid = <_ImageCacheIndexEntry>[];
    for (final entry in index) {
      final file = _fileFor(dir, entry.key);
      if (now.difference(entry.cachedAt) > _ttl || !await file.exists()) {
        await _deleteFileIfExists(file);
      } else {
        valid.add(entry);
      }
    }

    valid.sort((left, right) => right.lastUsedAt.compareTo(left.lastUsedAt));

    var totalBytes = 0;
    final kept = <_ImageCacheIndexEntry>[];
    for (final entry in valid) {
      final wouldFit =
          kept.length < _maxEntries &&
          totalBytes + entry.sizeBytes <= _maxTotalBytes;
      if (wouldFit) {
        kept.add(entry);
        totalBytes += entry.sizeBytes;
      } else {
        await _deleteFileIfExists(_fileFor(dir, entry.key));
      }
    }

    final keptKeys = kept.map((entry) => entry.key).toSet();
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.blob')) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      final key = name.substring(0, name.length - '.blob'.length);
      if (!keptKeys.contains(key)) {
        await _deleteFileIfExists(entity);
      }
    }
    await _saveIndex(prefs, kept);
  }

  Future<void> _deleteFileIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Cache files are disposable; failed cleanup should not break the UI.
    }
  }

  Future<void> _deleteDirectoryIfExists(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // Cache files are disposable; failed cleanup should not break the UI.
    }
  }

  Future<void> _deleteFilesWithPrefix(Directory dir, String prefix) async {
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith(prefix)) {
          await _deleteFileIfExists(entity);
        }
      }
    } catch (_) {
      // Cache files are disposable; failed cleanup should not break the UI.
    }
  }
}

class _ImageCacheIndexEntry {
  const _ImageCacheIndexEntry({
    required this.key,
    required this.sizeBytes,
    required this.cachedAt,
    required this.lastUsedAt,
  });

  final String key;
  final int sizeBytes;
  final DateTime cachedAt;
  final DateTime lastUsedAt;

  _ImageCacheIndexEntry copyWith({DateTime? lastUsedAt}) =>
      _ImageCacheIndexEntry(
        key: key,
        sizeBytes: sizeBytes,
        cachedAt: cachedAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );

  factory _ImageCacheIndexEntry.fromJson(Map<String, dynamic> json) =>
      _ImageCacheIndexEntry(
        key: json['key'] as String? ?? '',
        sizeBytes: _intFromJson(json['sizeBytes']),
        cachedAt: _dateFromJson(json['cachedAt']),
        lastUsedAt: _dateFromJson(json['lastUsedAt']),
      );

  Map<String, dynamic> toJson() => {
    'key': key,
    'sizeBytes': sizeBytes,
    'cachedAt': cachedAt.millisecondsSinceEpoch,
    'lastUsedAt': lastUsedAt.millisecondsSinceEpoch,
  };
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return 0;
}

DateTime _dateFromJson(Object? value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
