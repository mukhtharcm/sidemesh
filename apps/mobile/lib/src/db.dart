import 'dart:io';

import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_directories.dart';

class SidemeshDb {
  SidemeshDb._();

  static bool _ffiInitialized = false;

  static void _ensureFfiIfNeeded() {
    if (Platform.isLinux || Platform.isWindows) {
      if (!_ffiInitialized) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        _ffiInitialized = true;
      }
    }
  }

  static Database? _db;
  static Future<Database>? _openingDb;

  static Future<Database> get instance async {
    final db = _db;
    if (db != null) {
      return db;
    }
    final openingDb = _openingDb;
    if (openingDb != null) {
      return openingDb;
    }

    final future = _open();
    _openingDb = future;
    try {
      final openedDb = await future;
      _db = openedDb;
      return openedDb;
    } finally {
      if (identical(_openingDb, future)) {
        _openingDb = null;
      }
    }
  }

  static void useConfiguredFfiFactoryForTest() {
    _ffiInitialized = true;
  }

  static Future<Database> _open() async {
    _ensureFfiIfNeeded();
    final dbPath = await _resolveDbPath();
    return openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            host_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            title TEXT NOT NULL,
            preview TEXT NOT NULL,
            cwd TEXT NOT NULL,
            provider TEXT,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            runtime_json TEXT,
            git_info_json TEXT,
            is_sub_agent INTEGER NOT NULL DEFAULT 0,
            sub_agent_json TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'recent',
            cached_at INTEGER NOT NULL,
            PRIMARY KEY (host_id, session_id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_host_updated ON sessions(host_id, updated_at DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_favorite ON sessions(host_id, is_favorite, updated_at DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_source ON sessions(source, host_id)',
        );
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN is_sub_agent INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN sub_agent_json TEXT',
          );
        }
      },
    );
  }

  static Future<String> _resolveDbPath() async {
    final dir = Platform.isMacOS
        ? (await getSidemeshApplicationSupportDirectory()).path
        : await getDatabasesPath();
    await Directory(dir).create(recursive: true);
    final dbPath = join(dir, 'sidemesh_v1.db');
    if (Platform.isMacOS) {
      await _migrateLegacyMacosDatabaseIfNeeded(dbPath);
    }
    return dbPath;
  }

  static Future<void> _migrateLegacyMacosDatabaseIfNeeded(String dbPath) async {
    final legacyPath = join(await getDatabasesPath(), 'sidemesh_v1.db');
    if (legacyPath == dbPath) {
      return;
    }
    if (await File(dbPath).exists()) {
      return;
    }
    if (!await File(legacyPath).exists()) {
      return;
    }

    try {
      await _copyIfExists(legacyPath, dbPath);
      await _copyIfExists('$legacyPath-wal', '$dbPath-wal');
      await _copyIfExists('$legacyPath-shm', '$dbPath-shm');
      await _copyIfExists('$legacyPath-journal', '$dbPath-journal');
    } catch (_) {
      // Best-effort migration only. Falling back to a fresh DB is acceptable.
    }
  }

  static Future<void> _copyIfExists(
    String sourcePath,
    String destinationPath,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      return;
    }
    final destination = File(destinationPath);
    await destination.parent.create(recursive: true);
    await source.copy(destinationPath);
  }

  static Future<void> close() async {
    _openingDb = null;
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}
