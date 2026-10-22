import 'dart:io';
import 'package:excel/excel.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

class ExportService {
  ExportService();

  static const labels = <String, String>{
    'bank': 'بانک',
    'full_name': 'نام کامل',
    'national_code': 'کد ملی',
    'card_no': 'شماره کارت',
    'mobile': 'موبایل',
    'birth_date': 'تاریخ تولد',
    'account_number': 'شماره حساب',
    'father_name': 'نام پدر',
    'id_number': 'شماره شناسنامه',
    'city_name': 'شهر',
    'province_name': 'استان',
    'birth_city': 'شهر تولد',
    'birth_province': 'استان تولد',
    'address': 'نشانی',
  };

  static const safeColumns = ['full_name', 'bank'];
  static final fullColumns = labels.keys.toList();

  static List<List<String>> table(List<Map<String, Object?>> records,
      {required bool sensitive}) {
    final fields = sensitive ? fullColumns : safeColumns;
    return [
      [for (final key in fields) labels[key]!],
      for (final record in records)
        [for (final key in fields) (record[key] ?? '').toString()],
    ];
  }

  static List<int> generateExcel(List<Map<String, Object?>> records,
      {required bool sensitive}) {
    final workbook = Excel.createExcel();
    final sheet = workbook['اطلاعات اشخاص'];
    sheet.isRTL = true;
    sheet.setDefaultColumnWidth(24);
    workbook.setDefaultSheet('اطلاعات اشخاص');
    final rows = table(records, sensitive: sensitive);
    final style = CellStyle(
      bold: true,
      fontSize: 12,
      backgroundColorHex: ExcelColor.fromHexString('#DDEDE8').hex,
      horizontalAlign: HorizontalAlign.Right,
    );
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      for (var column = 0; column < rows[rowIndex].length; column++) {
        final cell = sheet.cell(CellIndex.indexByColumnRow(
          columnIndex: column, rowIndex: rowIndex));
        // All values are TEXT to preserve leading zeros in identifiers.
        cell.value = TextCellValue(rows[rowIndex][column]);
        if (rowIndex == 0) cell.cellStyle = style;
      }
    }
    sheet.setColumnWidth(0, 33);
    workbook.delete('Sheet1');
    final bytes = workbook.encode();
    if (bytes == null) throw StateError('ساخت فایل Excel ناموفق بود');
    return bytes;
  }

  Future<void> excel(List<Map<String, Object?>> records,
      {required bool sensitive}) async {
    _validate(records);
    final bytes = generateExcel(records, sensitive: sensitive);
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/UserInfo-${DateTime.now().millisecondsSinceEpoch}.xlsx');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path,
          mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
    ));
  }

  Future<List<int>> generatePdf(List<Map<String, Object?>> records,
      {required bool sensitive}) async {
    _validate(records);
    // Bundled OFL-licensed Persian font: works offline on all supported phones.
    final data = await rootBundle.load('assets/fonts/Lateef-Regular.ttf');
    final font = pw.Font.ttf(data);
    final document = pw.Document();
    final keys = sensitive ? fullColumns : safeColumns;
    document.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 200,
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: font, bold: font),
      margin: const pw.EdgeInsets.all(25),
      build: (context) => [
        pw.Text('UserInfo - گزارش اشخاص',
            style: pw.TextStyle(font: font, fontSize: 20)),
        pw.SizedBox(height: 16),
        for (var index = 0; index < records.length; index++)
          pw.Container(
            width: double.infinity,
            margin: const pw.EdgeInsets.only(bottom: 8),
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
            ),
            child: pw.Text(
              '${index + 1}. ' +
                  keys.where((key) =>
                    (records[index][key] ?? '').toString().isNotEmpty)
                    .map((key) => '${labels[key]}: ${records[index][key]}')
                    .join('\n'),
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(font: font, fontSize: 11),
            ),
          ),
      ],
    ));
    return document.save();
  }

  Future<void> pdf(List<Map<String, Object?>> records,
      {required bool sensitive}) async {
    final bytes = await generatePdf(records, sensitive: sensitive);
    await Printing.sharePdf(
      bytes: bytes, filename: 'UserInfo-${DateTime.now().millisecondsSinceEpoch}.pdf');
  }

  static void _validate(List<Map<String, Object?>> records) {
    if (records.isEmpty || records.length > 100) {
      throw StateError('خروجی آزمایشی محدود به ۱ تا ۱۰۰ رکورد است');
    }
  }
}
