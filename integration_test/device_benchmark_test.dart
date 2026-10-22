import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:userinfo/data/userinfo_database.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('synthetic Android SQLite capacity benchmark', (tester) async {
    const rows = int.fromEnvironment('USERINFO_BENCHMARK_ROWS', defaultValue: 100000);
    const batchSize = int.fromEnvironment('USERINFO_BATCH_SIZE', defaultValue: 1500);
    final directory = await Directory((await getTemporaryDirectory()).path).createTemp('synthetic_benchmark_');
    final database = UserInfoDatabase(databasePath: '${directory.path}/benchmark.sqlite');
    try {
      await database.beginFastImport();
      final file = await database.beginFile(bank: 'آزمایشی');
      final insert = Stopwatch()..start();
      for (var start = 0; start < rows; start += batchSize) {
        final count = (rows-start).clamp(0,batchSize);
        await database.insertBatch(file, List.generate(count, (i) => {
          'file_id':file,'bank':'آزمایشی','part':'','row_number':start+i+1,
          'full_name':'نمونه ساختگی ${start+i}',
          'normalized_name':'نمونه ساختگی ${start+i}',
          'mobile':'09${(start+i).toString().padLeft(9,'0')}',
        }));
      }
      insert.stop();
      await database.finishFastImport();
      final indexing = Stopwatch()..start();
      while (!(await database.buildNameIndexChunk(limit:2500)).ready) {}
      indexing.stop();
      final queries = <String, Object>{};
      for (final entry in {
        'absent_name': const SearchFilters(query:'نامناموجود'),
        'common_name': const SearchFilters(query:'ساخت'),
        'identifier': const SearchFilters(query:'09000000100',searchType:'mobile'),
      }.entries) {
        final samples=<int>[];
        for(var i=0;i<30;i++) {
          final watch=Stopwatch()..start();
          await database.search(entry.value);
          samples.add(watch.elapsedMicroseconds);
        }
        samples.sort();
        queries[entry.key]={'p50_us':samples[14],'p95_us':samples[28]};
      }
      binding.reportData={'rows':rows,'batch':batchSize,
        'insert_rows_sec':rows*1000000/insert.elapsedMicroseconds,
        'index_seconds':indexing.elapsedMilliseconds/1000,
        'search':queries,...await database.performanceSnapshot()};
      // ignore: avoid_print
      print('USERINFO_DEVICE_BENCHMARK ${jsonEncode(binding.reportData)}');
      expect(await database.totalRecords(),rows);
    } finally {
      await database.dispose();
      await directory.delete(recursive:true);
    }
  }, timeout: const Timeout(Duration(hours: 12)));
}
