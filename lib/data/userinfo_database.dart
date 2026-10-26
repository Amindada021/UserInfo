import 'dart:io';
import 'dart:async';
import '../core/performance_metrics.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import '../core/text_normalizer.dart';
import '../core/identifier_query.dart';

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
  UserInfoDatabase({this.databasePath});
  final String? databasePath;
  Database? _db;
  bool _nameIndexReady = false;
  bool _nameIndexBuildRunning = false;
  bool _maintenanceRunning = false;
  Completer<void>? _maintenanceComplete;
  Future<Database>? _opening;
  Future<Database> get db async {
    final maintenance = _maintenanceComplete;
    if (maintenance != null) await maintenance.future;
    if (_db != null) return _db!;
    final pending = _opening ??= _open();
    try {
      return _db = await pending;
    } finally {
      if (identical(_opening, pending)) _opening = null;
    }
  }

  Future<Database> _open() async {
    final location = databasePath ?? path.join(await getDatabasesPath(), 'userinfo.sqlite');
    final database = await openDatabase(
      location,
      version: 8,
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
        if (oldVersion < 7) {
          await _setupImportCheckpoints(database);
        }
        if (oldVersion < 6) {
          await _setupIdentifiers(database);
        }
        if (oldVersion < 5) {
          await _enableBulkIndexMode(database);
        }
        if (oldVersion < 8) {
          // Name, mobile and national_code queries now use the manually
          // populated FTS4/record_identifiers indexes. These three legacy
          // B-trees are redundant, and were still updated on every CSV row.
          await _dropRedundantInsertIndexes(database);
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
            'CREATE INDEX idx_records_bank_id ON records(bank, id)');
        await database.execute(
            'CREATE INDEX idx_records_file_id ON records(file_id, id)');
        // Preserve card-prefix lookups; name and national/mobile indexes are
        // created only in their specialized FTS/identifier tables on demand.
        await database.execute(
            'CREATE INDEX idx_records_card ON records(card_no)');
        await database.execute('CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await _setupNameIndex(database, existingRecords: false);
        await _setupFavorites(database);
        await _enableBulkIndexMode(database);
        await _setupIdentifiers(database);
        await _setupImportCheckpoints(database);
      },
    );
    // Recover if Android terminated the app midway through a bulk import.
    final bulkMode = await database.query('app_settings',
        columns: ['value'], where: 'key = ?',
        whereArgs: ['name_index_bulk_mode'], limit: 1);
    if (bulkMode.isNotEmpty && bulkMode.first['value'] == '1') {
      // Use the already-open handle, never the db getter during _open().
      final lastId = Sqflite.firstIntValue(await database.rawQuery(
          'SELECT COALESCE(MAX(id), 0) FROM records')) ?? 0;
      final status = await _readNameIndexStatus(database);
      if (lastId > status.target) {
        await database.insert('app_settings',
            {'key': 'name_index_target', 'value': lastId.toString()},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await database.insert('app_settings',
          {'key': 'name_index_bulk_mode', 'value': '0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    _nameIndexReady = (await _readNameIndexStatus(database)).ready;
    return database;
  }

  /// No record is deleted: only redundant legacy index pages are freed.
  /// The indexed search paths use FTS4 and record_identifiers instead.
  /// Keep bank/file/card indexes for existing filtering and deletes.
  Future<void> _dropRedundantInsertIndexes(DatabaseExecutor executor) async {
    for (final name in [
      'idx_records_name',
      'idx_records_mobile',
      'idx_records_national',
    ]) {
      await executor.execute('DROP INDEX IF EXISTS $name');
    }
  }

  /// Derived normalized names are still personal data. Neither this index
  /// nor the database is encrypted by the static application passcode.
  Future<void> _setupNameIndex(DatabaseExecutor executor,
      {required bool existingRecords}) async {
    await executor.execute(
      'CREATE VIRTUAL TABLE IF NOT EXISTS record_name_fts '
      'USING fts4(normalized_name, tokenize=unicode61, order=DESC)');
    await executor.execute(
      'CREATE TRIGGER IF NOT EXISTS record_name_fts_insert '
      'AFTER INSERT ON records '
      "WHEN COALESCE((SELECT value FROM app_settings "
      "WHERE key = 'name_index_bulk_mode'), '0') != '1' "
      'BEGIN INSERT INTO record_name_fts(docid, normalized_name) '
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

  Future<void> _enableBulkIndexMode(DatabaseExecutor db) async {
    // Drop/reinstall on schema upgrade so v4 databases also honor bulk mode.
    await db.execute('DROP TRIGGER IF EXISTS record_name_fts_insert');
    await db.execute(
      'CREATE TRIGGER record_name_fts_insert AFTER INSERT ON records '
      "WHEN COALESCE((SELECT value FROM app_settings "
      "WHERE key = 'name_index_bulk_mode'), '0') != '1' "
      'BEGIN INSERT INTO record_name_fts(docid, normalized_name) '
      'VALUES (new.id, new.normalized_name); END');
    await db.insert('app_settings',
        {'key': 'name_index_bulk_mode', 'value': '0'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _setupImportCheckpoints(DatabaseExecutor executor) async {
    await executor.execute('CREATE TABLE IF NOT EXISTS import_checkpoints ('
        'fingerprint TEXT PRIMARY KEY, file_id INTEGER NOT NULL UNIQUE '
        'REFERENCES files(id) ON DELETE CASCADE, csv_record INTEGER NOT NULL DEFAULT 0)');
  }

  Future<bool> hasLegacyImports() async {
    final database = await db;
    return (await database.rawQuery('SELECT 1 FROM files f WHERE imported_count > 0 '
        'AND NOT EXISTS(SELECT 1 FROM import_checkpoints c WHERE c.file_id = f.id) LIMIT 1')).isNotEmpty;
  }

  Future<Map<String, Object?>?> importCheckpoint(String fingerprint) async {
    final database = await db;
    final rows = await database.rawQuery('SELECT c.file_id, c.csv_record, f.state '
        'FROM import_checkpoints c JOIN files f ON f.id=c.file_id WHERE fingerprint=?',
        [fingerprint]);
    return rows.isEmpty ? null : rows.first;
  }

  // A small derived table preserves original identifier strings unchanged.
  // Populated in the same bounded transactions/cursor as the name index.
  static String _digitsSql(String column) {
    var sql = "COALESCE($column, '')";
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    for (var i = 0; i < 10; i++) {
      sql = "replace(replace($sql, '${persian[i]}', '$i'), '${arabic[i]}', '$i')";
    }
    return 'trim($sql)';
  }

  Future<void> _setupIdentifiers(DatabaseExecutor executor) async {
    await executor.execute('CREATE TABLE IF NOT EXISTS record_identifiers ('
        'record_id INTEGER PRIMARY KEY, mobile TEXT NOT NULL, national TEXT NOT NULL)');
    await executor.execute('CREATE INDEX IF NOT EXISTS idx_ident_mobile '
        'ON record_identifiers(mobile, record_id)');
    await executor.execute('CREATE INDEX IF NOT EXISTS idx_ident_national '
        'ON record_identifiers(national, record_id)');
    final mobile = _digitsSql('new.mobile');
    final national = _digitsSql('new.national_code');
    await executor.execute('CREATE TRIGGER IF NOT EXISTS identifiers_insert '
        'AFTER INSERT ON records '
        "WHEN COALESCE((SELECT value FROM app_settings WHERE key = 'name_index_bulk_mode'), '0') != '1' "
        'BEGIN INSERT OR REPLACE INTO record_identifiers VALUES(new.id, $mobile, $national); END');
    await executor.execute('CREATE TRIGGER IF NOT EXISTS identifiers_update '
        'AFTER UPDATE OF mobile, national_code ON records BEGIN '
        'INSERT OR REPLACE INTO record_identifiers VALUES(new.id, $mobile, $national); END');
    await executor.execute('CREATE TRIGGER IF NOT EXISTS identifiers_delete '
        'BEFORE DELETE ON records BEGIN '
        'DELETE FROM record_identifiers WHERE record_id = old.id; END');
    final maxId = Sqflite.firstIntValue(await executor.rawQuery(
        'SELECT COALESCE(MAX(id), 0) FROM records')) ?? 0;
    await executor.insert('app_settings', {'key': 'name_index_target', 'value': '$maxId'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await executor.insert('app_settings', {'key': 'name_index_cursor', 'value': '0'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// During bulk import, defer costly FTS index inserts to incremental
  /// background backfill. B-tree indexes remain available and consistent.
  Future<void> beginFastImport() async {
    final database = await db;
    await database.insert('app_settings',
        {'key': 'name_index_bulk_mode', 'value': '1'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    _nameIndexReady = false;
  }

  /// Make the exact upper bound durable, then restore FTS trigger operation.
  Future<void> finishFastImport() async {
    final database = await db;
    final lastId = Sqflite.firstIntValue(await database.rawQuery(
        'SELECT COALESCE(MAX(id), 0) FROM records')) ?? 0;
    await database.transaction((tx) async {
      final status = await _readNameIndexStatus(tx);
      if (lastId > status.target) {
        await tx.insert('app_settings',
            {'key': 'name_index_target', 'value': lastId.toString()},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await tx.insert('app_settings',
          {'key': 'name_index_bulk_mode', 'value': '0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _nameIndexReady = (await _readNameIndexStatus(database)).ready;
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
        final bulk = await tx.query('app_settings', columns: ['value'],
            where: 'key = ?', whereArgs: ['name_index_bulk_mode']);
        if (bulk.isNotEmpty && bulk.first['value'] == '1') return current;
        final rows = await tx.rawQuery(
          'SELECT id FROM records WHERE id > ? AND id <= ? ORDER BY id LIMIT ?',
          [current.done, current.target, limit]);
        final next = rows.length < limit ? current.target : rows.last['id'] as int;
        await PerformanceMetrics.measure('index_backfill_sql', () async {
          await tx.rawInsert(
            'INSERT INTO record_name_fts(docid, normalized_name) '
            'SELECT id, normalized_name FROM records r WHERE id > ? AND id <= ? '
            'AND NOT EXISTS(SELECT 1 FROM record_name_fts f WHERE f.docid = r.id)',
            [current.done, next]);
          await tx.rawInsert(
            'INSERT OR REPLACE INTO record_identifiers(record_id, mobile, national) '
            'SELECT id, ${_digitsSql('mobile')}, ${_digitsSql('national_code')} '
            'FROM records WHERE id > ? AND id <= ?', [current.done, next]);
        });
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
  Future<int> beginFile({required String bank, String? fingerprint}) async {
    final database = await db;
    return database.transaction((tx) async {
    final id = await tx.insert('files', {
      'uri': '',
      'name': '',
      'bank': bank,
      'size_bytes': null,
      'state': 'importing',
      'created_at': DateTime.now().toIso8601String(),
    });
    if (fingerprint != null) {
      await tx.insert('import_checkpoints', {'fingerprint': fingerprint, 'file_id': id});
    }
    return id;
    });
  }

  Future<void> insertBatch(int fileId, List<Map<String, Object?>> rows,
      {int? csvRecord}) async {
    if (rows.isEmpty && csvRecord == null) return;
    final database = await db;
    final commitWatch = PerformanceMetrics.enabled ? Stopwatch() : null;
    await PerformanceMetrics.measure('insert_transaction', () => database.transaction((tx) async {
      // A configurable 150k-row transaction must not become a single
      // gigantic sqflite Batch / platform-channel payload. Submit bounded
      // groups INSIDE one SQLite transaction so a crash cannot advance
      // its CSV checkpoint past committed data.
      if (rows.isNotEmpty) {
        final columns = rows.first.keys.toList(growable: false);
        const legal = {'file_id', 'bank', 'part', 'row_number',
          'normalized_name', 'normalized_father', 'normalized_city',
          'normalized_province', ...allowedFields};
        if (columns.any((column) => !legal.contains(column))) {
          throw ArgumentError('Invalid insert column');
        }
        final groupSize = 900 ~/ columns.length;
        if (groupSize < 1) throw ArgumentError('Too many columns');
        final tuple = '(${List.filled(columns.length, '?').join(',')})';
        final sqlPrefix = 'INSERT INTO records(${columns.join(',')}) VALUES ';
        const maxPlatformBatchRows = 3000;
        for (var portionStart = 0;
            portionStart < rows.length;
            portionStart += maxPlatformBatchRows) {
          final portionEnd =
              (portionStart + maxPlatformBatchRows).clamp(0, rows.length);
          final batch = tx.batch();
          for (var start = portionStart; start < portionEnd;
              start += groupSize) {
            final end = (start + groupSize).clamp(0, portionEnd);
            final group = rows.sublist(start, end);
            batch.rawInsert(
              '$sqlPrefix${List.filled(group.length, tuple).join(',')}',
              [for (final row in group)
                for (final column in columns) row[column]],
            );
          }
          await PerformanceMetrics.measure('sqlite_batch',
              () => batch.commit(noResult: true));
        }
      }
      if (csvRecord != null) {
        await tx.update('import_checkpoints', {'csv_record': csvRecord},
            where: 'file_id = ?', whereArgs: [fileId]);
      }
      await tx.rawUpdate(
          'UPDATE files SET imported_count = imported_count + ? WHERE id = ?',
          [rows.length, fileId]);
      commitWatch?.start();
    }));
    if (commitWatch != null) {
      PerformanceMetrics.record('commit_completion', commitWatch.elapsedMicroseconds);
    }
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

  (String, List<Object?>) _where(SearchFilters filters, {String? exactIdentifier}) {
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
      if (filters.searchType == 'name' &&
          nameFtsQuery(query).isNotEmpty) {
        conditions.add('record_name_fts MATCH ?');
        args.add(nameFtsQuery(query));
      } else if (filters.searchType == 'mobile' ||
          filters.searchType == 'national') {
        final column = filters.searchType == 'mobile' ? 'mobile' : 'national';
        final identifier = IdentifierQuery(query, mobile: column == 'mobile');
        final (predicate, values) = exactIdentifier == null
            ? identifier.predicate('ids.$column')
            : ('ids.$column = ?', <Object?>[exactIdentifier]);
        conditions.add(predicate);
        args.addAll(values);
      } else if (filters.searchType == 'name') {
        conditions.add('0');
      } else {
        // Advanced text filters retain explicit substring semantics.
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
      if (entry.key == 'mobile' || entry.key == 'national_code') {
        final column = entry.key == 'mobile' ? 'mobile' : 'national';
        final (predicate, values) = IdentifierQuery(value,
            mobile: column == 'mobile').predicate(column);
        conditions.add('r.id IN (SELECT record_id FROM record_identifiers '
            'WHERE $predicate)');
        args.addAll(values);
      } else if (entry.key == 'full_name') {
        final match = nameFtsQuery(value);
        if (match.isEmpty) {
          conditions.add('0');
        } else {
          conditions.add('r.id IN (SELECT docid FROM record_name_fts WHERE record_name_fts MATCH ?)');
          args.add(match);
        }
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
        nameFtsQuery(filters.query).isNotEmpty) {
      return 'record_name_fts CROSS JOIN records r ON '
          'record_name_fts.docid = r.id';
    }
    if (TextNormalizer.normalize(filters.query).isNotEmpty &&
        (filters.searchType == 'mobile' || filters.searchType == 'national')) {
      return 'record_identifiers ids CROSS JOIN records r ON r.id = ids.record_id';
    }
    return 'records r';
  }

  Future<int> count(SearchFilters filters) async {
    final database = await db;
    await _checkIdentifierBreadth(database, filters);
    final (where, args) = _where(filters);
    final result = await PerformanceMetrics.measure('search_count', () => database.rawQuery(
        'SELECT COUNT(*) AS count FROM ${_from(filters)} $where', args));
    return (result.first['count'] as num).toInt();
  }

  Future<List<Map<String, Object?>>> search(
      SearchFilters filters, {int? beforeId, int pageSize = 20}) async {
    if (pageSize < 1 || pageSize > 101) throw ArgumentError('Invalid page size');
    final database = await db;
    await _checkIdentifierBreadth(database, filters);
    if (filters.query.trim().isNotEmpty &&
        (filters.searchType == 'mobile' || filters.searchType == 'national')) {
      final identifier = IdentifierQuery(filters.query,
          mobile: filters.searchType == 'mobile');
      if (identifier.exact) {
        // One equality seek per representation. Each branch stops at LIMIT,
        // even if millions of records share this identifier. Only at most
        // five pages are merged in Dart, never all matching record IDs.
        final found = <int, Map<String, Object?>>{};
        for (final value in identifier.values) {
          final (where, args) = _where(filters, exactIdentifier: value);
          final column = filters.searchType == 'mobile' ? 'mobile' : 'national';
          final rows = await database.rawQuery(
            'SELECT r.*, EXISTS(SELECT 1 FROM favorites f WHERE f.record_id=r.id) AS is_favorite '
            'FROM record_identifiers ids INDEXED BY idx_ident_$column '
            'CROSS JOIN records r ON r.id=ids.record_id $where '
            '${beforeId == null ? '' : 'AND ids.record_id < ?'} '
            'ORDER BY ids.record_id DESC LIMIT ?',
            [...args, if (beforeId != null) beforeId, pageSize]);
          for (final row in rows) {
            found[row['id'] as int] = row;
          }
        }
        final rows = found.values.toList()
          ..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
        return rows.take(pageSize).toList();
      }
    }
    final (where, args) = _where(filters);
    final from = _from(filters);
    final order = from.startsWith('record_name_fts') ? 'record_name_fts.docid' : 'r.id';
    final cursor = beforeId == null ? '' : '${where.isEmpty ? 'WHERE' : 'AND'} $order < ?';
    return PerformanceMetrics.measure('search_rows', () => database.rawQuery(
      'SELECT r.*, EXISTS(SELECT 1 FROM favorites f WHERE f.record_id = r.id) AS is_favorite '
      'FROM $from $where $cursor ORDER BY $order DESC LIMIT ?',
      [...args, if (beforeId != null) beforeId, pageSize]));
  }

  /// Bound prefix work before any record joins or ID sort. A digit minimum
  /// alone is insufficient when millions of rows share the same prefix.
  Future<void> _checkIdentifierBreadth(Database database, SearchFilters filters) async {
    final requests = <(String, String)>[
      if (filters.query.trim().isNotEmpty &&
          (filters.searchType == 'mobile' || filters.searchType == 'national'))
        (filters.searchType, filters.query),
      for (final field in filters.fields.entries)
        if ((field.key == 'mobile' || field.key == 'national_code') &&
            field.value.trim().isNotEmpty)
          (field.key == 'mobile' ? 'mobile' : 'national', field.value),
    ];
    for (final (column, input) in requests) {
      final identifier = IdentifierQuery(input, mobile: column == 'mobile');
      if (identifier.exact) continue;
      final (predicate, args) = identifier.predicate(column);
      final result = await database.rawQuery(
          'SELECT COUNT(*) AS n FROM (SELECT record_id FROM record_identifiers '
          'INDEXED BY idx_ident_$column WHERE $predicate LIMIT 10001)', args);
      if ((result.first['n'] as num) > 10000) {
        throw StateError('نتایج این پیش‌شماره زیاد است؛ رقم‌های بیشتری وارد کنید');
      }
    }
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
    final complete = _maintenanceComplete = Completer<void>();
    try {
      final filePath = databasePath ?? path.join(await getDatabasesPath(), 'userinfo.sqlite');
      if (_opening != null) await _opening;
      final handle = _db;
      if (handle != null) {
        final mode = await handle.rawQuery('PRAGMA journal_mode');
        if (mode.first.values.first == 'wal') {
          final checkpoint = await handle.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
          if (checkpoint.first['busy'] != 0) {
            throw StateError('Database backup checkpoint is busy');
          }
        }
        await handle.close();
      }
      _db = null;
      return await task(filePath);
    } finally {
      _maintenanceRunning = false;
      _maintenanceComplete = null;
      complete.complete();
    }
  }

  Future<void> validateDatabaseFile(String filename) async {
    if (!await File(filename).exists()) throw StateError('Backup is missing');
    final testDb = await openDatabase(filename, readOnly: true);
    try {
      await testDb.execute('PRAGMA cache_size = -16384');
      await testDb.execute('PRAGMA mmap_size = 67108864');
      // A failed check returns specific error rows. Never discard them:
      // they distinguish a damaged DB page from a freelist or index fault.
      // Limit results to 10 structural messages; no user record values are
      // queried or included in the error.
      final result = await testDb.rawQuery('PRAGMA quick_check(10)');
      final messages = result.map((r) => r.values.first?.toString() ?? '')
          .where((message) => message.isNotEmpty)
          .take(10)
          .toList();
      if (messages.length != 1 || messages.single != 'ok') {
        throw FormatException('SQLite quick_check: '
            '${messages.isEmpty ? 'no result returned' : messages.join(' | ')}');
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

  /// Numerical/engine metadata only, never records or query arguments.
  Future<Map<String, Object?>> performanceSnapshot() async {
    final database = await db;
    final output = <String, Object?>{'metrics': PerformanceMetrics.snapshot()};
    for (final pragma in ['journal_mode','synchronous','cache_size','temp_store','mmap_size','page_count','page_size','freelist_count','compile_options']) {
      output[pragma] = await database.rawQuery('PRAGMA $pragma');
    }
    output['sqlite_version'] = await database.rawQuery('SELECT sqlite_version()');
    for (final suffix in ['', '-wal']) {
      final file = File('${database.path}$suffix');
      output[suffix.isEmpty ? 'database_bytes' : 'wal_bytes'] = await file.exists() ? await file.length() : 0;
    }
    try {
      output['object_bytes'] = await database.rawQuery('SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name');
    } catch (_) { output['object_bytes'] = 'dbstat unavailable'; }
    return output;
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }
}

