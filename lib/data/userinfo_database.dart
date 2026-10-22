import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import '../core/text_normalizer.dart';

class SearchFilters {
  const SearchFilters({
    this.query = '',
    this.bank = '',
    this.fields = const {},
    this.missingMobile = false,
    this.birthFrom = '',
    this.birthTo = '',
  });
  final String query;
  final String bank;
  final Map<String, String> fields;
  final bool missingMobile;
  final String birthFrom;
  final String birthTo;
}

class UserInfoDatabase {
  Database? _db;
  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final location = path.join(await getDatabasesPath(), 'userinfo.sqlite');
    return openDatabase(
      location,
      version: 1,
      onConfigure: (database) async {
        await database.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uri TEXT NOT NULL,
            name TEXT NOT NULL,
            size_bytes INTEGER,
            bank TEXT NOT NULL,
            state TEXT NOT NULL,
            imported_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            bank TEXT NOT NULL,
            part TEXT NOT NULL,
            row_number INTEGER NOT NULL,
            national_code TEXT, account_number TEXT, full_name TEXT,
            father_name TEXT, id_number TEXT, birth_date TEXT,
            city_name TEXT, province_name TEXT, birth_city TEXT,
            birth_province TEXT, address TEXT, card_no TEXT, mobile TEXT,
            normalized_name TEXT NOT NULL,
            normalized_father TEXT,
            normalized_city TEXT,
            normalized_province TEXT
          )
        ''');
        await database.execute(
            'CREATE INDEX idx_records_name ON records(normalized_name COLLATE NOCASE, id)');
        await database.execute(
            'CREATE INDEX idx_records_bank_id ON records(bank, id)');
        await database.execute(
            'CREATE INDEX idx_records_file_id ON records(file_id, id)');
        await database.execute(
            'CREATE INDEX idx_records_national ON records(national_code)');
        await database.execute(
            'CREATE INDEX idx_records_card ON records(card_no)');
        await database.execute(
            'CREATE INDEX idx_records_mobile ON records(mobile)');
      },
    );
  }

  Future<void> discardInterruptedImports() async {
    final database = await db;
    await database.transaction((tx) async {
      final partial = await tx.query('files',
          columns: ['id'], where: 'state != ?', whereArgs: ['complete']);
      for (final file in partial) {
        await tx.delete('records', where: 'file_id = ?', whereArgs: [file['id']]);
        await tx.delete('files', where: 'id = ?', whereArgs: [file['id']]);
      }
    });
  }

  Future<bool> alreadyImported(String name, int? size, String bank) async {
    final database = await db;
    final rows = await database.query('files',
        columns: ['id'],
        where: size == null
            ? 'name = ? AND bank = ? AND state = ?'
            : 'name = ? AND size_bytes = ? AND bank = ? AND state = ?',
        whereArgs: size == null
            ? [name, bank, 'complete']
            : [name, size, bank, 'complete'],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<int> beginFile({
    required String uri,
    required String name,
    required String bank,
    int? size,
  }) async {
    final database = await db;
    return database.insert('files', {
      'uri': uri, 'name': name, 'bank': bank,
      'size_bytes': size, 'state': 'importing',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> insertBatch(int fileId, List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final database = await db;
    await database.transaction((tx) async {
      final batch = tx.batch();
      for (final row in rows) {
        batch.insert('records', row);
      }
      await batch.commit(noResult: true);
      await tx.rawUpdate(
          'UPDATE files SET imported_count = imported_count + ? WHERE id = ?',
          [rows.length, fileId]);
    });
  }

  Future<void> finishFile(int fileId) async {
    final database = await db;
    await database.update('files', {'state': 'complete'},
        where: 'id = ?', whereArgs: [fileId]);
  }

  Future<void> abandonFile(int fileId) async {
    final database = await db;
    await database.transaction((tx) async {
      await tx.delete('records', where: 'file_id = ?', whereArgs: [fileId]);
      await tx.delete('files', where: 'id = ?', whereArgs: [fileId]);
    });
  }

  static const List<String> allowedFields = [
    'national_code', 'account_number', 'full_name', 'father_name',
    'id_number', 'birth_date', 'city_name', 'province_name',
    'birth_city', 'birth_province', 'address', 'card_no', 'mobile',
  ];

  (String, List<Object?>) _where(SearchFilters filters) {
    final conditions = <String>[];
    final args = <Object?>[];
    if (filters.bank.isNotEmpty) {
      conditions.add('r.bank = ?');
      args.add(filters.bank);
    }
    if (filters.query.trim().isNotEmpty) {
      conditions.add('r.normalized_name LIKE ?');
      args.add('${TextNormalizer.normalize(filters.query)}%');
    }
    for (final entry in filters.fields.entries) {
      if (!(allowedFields.contains(entry.key) || entry.key == 'part') || entry.value.trim().isEmpty) {
        continue;
      }
      final value = TextNormalizer.normalize(entry.value);
      if (entry.key == 'full_name') {
        conditions.add('r.normalized_name LIKE ?');
        args.add('$value%');
      } else if (entry.key == 'father_name') {
        conditions.add('r.normalized_father LIKE ?');
        args.add('$value%');
      } else if (entry.key == 'city_name') {
        conditions.add('r.normalized_city LIKE ?');
        args.add('$value%');
      } else if (entry.key == 'province_name') {
        conditions.add('r.normalized_province LIKE ?');
        args.add('$value%');
      } else {
        // Identifier searches are exact/prefix. Other text uses a prefix scan.
        conditions.add('r.${entry.key} LIKE ?');
        args.add('${entry.value.trim()}%');
      }
    }
    if (filters.missingMobile) {
      conditions.add('(r.mobile IS NULL OR r.mobile = ?)');
      args.add('');
    }
    if (filters.birthFrom.isNotEmpty) {
      conditions.add('r.birth_date >= ?');
      args.add(filters.birthFrom);
    }
    if (filters.birthTo.isNotEmpty) {
      conditions.add('r.birth_date <= ?');
      args.add(filters.birthTo);
    }
    return (conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}', args);
  }

  Future<int> count(SearchFilters filters) async {
    final database = await db;
    final (where, args) = _where(filters);
    final result = await database.rawQuery(
        'SELECT COUNT(*) AS count FROM records r $where', args);
    return (result.first['count'] as num).toInt();
  }

  Future<List<Map<String, Object?>>> search(
      SearchFilters filters, {int page = 0, int pageSize = 20}) async {
    final database = await db;
    final (where, args) = _where(filters);
    return database.rawQuery('''
      SELECT r.* FROM records r $where
      ORDER BY r.id DESC
      LIMIT ? OFFSET ?
    ''', [...args, pageSize, page * pageSize]);
  }

  Future<List<Map<String, Object?>>> byIds(Iterable<int> ids) async {
    final values = ids.toList();
    if (values.isEmpty) return [];
    if (values.length > 900) {
      throw ArgumentError('Selection is too large for one export');
    }
    final database = await db;
    final markers = List.filled(values.length, '?').join(',');
    return database.rawQuery(
        'SELECT * FROM records WHERE id IN ($markers) ORDER BY id DESC', values);
  }

  Future<int> totalRecords() async {
    final database = await db;
    final result = await database.rawQuery('SELECT COUNT(*) AS c FROM records');
    return (result.first['c'] as num).toInt();
  }

  Future<void> deleteEverything() async {
    final database = await db;
    await database.transaction((tx) async {
      await tx.delete('records');
      await tx.delete('files');
    });
    // VACUUM reclaims unused pages for the personal device.
    await database.execute('VACUUM');
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }
}
