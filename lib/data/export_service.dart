import 'dart:io';
import 'dart:typed_data';
import 'package:cross_file/cross_file.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'csv_source.dart';

class ExportService {
  ExportService(this.source);
  final CsvSource source;

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
    'part': 'فایل منبع',
  };

  static const safeColumns = ['full_name', 'bank', 'part'];
  static final fullColumns = labels.keys.toList();

  List<List<String>> _table(List<Map<String, Object?>> records,
      {required bool sensitive}) {
    final fields = sensitive ? fullColumns : safeColumns;
    return [
      [for (final key in fields) labels[key]!],
      for (final record in records)
        [for (final key in fields) (record[key] ?? '').toString()],
    ];
  }

  Future<void> excel(List<Map<String, Object?>> records,
      {required bool sensitive}) async {
    if (records.isEmpty || records.length > 100) {
      throw StateError('خروجی آزمایشی محدود به ۱ تا ۱۰۰ رکورد است');
    }
    final book = Excel.createExcel();
    final sheet = book['UserInfo'];
    for (final row in _table(records, sensitive: sensitive)) {
      sheet.appendRow([for (final cell in row) TextCellValue(cell)]);
    }
    final bytes = book.encode();
    if (bytes == null) throw StateError('امکان ایجاد XLSX وجود ندارد');
    final temp = await getTemporaryDirectory();
    final file = File('${temp.path}/userinfo_export.xlsx');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  Future<void> pdf(List<Map<String, Object?>> records,
      {required bool sensitive}) async {
    if (records.isEmpty || records.length > 100) {
      throw StateError('خروجی آزمایشی محدود به ۱ تا ۱۰۰ رکورد است');
    }
    final fontBytes = await source.pdfFont();
    if (fontBytes == null) {
      throw StateError('فونت فارسی مناسب برای PDF روی این دستگاه پیدا نشد');
    }
    final font = pw.Font.ttf(ByteData.sublistView(fontBytes));
    final document = pw.Document();
    // Wide PDFs with all 15 fields are unreadable on A4. XLSX includes all fields;
    // PDF includes the six most relevant columns when sensitive export is enabled.
    final rows = sensitive
        ? [
            ['نام کامل', 'بانک', 'کد ملی', 'شماره کارت', 'موبایل', 'تاریخ تولد'],
            for (final row in records) [
              for (final key in ['full_name','bank','national_code',
                  'card_no','mobile','birth_date']) (row[key] ?? '').toString(),
            ],
          ]
        : _table(records, sensitive: false);
    document.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: font, bold: font),
      build: (context) => [
        pw.Text('گزارش UserInfo', style: pw.TextStyle(font: font, fontSize: 18)),
        pw.SizedBox(height: 14),
        pw.TableHelper.fromTextArray(
          headers: rows.first,
          data: rows.skip(1).toList(),
          headerStyle: pw.TextStyle(font: font, fontSize: 9),
          cellStyle: pw.TextStyle(font: font, fontSize: 8),
          cellAlignment: pw.Alignment.centerRight,
        ),
      ],
    ));
    await Printing.sharePdf(
        bytes: await document.save(), filename: 'userinfo_export.pdf');
  }
}
