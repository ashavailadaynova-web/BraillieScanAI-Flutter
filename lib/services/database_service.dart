import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Satu rekaman jejak scan hasil terjemahan Braille.
class ScanRecord {
  final int id;
  final String text;
  final DateTime timestamp;

  const ScanRecord({
    required this.id,
    required this.text,
    required this.timestamp,
  });

  factory ScanRecord.fromMap(Map<String, Object?> map) => ScanRecord(
        id: map['id'] as int,
        text: map['text'] as String,
        timestamp: DateTime.parse(map['timestamp'] as String),
      );
}

/// Service penyimpanan SQLite lokal (tanpa auth/login) untuk menyimpan
/// rekam jejak scan: id, hasil teks, dan waktu scan.
class DatabaseService {
  /// Instance tunggal agar tidak ada koneksi database ganda yang bisa
  /// menyebabkan konflik lock pada file .db yang sama.
  static final DatabaseService instance = DatabaseService();

  static const String _dbName = 'braille_scan.db';
  static const String _table = 'scan_records';

  Database? _db;

  DatabaseService();

  Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String path = p.join(dir.path, _dbName);
    return openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute(
          'CREATE TABLE $_table ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'text TEXT NOT NULL, '
          'timestamp TEXT NOT NULL'
          ')',
        );
      },
    );
  }

  /// Menyimpan satu hasil scan ke riwayat. Mengembalikan [id] baris baru.
  Future<int> addRecord({required String text}) async {
    final Database db = await _database;
    final String clean = text.trim();
    if (clean.isEmpty) return -1;
    return db.insert(_table, {
      'text': clean,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Mengambil seluruh riwayat scan, terbaru di atas.
  Future<List<ScanRecord>> getAllRecords() async {
    final Database db = await _database;
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      orderBy: 'timestamp DESC',
    );
    return rows.map(ScanRecord.fromMap).toList();
  }

  /// Menghapus satu rekaman berdasarkan [id].
  Future<int> deleteRecord(int id) async {
    final Database db = await _database;
    return db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  /// Menghapus seluruh riwayat scan.
  Future<int> clearAll() async {
    final Database db = await _database;
    return db.delete(_table);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}