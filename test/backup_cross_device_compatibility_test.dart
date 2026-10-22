import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/userinfo_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('synthetic v1.6 SQLite backup migrates and opens on a second installation',
      () async {
    final temp = await Directory.systemTemp.createTemp('userinfo_phone_transfer_');
    final source = '${temp.path}/source_v1_6.sqlite';
    final destination = '${temp.path}/second_phone.sqlite';
    Database? old;
    final receiver = UserInfoDatabase(databasePath: destination);
    try {
      // Schema version 5 is the UserInfo v0.1.6 database format.
      old = await openDatabase(source, version: 5,
          onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uri TEXT NOT NULL, name TEXT NOT NULL, size_bytes INTEGER,
            bank TEXT NOT NULL, state TEXT NOT NULL,
            imported_count INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            bank TEXT NOT NULL, part TEXT NOT NULL, row_number INTEGER NOT NULL,
            national_code TEXT, account_number TEXT, full_name TEXT,
            father_name TEXT, id_number TEXT, birth_date TEXT,
            city_name TEXT, province_name TEXT, birth_city TEXT,
            birth_province TEXT, address TEXT, card_no TEXT, mobile TEXT,
            normalized_name TEXT NOT NULL, normalized_father TEXT,
            normalized_city TEXT, normalized_province TEXT
          )
        ''');
        await db.execute(
          'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await db.execute(
          'CREATE TABLE favorites (record_id INTEGER PRIMARY KEY '
          'REFERENCES records(id) ON DELETE CASCADE)');
        await db.execute(
          'CREATE VIRTUAL TABLE record_name_fts '
          'USING fts4(normalized_name, tokenize=unicode61, order=DESC)');
        for (final setting in {
          'name_index_target': '0',
          'name_index_cursor': '0',
          'name_index_bulk_mode': '0',
          'show_full_details': 'false',
        }.entries) {
          await db.insert('app_settings',
              {'key': setting.key, 'value': setting.value});
        }
        await db.insert('files', {
          'id': 1, 'uri': '', 'name': '', 'size_bytes': null,
          'bank': 'ملت', 'state': 'complete', 'imported_count': 1,
          'created_at': '2026-01-01T00:00:00'
        });
        await db.insert('records', {
          'id': 1, 'file_id': 1, 'bank': 'ملت', 'part': '',
          'row_number': 1,
          'full_name': 'شخص آزمایشی',
          'normalized_name': 'شخص آزمایشی',
          'national_code': '0000001234',
          'mobile': '09120000000',
        });
        await db.insert('favorites', {'record_id': 1});
      });
      await old.close();
      old = null;
      // A copy to another handset contains only SQLite data. The second
      // installation uses its own app-private database path.
      await File(source).copy(destination);
      await receiver.validateDatabaseFile(destination);
      expect(await receiver.totalRecords(), 1);
      final rows = await receiver.search(const SearchFilters());
      expect(rows.single['national_code'], '0000001234');
      expect(rows.single['mobile'], '09120000000');
      expect(rows.single['is_favorite'], 1);

      final sql = await receiver.db;
      final version = await sql.rawQuery('PRAGMA user_version');
      expect(version.single.values.single, 7);
      final checkpoints = await sql.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'import_checkpoints'");
      expect(checkpoints, isNotEmpty);
      final identifiers = await sql.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'record_identifiers'");
      expect(identifiers, isNotEmpty);
    } finally {
      await old?.close();
      await receiver.dispose();
      await temp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
