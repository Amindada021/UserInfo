import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/userinfo_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory temp;
  late UserInfoDatabase database;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('userinfo_synthetic_');
    await databaseFactory.setDatabasesPath(temp.path);
    database = UserInfoDatabase();
  });
  tearDown(() async {
    await database.dispose();
    await temp.delete(recursive: true);
  });
  Future<int> seed({int count = 40}) async {
    final file = await database.beginFile(bank: 'آزمایشی');
    await database.insertBatch(file, List.generate(count, (i) => {
      'file_id': file, 'bank': 'آزمایشی', 'part': '', 'row_number': i + 1,
      'full_name': 'محمدرضا حسینی نژاد', 'normalized_name': 'محمدرضا حسینی نژاد',
      'mobile': '۰۹١۲۰۰۰۰۰۰۰', 'national_code': '۰۰۰۰۰۰۰۰۰۰',
    }));
    return file;
  }
  test('fresh database keeps only indexes needed before manual indexing',
      () async {
    final handle = await database.db;
    final indexes = await handle.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='records'");
    final names = indexes.map((row) => row['name']).toSet();
    for (final name in [
      'idx_records_name', 'idx_records_mobile', 'idx_records_national',
    ]) {
      expect(names.contains(name), isFalse);
    }
    for (final name in ['idx_records_file_id', 'idx_records_bank_id',
        'idx_records_card']) {
      expect(names.contains(name), isTrue);
    }
    await database.beginFastImport();
    await seed(count: 40);
    await database.finishFastImport();
    expect(await database.totalRecords(), 40);
    var index = await database.nameIndexStatus();
    while (!index.ready) {
      index = await database.buildNameIndexChunk(limit: 20);
    }
    expect(await database.count(const SearchFilters(query: 'حسی')), 40);
    expect(await database.count(const SearchFilters(
        query: '0912', searchType: 'mobile')), 40);
    expect(await database.count(const SearchFilters(
        query: '000', searchType: 'national')), 40);
  });

  test('prefix AND terms, original identifiers, keyset, edits and favorites', () async {
    await seed();
    for (final q in ['محمدرضا','حسینی','نژاد','محمدرضا حسینی','حسینی محمدرضا','حسی']) {
      expect(await database.count(SearchFilters(query: q)), 40);
    }
    expect(await database.count(const SearchFilters(query: 'سینی')), 0);
    expect(await database.count(const SearchFilters(query: '0912', searchType: 'mobile')), 40);
    final first = await database.search(const SearchFilters(), pageSize: 20);
    final second = await database.search(const SearchFilters(), beforeId: first.last['id'] as int);
    expect({...first.map((r) => r['id']), ...second.map((r) => r['id'])}.length, 40);
    final id = first.first['id'] as int;
    await database.toggleFavorite(id);
    await database.updatePerson(id, {'full_name': 'نام آزمایشی', 'mobile': '۰۹۳۵۰۰۰۰۰۰۰'});
    expect(await database.count(const SearchFilters(query: 'حسی')), 39);
    expect(await database.count(const SearchFilters(query: '0935', searchType: 'mobile')), 1);
    expect(await database.count(const SearchFilters(favoritesOnly: true)), 1);
    expect((await database.byIds([id])).first['mobile'], '۰۹۳۵۰۰۰۰۰۰۰');
  });
  test('crashed bulk import preserves rows and durable backfill cursor', () async {
    await database.beginFastImport();
    await seed();
    await database.dispose(); // simulate termination without finishFastImport
    database = UserInfoDatabase();
    expect(await database.totalRecords(), 40);
    final status = await database.buildNameIndexChunk(limit: 7);
    expect(status.done, 7);
    await database.dispose();
    database = UserInfoDatabase();
    expect((await database.nameIndexStatus()).done, 7);
    while (!(await database.buildNameIndexChunk(limit: 7)).ready) {}
    expect(await database.count(const SearchFilters(query: 'حسی')), 40);
    expect(await database.count(const SearchFilters(query: '0912', searchType: 'mobile')), 40);
    expect((await (await database.db).rawQuery('PRAGMA integrity_check')).first.values.first, 'ok');
  });
  test('v7 migration drops only duplicate indexes, never imported people',
      () async {
    await seed(count: 50);
    await database.toggleFavorite(1);
    final handle = await database.db;
    await handle.execute(
        'CREATE INDEX idx_records_name ON records(normalized_name COLLATE NOCASE, id)');
    await handle.execute(
        'CREATE INDEX idx_records_national ON records(national_code)');
    await handle.execute(
        'CREATE INDEX idx_records_mobile ON records(mobile)');
    await handle.setVersion(7);
    await database.dispose();
    database = UserInfoDatabase();
    expect(await database.totalRecords(), 50);
    expect(await database.count(
        const SearchFilters(favoritesOnly: true)), 1);
    final names = await (await database.db).rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='records'");
    final namesSet = names.map((row) => row['name']).toSet();
    expect(namesSet.contains('idx_records_name'), isFalse);
    expect(namesSet.contains('idx_records_national'), isFalse);
    expect(namesSet.contains('idx_records_mobile'), isFalse);
    expect((await (await database.db).rawQuery('PRAGMA integrity_check'))
        .first.values.first, 'ok');
    expect(await database.count(const SearchFilters(query: 'حسی')), 50);
  });

  test('v5 migration preserves originals, favorites and partial files', () async {
    await seed();
    await database.toggleFavorite(1);
    final handle = await database.db;
    for (final trigger in ['identifiers_insert','identifiers_update','identifiers_delete']) {
      await handle.execute('DROP TRIGGER $trigger');
    }
    await handle.execute('DROP TABLE record_identifiers');
    await handle.execute('DROP TABLE import_checkpoints');
    await handle.setVersion(5);
    final before = await database.byIds([1,2,3]);
    await database.dispose();
    database = UserInfoDatabase();
    expect(await database.byIds([1,2,3]), before);
    expect(await database.totalRecords(), 40);
    expect(await database.count(const SearchFilters(favoritesOnly: true)), 1);
    while (!(await database.buildNameIndexChunk(limit: 9)).ready) {}
    expect(await database.count(const SearchFilters(query: '000', searchType: 'national')), 40);
  });
  test('failed batch rolls back checkpoint and preserves committed records', () async {
    final file = await database.beginFile(bank: 'آزمایشی', fingerprint: 'synthetic');
    final row = <String,Object?>{'file_id':file,'bank':'آزمایشی','part':'',
      'row_number':1,'normalized_name':'نمونه'};
    await database.insertBatch(file,[row],csvRecord:2);
    await expectLater(database.insertBatch(file,[{...row,'file_id':-1}],csvRecord:3), throwsA(isA<DatabaseException>()));
    expect(await database.totalRecords(),1);
    expect((await database.importCheckpoint('synthetic'))!['csv_record'],2);
  });
  test('closed WAL backup is self-contained and validated', () async {
    await (await database.db).rawQuery('PRAGMA journal_mode=WAL');
    await seed(count:13);
    final copy = '${temp.path}/backup.sqlite';
    await database.withDatabaseClosed((filename) async { await File(filename).copy(copy); });
    await database.validateDatabaseFile(copy);
    final restored = UserInfoDatabase(databasePath:copy);
    try { expect(await restored.totalRecords(),13); }
    finally { await restored.dispose(); }
  });

  test('reads wait until a closed-file maintenance operation completes', () async {
    await seed(count:2);
    Future<int>? pending;
    await database.withDatabaseClosed((filename) async {
      pending = database.totalRecords();
      expect(await File(filename).exists(),true);
    });
    expect(await pending!,2);
  });

}
