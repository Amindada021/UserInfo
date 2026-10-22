import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:userinfo/data/userinfo_database.dart';

void main() {
  test('synthetic insert benchmark, same schema and durability', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final results = <Map<String, Object>>[];
    for (final size in [1000, 1500, 2000, 5000]) {
      for (final mode in ['legacy', 'grouped']) {
        final temp = await Directory.systemTemp.createTemp('userinfo_bench_');
        await databaseFactory.setDatabasesPath(temp.path);
        final database = UserInfoDatabase();
        try {
          await database.beginFastImport();
          final fileId = await database.beginFile(bank: 'آزمایشی');
          final handle = await database.db;
          final times = <int>[];
          const total = 100000;
          final watch = Stopwatch()..start();
          for (var start = 0; start < total; start += size) {
            final rows = List.generate(size, (i) => <String, Object?>{
              'file_id': fileId, 'bank': 'آزمایشی', 'part': '', 'row_number': start+i+1,
              for (final field in UserInfoDatabase.allowedFields) field: '',
              'full_name': 'نمونه ساختگی ${start+i}',
              'mobile': '09${(start+i).toString().padLeft(9, '0')}',
              'normalized_name': 'نمونه ساختگی ${start+i}',
              'normalized_father': '', 'normalized_city': '', 'normalized_province': '',
            });
            final batchWatch = Stopwatch()..start();
            if (mode == 'legacy') {
              await handle.transaction((tx) async {
                final batch = tx.batch();
                for (final row in rows) { batch.insert('records', row); }
                await batch.commit(noResult: true);
                await tx.rawUpdate('UPDATE files SET imported_count=imported_count+? WHERE id=?',[size,fileId]);
              });
            } else {
              await database.insertBatch(fileId, rows);
            }
            times.add(batchWatch.elapsedMicroseconds);
          }
          watch.stop();
          times.sort();
          final saved = await database.totalRecords();
          expect(saved, ((total+size-1)~/size)*size);
          results.add({'mode':mode, 'batch':size,'rows':saved,
            'rows_sec':saved*1000000/watch.elapsedMicroseconds,
            'batch_p50_us':times[times.length~/2],
            'batch_p95_us':times[(times.length*.95).ceil()-1],
            'database_bytes':await File(handle.path).length(),
            'journal':(await handle.rawQuery('PRAGMA journal_mode')).first.values.first!,
            'synchronous':(await handle.rawQuery('PRAGMA synchronous')).first.values.first!});
        } finally {
          await database.dispose();
          await temp.delete(recursive:true);
        }
      }
    }
    // Synthetic measurements only. Host FFI results do not measure Android channel cost.
    // ignore: avoid_print
    print('USERINFO_INSERT_BENCHMARK ${jsonEncode(results)}');
  }, skip: !const bool.fromEnvironment('USERINFO_RUN_BENCHMARK'),
    timeout: const Timeout(Duration(minutes: 10)));
}
