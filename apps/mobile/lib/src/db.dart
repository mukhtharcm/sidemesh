import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class SidemeshDb {
  SidemeshDb._();

  static Database? _db;

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final dbPath = join(dir, 'sidemesh_v1.db');
    return openDatabase(
      dbPath,
      version: 1,
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
    );
  }

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}
