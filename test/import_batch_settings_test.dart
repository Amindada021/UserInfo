import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/csv_source.dart';
import 'package:userinfo/data/import_controller.dart';
import 'package:userinfo/data/userinfo_database.dart';

import 'import_resume_test.dart' show SyntheticSource;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('custom batch setting persists, applies next import and preserves rows',
      () async {
    final folder = await Directory.systemTemp.createTemp('userinfo_custom_batch_');
    final filename = '${folder.path}/userinfo.sqlite';
    var database = UserInfoDatabase(databasePath: filename);
    try {
      await database.setSetting('import_batch_rows', '7500');
      expect(await database.getSetting('import_batch_rows'), '7500');
      await database.dispose();
      database = UserInfoDatabase(databasePath: filename);
      final csv = StringBuffer('NATIONAL_CODE,CARD_NO,FULL_NAME,BIRTH_DATE,MOBILE\n');
      for (var i = 0; i < 7500; i++) {
        csv.writeln('0000000000,0000000000000000,شخص آزمایشی $i,,09000000000');
      }
      final payload = Uint8List.fromList(utf8.encode(csv.toString()));
      final source = SyntheticSource(payload);
      final importer = ImportController(database, source);
      final document = CsvDocument(
          uri: 'synthetic:custom-batch', name: 'test.csv',
          size: payload.length);
      try {
        await importer.importDocuments([document]);
        expect(importer.lastError, isNull);
        expect(importer.batchRows, 7500);
        expect(importer.maxCommittedBatchRows, 7500);
        expect(await database.totalRecords(), 7500);
        expect(source.logs.toString(), contains('batchTarget=7500'));
        expect(source.logs.toString(), contains('maxCommittedBatchRows=7500'));
      } finally {
        importer.dispose();
      }
    } finally {
      await database.dispose();
      await folder.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('user can select 150k without loading 150k rows into test memory',
      () async {
    final folder = await Directory.systemTemp.createTemp('userinfo_max_batch_');
    final database = UserInfoDatabase(
        databasePath: '${folder.path}/userinfo.sqlite');
    final payload = Uint8List.fromList(utf8.encode(
        'NATIONAL_CODE,CARD_NO,FULL_NAME,BIRTH_DATE,MOBILE\n'
        '0000000000,0000000000000000,نمونه ساختگی,,09000000000\n'));
    final source = SyntheticSource(payload);
    final importer = ImportController(database, source);
    try {
      await database.setSetting('import_batch_rows', '150000');
      await importer.importDocuments([
        CsvDocument(uri: 'synthetic:max-batch', name: 'test.csv',
            size: payload.length)
      ]);
      expect(importer.lastError, isNull);
      expect(importer.batchRows, 150000);
      expect(await database.totalRecords(), 1);
      expect(importer.maxCommittedBatchRows, 1);
    } finally {
      importer.dispose();
      await database.dispose();
      await folder.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
