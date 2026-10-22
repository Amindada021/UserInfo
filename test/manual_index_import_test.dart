import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/userinfo_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('bulk-imported people remain durable until indexing is manually run',
      () async {
    final folder = await Directory.systemTemp.createTemp('userinfo_manual_index_');
    final file = '${folder.path}/database.sqlite';
    var database = UserInfoDatabase(databasePath: file);

    try {
      await database.beginFastImport();
      final fileId = await database.beginFile(bank: 'آزمایشی');
      await database.insertBatch(fileId, [{
        'file_id': fileId,
        'bank': 'آزمایشی',
        'part': '',
        'row_number': 1,
        'full_name': 'علی رضایی',
        'normalized_name': 'علی رضایی',
        'mobile': '09120000001',
        'national_code': '0000001234',
      }], csvRecord: 2);
      await database.finishFile(fileId);
      await database.finishFastImport();

      expect(await database.totalRecords(), 1);
      var status = await database.nameIndexStatus();
      expect(status.ready, isFalse);
      expect(status.target, greaterThan(0));

      // Closing/reopening must not build the index in the background.
      await database.dispose();
      database = UserInfoDatabase(databasePath: file);
      status = await database.nameIndexStatus();
      expect(status.ready, isFalse);
      expect(await database.totalRecords(), 1);

      // Before pressing the indexing button, no deferred index rows exist.
      final first = await database.search(
          const SearchFilters(query: 'رضایی'));
      expect(first, isEmpty);

      while (!status.ready) {
        status = await database.buildNameIndexChunk(limit: 1);
      }
      final byName = await database.search(
          const SearchFilters(query: 'رضایی'));
      final byMobile = await database.search(
          const SearchFilters(query: '0912', searchType: 'mobile'));
      final byNational = await database.search(
          const SearchFilters(query: '0000', searchType: 'national'));
      expect(byName.length, 1);
      expect(byMobile.length, 1);
      expect(byNational.length, 1);
      expect(await database.totalRecords(), 1);
    } finally {
      await database.dispose();
      await folder.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
