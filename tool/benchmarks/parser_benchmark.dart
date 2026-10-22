import 'dart:convert';
import 'dart:io';
import 'package:userinfo/core/csv_stream_parser.dart';
import 'legacy_csv_parser.dart';

Stream<List<int>> synthetic(int rows) async* {
  final block = utf8.encode(List.filled(1000,
      '0000000000,0000000000000000,"نمونه ساختگی",,09000000000\n').join());
  for (var i = 0; i < rows; i += 1000) { yield block; }
}
Future<void> main(List<String> args) async {
  final rows = args.isEmpty ? 1000000 : int.parse(args.first);
  final results = <String, Object>{'rows': rows, 'runtime': Platform.version};
  for (final mode in ['legacy_per_row', 'batched']) {
    final samples = <int>[];
    for (var repeat = 0; repeat < 5; repeat++) {
      var count = 0;
      final watch = Stopwatch()..start();
      if (mode == 'legacy_per_row') {
        await for (final row in const LegacyCsvStreamParser().parseWithErrors(synthetic(rows))) {
          if (row.isValid) count++;
        }
      } else {
        await for (final batch in const CsvStreamParser().parseBatches(synthetic(rows))) {
          for (final row in batch) { if (row.isValid) count++; }
        }
      }
      samples.add(watch.elapsedMicroseconds);
      if (count != rows) throw StateError('Incorrect row count');
    }
    samples.sort();
    results[mode] = {'p50_us': samples[2], 'p95_us': samples.last,
      'rows_sec': rows * 1000000 / samples[2], 'peak_rss_bytes': ProcessInfo.maxRss};
  }
  stdout.writeln(jsonEncode(results));
}
