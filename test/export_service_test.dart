import 'dart:convert';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:userinfo/data/export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sample = <Map<String, Object?>>[
    {'full_name': 'Test Person', 'bank': 'Test'}
  ];

  test('export produces a real XLSX worksheet', () {
    final bytes = ExportService.generateExcel(sample, sensitive: false);
    expect(bytes.take(2).toList(), [0x50, 0x4b]);
    final spreadsheet = Excel.decodeBytes(bytes);
    expect(spreadsheet.tables.keys, contains('اطلاعات اشخاص'));
  });

  test('PDF export generates valid bytes with bundled font', () async {
    final bytes = await ExportService().generatePdf(sample, sensitive: false);
    expect(ascii.decode(bytes.take(4).toList()), '%PDF');
  });
}
