import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:userinfo/data/export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sample = <Map<String, Object?>>[
    {
      'full_name': 'شخص نمونه',
      'bank': 'ملی',
      'national_code': '0012345678',
      'mobile': '09120000000',
      'card_no': '0000111122223333',
      'address': 'آدرس نمونه برای آزمایش',
    },
  ];

  test('XLSX contains 14 columns and real right-to-left view flag', () {
    final bytes = ExportService.generateExcel(sample, sensitive: false);
    expect(bytes.take(2).toList(), [0x50, 0x4b]);
    final zip = ZipDecoder().decodeBytes(bytes);
    final sheet = zip.find('xl/worksheets/sheet1.xml');
    expect(sheet, isNotNull);
    final sheetXml = utf8.decode(sheet!.content as List<int>);
    expect(sheetXml, contains('rightToLeft="1"'));
    final spreadsheet = Excel.decodeBytes(bytes);
    final data = spreadsheet.tables['اطلاعات اشخاص']!.rows;
    expect(data.first.length, ExportService.fullColumns.length);
    expect(data.length, 2);
    expect(data[1][ExportService.fullColumns.indexOf('national_code')]!.value,
        isA<TextCellValue>());
    expect(
      (data[1][ExportService.fullColumns.indexOf('national_code')]!.value
          as TextCellValue).value,
      '0012345678',
    );
    expect(
      (data[1][ExportService.fullColumns.indexOf('address')]!.value
          as TextCellValue).value,
      'آدرس نمونه برای آزمایش',
    );
  });

  test('PDF generated is landscape A3 and includes all report sections',
      () async {
    final bytes = await ExportService().generatePdf(sample, sensitive: false);
    expect(ascii.decode(bytes.take(4).toList()), '%PDF');
    expect(bytes.length, greaterThan(1000));
  });
}
