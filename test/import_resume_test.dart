import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/csv_source.dart';
import 'package:userinfo/data/import_controller.dart';
import 'package:userinfo/data/userinfo_database.dart';

class SyntheticSource extends CsvSource {
  SyntheticSource(this.data);
  final Uint8List data;
  int position = 0;
  final logs = StringBuffer();
  @override Future<void> open(CsvDocument document) async { position = 0; }
  @override Future<Uint8List?> read() async {
    if (position >= data.length) return null;
    final end = (position + 8192).clamp(0, data.length);
    final chunk = Uint8List.sublistView(data, position, end);
    position = end;
    return chunk;
  }
  @override Future<void> close() async {}
  @override Future<int> freeBytes() async => 1024 * 1024 * 1024;
  @override Future<void> protectImport(bool enabled) async {}
  @override Future<void> reportImportProgress({required int fileIndex, required int fileCount, required int percent}) async {}
  @override Future<String> openImportLog() async => 'synthetic-log';
  @override Future<void> appendImportLog(String value) async { logs.write(value); }
  @override Future<void> closeImportLog() async {}
}
class InterruptedDatabase extends UserInfoDatabase {
  bool interrupt = true;
  int calls = 0;
  @override Future<void> insertBatch(int fileId, List<Map<String, Object?>> rows, {int? csvRecord}) async {
    if (interrupt && ++calls == 2) throw ImportCancelled();
    await super.insertBatch(fileId, rows, csvRecord: csvRecord);
  }
}
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test('resume after commit keeps malformed/multiline boundaries and never duplicates', () async {
    final temp = await Directory.systemTemp.createTemp('userinfo_resume_');
    await databaseFactory.setDatabasesPath(temp.path);
    final database = InterruptedDatabase();
    final csv = StringBuffer('NATIONAL_CODE,CARD_NO,FULL_NAME,BIRTH_DATE,MOBILE\n');
    for (var i = 0; i < 3100; i++) {
      if (i == 1200 || i == 1700) csv.writeln('bad,row');
      csv.writeln('0000000000,0000000000000000,"نمونه\nساختگی $i",,09000000000');
    }
    final source = SyntheticSource(Uint8List.fromList(utf8.encode(csv.toString())));
    final controller = ImportController(database, source);
    final doc = CsvDocument(uri: 'synthetic:test', name: 'test.csv', size: source.data.length);
    try {
      await controller.importDocuments([doc]);
      expect(await database.totalRecords(), 1500);
      await database.dispose();
      database.interrupt = false;
      await controller.importDocuments([doc]);
      expect(controller.lastError, isNull);
      expect(await database.totalRecords(), 3100);
      await controller.importDocuments([doc]);
      expect(await database.totalRecords(), 3100);
      expect(controller.inserted, 0);
      final duplicates = await (await database.db).rawQuery(
          'SELECT row_number FROM records GROUP BY row_number HAVING COUNT(*)>1');
      expect(duplicates, isEmpty);
      expect(source.logs.toString(), isNot(contains('09000000000')));
      expect(source.logs.toString(), isNot(contains('نمونه')));
    } finally {
      controller.dispose();
      await database.dispose();
      await temp.delete(recursive: true);
    }
  });
}
