import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:userinfo/data/csv_source.dart';
import 'package:userinfo/data/import_controller.dart';
import 'package:userinfo/data/userinfo_database.dart';

/// Synthetic local-file benchmark; never accesses the real userinfo.sqlite.
class _LocalCsvSource extends CsvSource {
  _LocalCsvSource(this.file);
  final File file;
  RandomAccessFile? input;

  @override
  Future<void> open(CsvDocument document) async {
    await close();
    input = await file.open();
  }

  @override
  Future<Uint8List?> read() async {
    final chunk = await input!.read(1024 * 1024);
    return chunk.isEmpty ? null : Uint8List.fromList(chunk);
  }

  @override
  Future<void> close() async {
    final handle = input;
    input = null;
    await handle?.close();
  }

  @override
  Future<String> openImportLog() async => 'synthetic-log';

  @override
  Future<void> appendImportLog(String value) async {}

  @override
  Future<void> closeImportLog() async {}

  @override
  Future<void> protectImport(bool enabled) async {}

  @override
  Future<void> reportImportProgress({
    required int fileIndex,
    required int fileCount,
    required int percent,
  }) async {}

  @override
  Future<int> freeBytes() async => 32 * 1024 * 1024 * 1024;
}

Future<void> _generateCsv(File file, int records) async {
  final sink = file.openWrite();
  sink.writeln('NATIONAL_CODE,CARD_NO,FULL_NAME,BIRTH_DATE,MOBILE');
  for (var i = 0; i < records; i++) {
    sink.writeln('0000000000,0000000000000000,نمونه ساختگی $i,,09000000000');
  }
  await sink.close();
}

Future<Map<String, Object?>> _flutter(
    File csv, String path, int rows, int batch) async {
  final db = UserInfoDatabase(databasePath: path);
  final source = _LocalCsvSource(csv);
  final import = ImportController(db, source);
  try {
    await db.setSetting('import_batch_rows', '$batch');
    final watch = Stopwatch()..start();
    await import.importDocuments([
      CsvDocument(uri: 'synthetic:local', name: 'synthetic.csv',
          size: await csv.length()),
    ]);
    watch.stop();
    expect(import.lastError, isNull);
    expect(import.inserted, rows);
    expect(await db.totalRecords(), rows);
    return {
      'engine': 'flutter_sqflite',
      'rows': rows,
      'actual_batch_max': import.maxCommittedBatchRows,
      'total_ms': watch.elapsedMicroseconds / 1000.0,
      'rows_per_second': rows * 1000000.0 / watch.elapsedMicroseconds,
      'sqlite_bytes': await File(path).length(),
    };
  } finally {
    import.dispose();
    await source.close();
    await db.dispose();
  }
}

Future<Map<String, Object?>> _native(
    File csv, String path, int rows, int batch) async {
  final setup = UserInfoDatabase(databasePath: path);
  late final int fileId;
  try {
    await setup.beginFastImport();
    final fingerprint = (await sha256.bind(csv.openRead()).first).toString();
    fileId = await setup.beginFile(bank: 'ملی', fingerprint: fingerprint);
  } finally {
    await setup.dispose();
  }

  const channel = MethodChannel('userinfo/csv_stream');
  final outcome = await channel.invokeMapMethod<String, dynamic>(
    'runNativeCsvBenchmark',
    {
      'csvPath': csv.path, 'dbPath': path,
      'fileId': fileId, 'rows': rows, 'batch': batch,
    },
  );
  expect(outcome, isNotNull);
  expect(outcome!['rows'], rows);
  final verify = UserInfoDatabase(databasePath: path);
  try {
    expect(await verify.totalRecords(), rows);
    await verify.finishFastImport();
  } finally {
    await verify.dispose();
  }
  return {'engine': 'kotlin_android_sqlite', ...outcome};
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compare native Kotlin versus actual Dart import pipeline',
      (tester) async {
    const rows = int.fromEnvironment('USERINFO_NATIVE_COMPARE_ROWS',
        defaultValue: 100000);
    const batch = int.fromEnvironment('USERINFO_NATIVE_COMPARE_BATCH',
        defaultValue: 1500);
    if (rows < 100 || rows > 1000000 ||
        batch < 100 || batch > 150000) {
      throw ArgumentError('Out-of-range native benchmark options');
    }
    if (await CsvSource().freeBytes() < 2 * 1024 * 1024 * 1024) {
      throw StateError('Benchmark requires >= 2 GiB free storage');
    }
    final temporary = await getTemporaryDirectory();
    final parent = Directory('${temporary.path}/userinfo_native_compare');
    await parent.create(recursive: true);
    final directory = await parent.createTemp('run_');
    final csv = File('${directory.path}/fixture.csv');
    final trials = <Map<String, Object?>>[];
    try {
      await _generateCsv(csv, rows);
      for (final engine in ['native', 'flutter', 'flutter', 'native']) {
        final path = '${directory.path}/${engine}_${trials.length}.sqlite';
        final result = engine == 'native'
            ? await _native(csv, path, rows, batch)
            : await _flutter(csv, path, rows, batch);
        trials.add(result);
        // ignore: avoid_print
        print('USERINFO_NATIVE_COMPARE_TRIAL ${jsonEncode(result)}');
      }
      final native = trials
          .where((e) => e['engine'] == 'kotlin_android_sqlite')
          .map((e) => (e['rows_per_second'] as num).toDouble()).toList();
      final flutter = trials
          .where((e) => e['engine'] == 'flutter_sqflite')
          .map((e) => (e['rows_per_second'] as num).toDouble()).toList();
      final nativeMean = (native[0] + native[1]) / 2;
      final flutterMean = (flutter[0] + flutter[1]) / 2;
      final report = <String, Object>{
        'environment': 'Android local synthetic CSV only',
        'rows_per_trial': rows,
        'configured_batch': batch,
        'native_rows_sec': nativeMean,
        'flutter_rows_sec': flutterMean,
        'native_vs_flutter_ratio': nativeMean / flutterMean,
        'trials': trials,
        'warning': 'Benchmark native CSV parser only supports simple '
            'five-column unquoted synthetic CSV; not production RFC-4180.',
      };
      binding.reportData = report;
      // ignore: avoid_print
      print('USERINFO_NATIVE_COMPARE_RESULT ${jsonEncode(report)}');
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(hours: 2)));
}
