import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:userinfo/core/csv_stream_parser.dart';

void main() {
  test('reads quoted commas, escaped quotes and multiline cells', () async {
    final input = 'A,B\r\n"one,two","a""b"\r\n"x","فارسی"\n';
    final bytes = utf8.encode(input);
    final stream = Stream<List<int>>.fromIterable([
      bytes.sublist(0, 9), bytes.sublist(9, 18), bytes.sublist(18),
    ]);
    final rows = await const CsvStreamParser().parse(stream).toList();
    expect(rows, [
      ['A', 'B'],
      ['one,two', 'a"b'],
      ['x', 'فارسی'],
    ]);
  });

  test('keeps empty columns at end of record', () async {
    final rows = await const CsvStreamParser()
        .parse(Stream.value(utf8.encode('one,two,\n'))).toList();
    expect(rows.single, ['one', 'two', '']);
  });

  test('bad UTF-8 skips only affected record, resumes on next line', () async {
    final head = utf8.encode('A,B\nfirst,1\n');
    final bad = <int>[0x62, 0x61, 0xff, 0x64, 0x2c, 0x32, 0x0a];
    final tail = utf8.encode('last,3\n');
    final result = await const CsvStreamParser().parseWithErrors(
      Stream<List<int>>.fromIterable([head, bad, tail]),
    ).toList();
    expect(result.length, 4);
    expect(result[1].fields, ['first', '1']);
    expect(result[2].error, 'INVALID_UTF8');
    expect(result[2].physicalLine, 3);
    expect(result[3].fields, ['last', '3']);
  });

  test('unbalanced and stray quotes become row errors, not whole-file throws',
      () async {
    final input = 'A,B\nbad"quote,2\nlast,3\n"unclosed,4';
    final rows = await const CsvStreamParser()
        .parseWithErrors(Stream.value(utf8.encode(input)))
        .toList();
    expect(rows[1].error, 'QUOTE_IN_UNQUOTED_FIELD');
    expect(rows[2].fields, ['last', '3']);
    expect(rows[3].error, 'UNCLOSED_QUOTE_AT_EOF');
  });

  test('oversized unclosed record is bounded and next physical line resumes',
      () async {
    final input = 'A,B\n"bad-${List.filled(150, 'x').join()}\ngood,4\n';
    final rows = await const CsvStreamParser(maxRecordCharacters: 70)
        .parseWithErrors(Stream.value(utf8.encode(input)))
        .toList();
    expect(rows.length, 3);
    expect(rows[1].error, 'RECORD_TOO_LARGE');
    expect(rows[2].fields, ['good', '4']);
  });

  test('malformed rows do not require building the full CSV in memory',
      () async {
    final input = 'A,B\nfirst,1\nbad"text,2\nlast,3\n';
    final rows = await const CsvStreamParser().parse(
        Stream.value(utf8.encode(input))).toList();
    expect(rows, [
      ['A', 'B'],
      ['first', '1'],
      ['last', '3'],
    ]);
  });
}
