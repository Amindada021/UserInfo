import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

class ExportService {
  ExportService();

  // The full, source-independent record schema. Missing bank-specific values
  // stay empty rather than being invented.
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

  static final fullColumns = labels.keys.toList(growable: false);
  static const safeColumns = <String>['full_name', 'bank'];

  // Complete exports are now the default, including for old callers still
  // passing sensitive=false. User approval occurs before sharing in the UI.
  static List<List<String>> table(List<Map<String, Object?>> records,
      {bool sensitive = true}) {
    return [
      [for (final key in fullColumns) labels[key]!],
      for (final record in records)
        [for (final key in fullColumns) (record[key] ?? '').toString()],
    ];
  }

  static List<int> generateExcel(List<Map<String, Object?>> records,
      {bool sensitive = true}) {
    _validate(records);
    final workbook = Excel.createExcel();
    final sheet = workbook['اطلاعات اشخاص'];
    sheet.isRTL = true;
    workbook.setDefaultSheet('اطلاعات اشخاص');
    sheet.setDefaultColumnWidth(23);

    final rows = table(records);
    final headerStyle = CellStyle(
      bold: true,
      fontSize: 12,
      backgroundColorHex: ExcelColor.fromHexString('#DDEDE8'),
      horizontalAlign: HorizontalAlign.Right,
    );
    final valueStyle = CellStyle(
      horizontalAlign: HorizontalAlign.Right,
    );

    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
        );
        // Every value is Excel TEXT, preserving leading zeroes and long IDs.
        cell.value = TextCellValue(rows[r][c]);
        cell.cellStyle = r == 0 ? headerStyle : valueStyle;
      }
    }

    // Wider name and address columns, normal widths for the other fields.
    for (var c = 0; c < fullColumns.length; c++) {
      final key = fullColumns[c];
      sheet.setColumnWidth(c, switch (key) {
        'full_name' => 34,
        'address' => 55,
        'bank' => 14,
        'card_no' || 'account_number' => 25,
        _ => 22,
      });
    }
    workbook.delete('Sheet1');
    final bytes = workbook.encode();
    if (bytes == null) {
      throw StateError('ساخت فایل Excel ناموفق بود');
    }
    return _enforceRightToLeft(bytes);
  }

  // Excel's isRTL setter is not reliably serialized by the excel package.
  // Ensure the actual XLSX worksheet XML contains rightToLeft="1".
  // A valid XLSX is a ZIP archive: this preserves every other workbook entry.
  static List<int> _enforceRightToLeft(List<int> xlsx) {
    final input = ZipDecoder().decodeBytes(xlsx);
    final output = Archive();
    var corrected = 0;
    for (final entry in input) {
      if (!entry.isFile) {
        output.add(ArchiveFile.directory(entry.name));
        continue;
      }
      final data = entry.readBytes();
      if (data == null) {
        throw StateError('فایل Excel ناقص است: ${entry.name}');
      }
      if (RegExp(r'^xl/worksheets/sheet[0-9]+\.xml$')
          .hasMatch(entry.name)) {
        var xml = utf8.decode(data);
        final sheetView = RegExp(r'<sheetView\b([^>]*?)(/?)>');
        if (sheetView.hasMatch(xml)) {
          xml = xml.replaceFirstMapped(sheetView, (match) {
            var attributes = (match.group(1) ?? '').replaceAll(
                RegExp(r'\srightToLeft="[^"]*"'), '');
            return '<sheetView${attributes} rightToLeft="1"${match.group(2)}>';
          });
        } else if (xml.contains('<sheetViews/>')) {
          xml = xml.replaceFirst('<sheetViews/>',
              '<sheetViews><sheetView workbookViewId="0" rightToLeft="1"/></sheetViews>');
        } else if (xml.contains('<sheetViews>')) {
          xml = xml.replaceFirst('<sheetViews>',
              '<sheetViews><sheetView workbookViewId="0" rightToLeft="1"/>');
        } else {
          xml = xml.replaceFirst('<sheetData',
              '<sheetViews><sheetView workbookViewId="0" rightToLeft="1"/></sheetViews><sheetData');
        }
        corrected++;
        output.add(ArchiveFile.bytes(entry.name, utf8.encode(xml)));
      } else {
        output.add(ArchiveFile.bytes(entry.name, data));
      }
    }
    if (corrected == 0) {
      throw StateError('هیچ شیت Excel برای راست‌به‌چپ شدن پیدا نشد');
    }
    return ZipEncoder().encodeBytes(output);
  }

  Future<void> excel(List<Map<String, Object?>> records,
      {bool sensitive = true}) async {
    _validate(records);
    final bytes = generateExcel(records);
    final directory = await getTemporaryDirectory();
    final file = File(
        '${directory.path}/UserInfo-${DateTime.now().millisecondsSinceEpoch}.xlsx');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [
        XFile(file.path,
            mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
      ],
    ));
  }

  // A landscape A3 PDF with two related tables, each containing the same row
  // number and full name. Splitting 14 columns is intentional: a single table
  // would require unreadably small Persian glyphs, particularly for addresses.
  static const _firstColumns = <String>[
    'full_name', 'bank', 'national_code', 'card_no', 'mobile',
    'account_number', 'birth_date',
  ];
  static const _secondColumns = <String>[
    'full_name', 'father_name', 'id_number', 'city_name', 'province_name',
    'birth_city', 'birth_province', 'address',
  ];

  Future<List<int>> generatePdf(List<Map<String, Object?>> records,
      {bool sensitive = true}) async {
    _validate(records);
    final fontData = await rootBundle.load('assets/fonts/Lateef-Regular.ttf');
    final font = pw.Font.ttf(fontData);
    final document = pw.Document();
    final titleStyle = pw.TextStyle(font: font, fontSize: 18);
    final tableFont = pw.TextStyle(font: font, fontSize: 11);

    pw.Widget buildTable(List<String> columns,
        List<Map<String, Object?>> slice, int startIndex) {
      return pw.TableHelper.fromTextArray(
        headers: <String>[
          'ردیف',
          for (final key in columns) labels[key]!,
        ],
        data: <List<String>>[
          for (var index = 0; index < slice.length; index++)
            <String>[
              '${startIndex + index + 1}',
              for (final key in columns)
                (slice[index][key] ?? '').toString(),
            ],
        ],
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
        border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
        cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 5, vertical: 6),
        headerStyle: pw.TextStyle(
          font: font, fontSize: 11, fontWeight: pw.FontWeight.bold),
        cellStyle: tableFont,
        headerAlignment: pw.Alignment.centerRight,
        cellAlignment: pw.Alignment.centerRight,
        columnWidths: {
          0: const pw.FixedColumnWidth(32),
          for (var i = 0; i < columns.length; i++)
            i + 1: pw.FlexColumnWidth(
                columns[i] == 'address' ? 3.5
                : columns[i] == 'full_name' ? 2.3
                : columns[i] == 'card_no' || columns[i] == 'account_number'
                    ? 2.0 : 1.4),
        },
      );
    }

    document.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a3.landscape,
      maxPages: 200,
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: font, bold: font),
      margin: const pw.EdgeInsets.all(30),
      build: (context) => [
        pw.Text('UserInfo - گزارش کامل اطلاعات اشخاص', style: titleStyle),
        pw.SizedBox(height: 8),
        pw.Text('جدول اول: اطلاعات هویتی و بانکی',
            style: tableFont),
        pw.SizedBox(height: 8),
        buildTable(_firstColumns, records, 0),
        pw.SizedBox(height: 16),
        pw.Text('جدول دوم: اطلاعات تکمیلی (ردیف‌ها متناظر هستند)',
            style: tableFont),
        pw.SizedBox(height: 8),
        buildTable(_secondColumns, records, 0),
      ],
    ));
    return document.save();
  }

  Future<void> pdf(List<Map<String, Object?>> records,
      {bool sensitive = true}) async {
    final bytes = await generatePdf(records);
    await Printing.sharePdf(
      bytes: Uint8List.fromList(bytes),
      filename: 'UserInfo-${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
  }

  static void _validate(List<Map<String, Object?>> records) {
    if (records.isEmpty || records.length > 100) {
      throw StateError('خروجی آزمایشی محدود به ۱ تا ۱۰۰ رکورد است');
    }
  }
}
