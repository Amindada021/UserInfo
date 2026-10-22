import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:userinfo/data/csv_source.dart';
import 'package:userinfo/data/userinfo_database.dart';

/// Opt-in hardware benchmark. Uses an isolated synthetic SQLite DB and never
/// opens, updates or deletes the UserInfo production database.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('isolated Android insert/index/search benchmark', (tester) async {
    const rows = int.fromEnvironment('USERINFO_BENCHMARK_ROWS',
        defaultValue: 100000);
    const batchSize = int.fromEnvironment('USERINFO_BATCH_SIZE',
        defaultValue: 1500);
    const minFreeGiB = int.fromEnvironment('USERINFO_MIN_FREE_GIB',
        defaultValue: 5);
    const hoursLimit = int.fromEnvironment('USERINFO_MAX_TEST_HOURS',
        defaultValue: 2);

    if (rows < 1 || rows > 100000000 || batchSize < 1 ||
        batchSize > 5000 || minFreeGiB < 2) {
      throw ArgumentError('Invalid benchmark limits');
    }

    final source = CsvSource();
    final startedFree = await source.freeBytes();
    final minimumFree = minFreeGiB * 1024 * 1024 * 1024;
    if (startedFree < minimumFree) {
      throw StateError('Refusing benchmark: insufficient free storage');
    }

    final root = await getTemporaryDirectory();
    final directory = await root.createTemp('userinfo_isolated_benchmark_');
    final filename = '${directory.path}/synthetic.sqlite';
    final database = UserInfoDatabase(databasePath: filename);
    final allWatch = Stopwatch()..start();
    var inserted = 0;
    final batchTimes = <int>[];
    Map<String, Object?>? result;

    try {
      await database.beginFastImport();
      final file = await database.beginFile(bank: 'آزمایشی');
      final insert = Stopwatch()..start();

      for (var start = 0; start < rows; start += batchSize) {
        if (allWatch.elapsed > Duration(hours: hoursLimit)) {
          throw StateError('Benchmark time guard reached at $inserted rows');
        }
        if (start % (batchSize * 25) == 0) {
          final free = await source.freeBytes();
          if (free < minimumFree) {
            throw StateError('Storage guard stopped test at $inserted rows');
          }
        }
        final count = (rows - start).clamp(0, batchSize);
        final values = List.generate(count, (i) => <String, Object?>{
          'file_id': file,
          'bank': 'آزمایشی',
          'part': '',
          'row_number': start + i + 1,
          'full_name': 'نمونه ساختگی ${start + i}',
          'normalized_name': 'نمونه ساختگی ${start + i}',
          'mobile': '09${(start + i).toString().padLeft(9, '0')}',
          'national_code': (start + i).toString().padLeft(10, '0'),
        });
        final watch = Stopwatch()..start();
        await database.insertBatch(file, values);
        batchTimes.add(watch.elapsedMicroseconds);
        inserted += count;

        if (inserted % 100000 == 0 || inserted == rows) {
          // ignore: avoid_print
          print('USERINFO_DEVICE_PROGRESS '
              '${jsonEncode({'rows': inserted, 'target': rows, 'elapsed_s': insert.elapsedMilliseconds / 1000})}');
        }
      }

      insert.stop();
      await database.finishFastImport();
      final indexing = Stopwatch()..start();
      while (!(await database.buildNameIndexChunk(limit: 2500)).ready) {
        if (allWatch.elapsed > Duration(hours: hoursLimit)) {
          throw StateError('Indexing exceeded benchmark time guard');
        }
        if (indexing.elapsed.inSeconds % 120 == 0) {
          final free = await source.freeBytes();
          if (free < minimumFree) {
            throw StateError('Storage guard stopped name indexing');
          }
        }
      }
      indexing.stop();

      final searches = <String, Object>{};
      for (final entry in {
        'absent_name': const SearchFilters(query: 'نامناموجود'),
        'common_name': const SearchFilters(query: 'ساخت'),
        'identifier': const SearchFilters(
            query: '09000000100', searchType: 'mobile'),
      }.entries) {
        final durations = <int>[];
        for (var i = 0; i < 30; i++) {
          final watch = Stopwatch()..start();
          await database.search(entry.value);
          durations.add(watch.elapsedMicroseconds);
        }
        durations.sort();
        searches[entry.key] = {
          'p50_us': durations[14],
          'p95_us': durations[28],
        };
      }

      batchTimes.sort();
      final fileBytes = await File(filename).length();
      final walFile = File('$filename-wal');
      final walBytes = await walFile.exists() ? await walFile.length() : 0;
      final total = await database.totalRecords();
      expect(total, rows);
      result = {
        'result': 'passed',
        'environment': 'real Android device, isolated synthetic dataset',
        'rows': total,
        'batch': batchSize,
        'insert_rows_per_second': rows * 1000000 /
            insert.elapsedMicroseconds,
        'insert_elapsed_seconds': insert.elapsedMilliseconds / 1000,
        'index_elapsed_seconds': indexing.elapsedMilliseconds / 1000,
        'batch_p50_us': batchTimes[batchTimes.length ~/ 2],
        'batch_p95_us': batchTimes[(batchTimes.length * .95).ceil() - 1],
        'sqlite_bytes': fileBytes,
        'wal_bytes': walBytes,
        'free_bytes_at_start': startedFree,
        'free_bytes_at_finish': await source.freeBytes(),
        'rss_bytes': ProcessInfo.currentRss,
        'max_rss_bytes': ProcessInfo.maxRss,
        'queries': searches,
        ...await database.performanceSnapshot(),
      };
      binding.reportData = result;
      // ignore: avoid_print
      print('USERINFO_DEVICE_BENCHMARK ${jsonEncode(result)}');
    } finally {
      await database.dispose();
      await directory.delete(recursive: true);
      if (result == null) {
        // ignore: avoid_print
        print('USERINFO_DEVICE_BENCHMARK_INCOMPLETE '
            '${jsonEncode({'inserted': inserted, 'requested': rows,
            'elapsed_s': allWatch.elapsed.inSeconds})}');
      }
    }
  }, timeout: const Timeout(Duration(hours: 15)));
}
