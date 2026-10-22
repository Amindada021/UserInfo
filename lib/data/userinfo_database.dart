import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import '../core/text_normalizer.dart';

class SearchFilters {
  const SearchFilters({
    this.query = '',
    this.searchType = 'name',
    this.favoritesOnly = false,
    this.bank = '',
    this.fields = const {},
    this.missingMobile = false,
    this.birthFrom = '',
    this.birthTo = '',
  });
  final String query;
  final String searchType;
  final bool favoritesOnly;
  final String bank;
  final Map<String, String> fields;
  final bool missingMobile;
  final String birthFrom;
  final String birthTo;
}

class NameIndexStatus {
  const NameIndexStatus({required this.done, required this.target});
  final int done;
  final int target;
  bool get ready => done >= target;
  double get fraction => target == 0 ? 1 : (done / target).clamp(0, 1);
}

class UserInfoDatabase {
  Database? _db;
  bool _nameIndexReady = false;
  bool _nameIndexBuildRunning = false;
  bool _maintenanceRunning = false;
  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final location = path.join(await getDatabasesPath(), 'userinfo.sqlite');
    final database = await openDatabase(
      location,
      version: 4,
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Preserve imported people while irreversibly removing source-file metadata.
          await database.execute("UPDATE files SET uri = '', name = '', size_bytes = NULL");
          await database.execute("UPDATE records SET part = ''");
          await database.execute("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
        }
        if (oldVersion < 3) {
          await _setupNameIndex(database, existingRecords: true);
        }
        if (oldVersion < 4) {
          await _setupFavorites(database);
        }
      },
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
        await database.execute('CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await _setupNameIndex(database, existingRecords: false);
        await _setupFavorites(database);
      },
    );
    _nameIndexReady = (await _readNameIndexStatus(database)).ready;
    return database;
  }

  /// Indexed names are derived from normalized_name; no original identities
  /// or personal banking fields are copied into the FTS4 index.
  Future<void> _setupNameIndex(DatabaseExecutor executor,
      {required bool existingRecords}) async {
    await executor.execute(
      'CREATE VIRTUAL TABLE IF NOT EXISTS record_name_fts '
      'USING fts4(normalized_name, tokenize=unicode61, order=DESC)');
    await executor.execute(
      'CREATE TRIGGER IF NOT EXISTS record_name_fts_insert '
      'AFTER INSERT ON records BEGIN '
      'INSERT INTO record_name_fts(docid, normalized_name) '
      'VALUES (new.id, new.normalized_name); END');
    await executor.execute(
      'CREATE TRIGGER IF NOT EXISTS record_name_fts_delete '
      'BEFORE DELETE ON records BEGIN '
      'DELETE FROM record_name_fts WHERE docid = old.id; END');
    await executor.execute(
      'CREATE TRIGGER IF NOT EXISTS record_name_fts_update '
      'AFTER UPDATE OF normalized_name ON records BEGIN '
      'DELETE FROM record_name_fts WHERE docid = old.id; '
      'INSERT INTO record_name_fts(docid, normalized_name) '
      'VALUES (new.id, new.normalized_name); END');
    final highWaterMark = existingRecords
        ? (Sqflite.firstIntValue(await executor.rawQuery(
            'SELECT COALESCE(MAX(id), 0) FROM records')) ?? 0)
        : 0;
    await executor.insert('app_settings',
        {'key': 'name_index_target', 'value': highWaterMark.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await executor.insert('app_settings',
        {'key': 'name_index_cursor', 'value': '0'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _setupFavorites(DatabaseExecutor executor) async {
    await executor.execute('CREATE TABLE IF NOT EXISTS favorites ('
        'record_id INTEGER PRIMARY KEY REFERENCES records(id) ON DELETE CASCADE)');
  }

  Future<NameIndexStatus> _readNameIndexStatus(
      DatabaseExecutor executor) async {
    final settings = await executor.query('app_settings',
        columns: ['key', 'value'],
        where: 'key IN (?, ?)',
        whereArgs: ['name_index_target', 'name_index_cursor']);
    final map = {
      for (final setting in settings)
        setting['key'] as String: setting['value'].toString()
    };
    final target = int.tryParse(map['name_index_target'] ?? '') ?? 0;
    final done = int.tryParse(map['name_index_cursor'] ?? '') ?? 0;
    return NameIndexStatus(done: done, target: target);
  }

  Future<NameIndexStatus> nameIndexStatus() async =>
      _readNameIndexStatus(await db);

  /// Commits FTS inserts and cursor together, preserving crash recovery.
  /// Triggers index all new imports immediately, outside the old-data window.
  Future<NameIndexStatus> buildNameIndexChunk({int limit = 1200}) async {
    if (limit < 1 || limit > 5000) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..5000');
    }
    final database = await db;
    if (_nameIndexReady || _nameIndexBuildRunning) {
      return _readNameIndexStatus(database);
    }
    _nameIndexBuildRunning = true;
    try {
      final status = await database.transaction((tx) async {
        final current = await _readNameIndexStatus(tx);
        if (current.ready) return current;
        final rows = await tx.rawQuery(
          'SELECT id, normalized_name FROM records '
          'WHERE id > ? AND id <= ? ORDER BY id LIMIT ?',
          [current.done, current.target, limit],
        );
        final batch = tx.batch();
        for (final row in rows) {
          batch.rawInsert(
            'INSERT OR REPLACE INTO record_name_fts(docid, normalized_name) '
            'VALUES (?, ?)',
            [row['id'], row['normalized_name']],
          );
        }
        await batch.commit(noResult: true);
        final next = rows.length < limit
            ? current.target
            : rows.last['id'] as int;
        await tx.insert('app_settings',
          {'key': 'name_index_cursor', 'value': next.toString()},
          conflictAlgorithm: ConflictAlgorithm.replace);
        return NameIndexStatus(done: next, target: current.target);
      });
      if (status.ready) _nameIndexReady = true;
      return status;
    } finally {
      _nameIndexBuildRunning = false;
    }
  }

  /// For FTS4 the wildcard belongs inside each quoted term.
  /// Every term can match a prefix anywhere within a complete name.
  static String nameFtsQuery(String input) {
    final normalized = TextNormalizer.normalize(input);
    final tokens = normalized.split(
        RegExp(r'[^a-z0-9\u0621-\u06FF]+'))
        .where((token) => token.isNotEmpty);
    return tokens.map((token) => '"$token*"').join(' ');
  }

  Future<bool> showFullDetails() async {
    final database = await db;
    final rows = await database.query('app_settings', columns: ['value'],
        where: 'key = ?', whereArgs: ['show_full_details'], limit: 1);
    return rows.isNotEmpty && rows.first['value'] == 'true';
  }

  Future<void> setShowFullDetails(bool value) async {
    final database = await db;
    await database.insert('app_settings',
        {'key': 'show_full_details', 'value': value.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// A crashed or interrupted import retains all committed batches.
  /// Import state becomes partial so a later attempt cannot silently delete
  /// 1.8 million successfully saved people.
  Future<void> discardInterruptedImports() async {
    final database = await db;
    await database.update('files', {'state': 'partial'},
        where: 'state = ?', whereArgs: ['importing']);
  }

  Future<void> markPartial(int fileId) async {
    final database = await db;
    await database.update('files', {'state': 'partial'},
        where: 'id = ?', whereArgs: [fileId]);
  }

  Future<int> partialRecordCount() async {
    final database = await db;
    final results = await database.rawQuery(
        'SELECT COALESCE(SUM(imported_count), 0) AS total FROM files WHERE state = ?',
        ['partial']);
    return (results.first['total'] as num).toInt();
  }

  // File rows are anonymous internal import transactions. The device never
  // persists the URI, filename, part or file size.
  Future<int> beginFile({required String bank}) async {
    final database = await db;
    return database.insert('files', {
      'uri': '',
      'name': '',
      'bank': bank,
      'size_bytes': null,
      'state': 'importing',
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

  static String _escapeLike(String input) => input
      .replaceAll('!', '!!')
      .replaceAll('%', '!%')
      .replaceAll('_', '!_');

  (String, List<Object?>) _where(SearchFilters filters) {
    final conditions = <String>[];
    final args = <Object?>[];
    if (filters.favoritesOnly) {
      conditions.add('r.id IN (SELECT record_id FROM favorites)');
    }
    if (filters.bank.isNotEmpty) {
      conditions.add('r.bank = ?');
      args.add(filters.bank);
    }
    final query = TextNormalizer.normalize(filters.query);
    if (query.isNotEmpty) {
      if (filters.searchType == 'name' && _nameIndexReady &&
          nameFtsQuery(query).isNotEmpty) {
        conditions.add('record_name_fts MATCH ?');
        args.add(nameFtsQuery(query));
      } else if (filters.searchType == 'mobile' ||
          filters.searchType == 'national') {
        // Normalized search digits, raw identifying values remain unchanged.
        final column = filters.searchType == 'mobile'
            ? 'mobile' : 'national_code';
        conditions.add('r.$column LIKE ? ESCAPE \'!\'');
        args.add('${_escapeLike(query)}%');
      } else {
        // Match name or surname anywhere, regardless of word order.
        for (final word in query.split(' ').where((v) => v.isNotEmpty)) {
          conditions.add("r.normalized_name LIKE ? ESCAPE '!'");
          args.add('%${_escapeLike(word)}%');
        }
      }
    }
    for (final entry in filters.fields.entries) {
      if (!allowedFields.contains(entry.key) || entry.value.trim().isEmpty) {
        continue;
      }
      final value = TextNormalizer.normalize(entry.value);
      if (entry.key == 'full_name') {
        conditions.add("r.normalized_name LIKE ? ESCAPE '!'");
        args.add('%${_escapeLike(value)}%');
      } else if (entry.key == 'father_name') {
        conditions.add("r.normalized_father LIKE ? ESCAPE '!'");
        args.add('%${_escapeLike(value)}%');
      } else if (entry.key == 'city_name') {
        conditions.add("r.normalized_city LIKE ? ESCAPE '!'");
        args.add('%${_escapeLike(value)}%');
      } else if (entry.key == 'province_name') {
        conditions.add("r.normalized_province LIKE ? ESCAPE '!'");
        args.add('%${_escapeLike(value)}%');
      } else {
        // Identifier searches are exact/prefix. Other text uses a prefix scan.
        conditions.add("r.${entry.key} LIKE ? ESCAPE '!'");
        args.add('${_escapeLike(value)}%');
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

  String _from(SearchFilters filters) {
    if (filters.searchType == 'name' &&
        filters.query.trim().isNotEmpty &&
        _nameIndexReady &&
        nameFtsQuery(filters.query).isNotEmpty) {
      return 'records r JOIN record_name_fts ON '
          'record_name_fts.docid = r.id';
    }
    return 'records r';
  }

  Future<int> count(SearchFilters filters) async {
    final database = await db;
    final (where, args) = _where(filters);
    final result = await database.rawQuery(
        'SELECT COUNT(*) AS count FROM ${_from(filters)} $where', args);
    return (result.first['count'] as num).toInt();
  }

  Future<List<Map<String, Object?>>> search(
      SearchFilters filters, {int page = 0, int pageSize = 20}) async {
    final database = await db;
    final (where, args) = _where(filters);
    return database.rawQuery('''
      SELECT r.*, EXISTS(SELECT 1 FROM favorites f WHERE f.record_id = r.id) AS is_favorite
      FROM ${_from(filters)} $where
      ORDER BY r.id DESC
      LIMIT ? OFFSET ?
    ''', [...args, pageSize, page * pageSize]);
  }

  Future<bool> toggleFavorite(int id) async {
    final database = await db;
    final exists = await database.query('favorites',
        where: 'record_id = ?', whereArgs: [id], limit: 1);
    if (exists.isNotEmpty) {
      await database.delete('favorites', where: 'record_id = ?', whereArgs: [id]);
      return false;
    }
    await database.insert('favorites', {'record_id': id},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
  }

  Future<void> updatePerson(int id, Map<String, String?> changed) async {
    final valid = <String, Object?>{};
    for (final entry in changed.entries) {
      if (!allowedFields.contains(entry.key)) {
        throw ArgumentError('Invalid field: ${entry.key}');
      }
      valid[entry.key] = TextNormalizer.cleaned(entry.value);
    }
    if (valid.isEmpty) return;
    if (valid.containsKey('full_name')) {
      valid['normalized_name'] = TextNormalizer.normalize(
          valid['full_name']?.toString() ?? '');
    }
    if (valid.containsKey('father_name')) {
      valid['normalized_father'] = TextNormalizer.normalize(
          valid['father_name']?.toString() ?? '');
    }
    if (valid.containsKey('city_name')) {
      valid['normalized_city'] = TextNormalizer.normalize(
          valid['city_name']?.toString() ?? '');
    }
    if (valid.containsKey('province_name')) {
      valid['normalized_province'] = TextNormalizer.normalize(
          valid['province_name']?.toString() ?? '');
    }
    final database = await db;
    final n = await database.update('records', valid,
        where: 'id = ?', whereArgs: [id]);
    if (n != 1) throw StateError('Record was not found');
  }

  Future<String> getSetting(String key, {String fallback = ''}) async {
    final database = await db;
    final rows = await database.query('app_settings', columns: ['value'],
        where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? fallback : rows.first['value'].toString();
  }

  Future<void> setSetting(String key, String value) async {
    final database = await db;
    await database.insert('app_settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Block other UI operations while SQLite is closed for a consistent
  /// streamable on-device backup. Never load database bytes in RAM.
  Future<T> withDatabaseClosed<T>(Future<T> Function(String path) task) async {
    if (_maintenanceRunning) throw StateError('Database maintenance active');
    _maintenanceRunning = true;
    final filePath = path.join(await getDatabasesPath(), 'userinfo.sqlite');
    try {
      await _db?.close();
      _db = null;
      return await task(filePath);
    } finally {
      _maintenanceRunning = false;
    }
  }

  Future<void> validateDatabaseFile(String filename) async {
    if (!await File(filename).exists()) throw StateError('Backup is missing');
    final testDb = await openDatabase(filename, readOnly: true);
    try {
      final result = await testDb.rawQuery('PRAGMA quick_check');
      if (result.isEmpty || result.first.values.first != 'ok') {
        throw const FormatException('SQLite quick_check failed');
      }
      final tables = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('records','files','app_settings')");
      if (tables.length != 3) {
        throw const FormatException('Not a UserInfo database');
      }
    } finally {
      await testDb.close();
    }
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
      await tx.delete('favorites');
      await tx.delete('files');
      await tx.insert('app_settings',
          {'key': 'name_index_target', 'value': '0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.insert('app_settings',
          {'key': 'name_index_cursor', 'value': '0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    // VACUUM reclaims unused pages for the personal device.
    await database.execute('VACUUM');
    _nameIndexReady = true;
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }
}
