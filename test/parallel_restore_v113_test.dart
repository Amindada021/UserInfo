import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/userinfo_database.dart';

void main() {
  test('v0.1.13 schema 7 backup opens in separate Next sandbox unchanged', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('next_restore_');
    final legacy = UserInfoDatabase(databasePath: '${dir.path}/legacy.sqlite');
    final next = UserInfoDatabase(databasePath: '${dir.path}/next.sqlite');
    try {
      final fileId = await legacy.beginFile(bank: 'test');
      await legacy.insertBatch(fileId, [{
        'file_id': fileId, 'bank': 'test', 'part': '', 'row_number': 1,
        'full_name': 'شخص آزمایشی', 'normalized_name': 'شخص آزمایشی',
        'mobile': '۰۹۱۲۰۰۰۰۰۰۱', 'national_code': '0000001234',
      }]);
      await legacy.toggleFavorite(1);
      final db = await legacy.db;
      // v1.13 uses schema 7 with these extra indexes; v8 only drops indexes.
      await db.execute('CREATE INDEX idx_records_mobile ON records(mobile)');
      await db.execute('CREATE INDEX idx_records_national ON records(national_code)');
      await db.execute('CREATE INDEX idx_records_name ON records(normalized_name)');
      await db.setVersion(7);
      await legacy.dispose();
      final source = File('${dir.path}/legacy.sqlite');
      final originalBytes = await source.readAsBytes();
      await source.copy('${dir.path}/next.sqlite');
      await next.validateDatabaseFile('${dir.path}/next.sqlite');
      expect(await next.totalRecords(), 1);
      final rows = await next.search(const SearchFilters(
          query: '+989120000001', searchType: 'mobile'));
      expect(rows.single['mobile'], '۰۹۱۲۰۰۰۰۰۰۱');
      expect(rows.single['national_code'], '0000001234');
      expect(rows.single['is_favorite'], 1);
      expect(await (await next.db).getVersion(), 8);
      expect(await source.readAsBytes(), originalBytes);
    } finally {
      await legacy.dispose();
      await next.dispose();
      await dir.delete(recursive: true);
    }
  });
}
