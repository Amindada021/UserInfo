import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:userinfo/core/csv_stream_parser.dart';

void main() {
  test('reads multiline quoted fields and quoted commas across chunks', () async {
    final input = 'A,B\r\n"one,two","a""b"\r\n"x","فارسی"\n';
    final bytes = utf8.encode(input);
    final stream = Stream<List<int>>.fromIterable(
        [bytes.sublist(0, 9), bytes.sublist(9, 18), bytes.sublist(18)]);
    final rows = await const CsvStreamParser().parse(stream).toList();
    expect(rows, [
      ['A', 'B'],
      ['one,two', 'a"b'],
      ['x', 'فارسی'],
    ]);
  });
  test('preserves trailing empty column', () async {
    final rows = await const CsvStreamParser()
        .parse(Stream.value(utf8.encode('one,two,\n'))).toList();
    expect(rows.single, ['one', 'two', '']);
  });
}
