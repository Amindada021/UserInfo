import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/csv_stream_parser.dart';
import '../core/text_normalizer.dart';
import 'csv_source.dart';
import 'userinfo_database.dart';

class ImportCancelled implements Exception {}

class ImportController extends ChangeNotifier {
  ImportController(this.database, this.source);
  final UserInfoDatabase database;
  final CsvSource source;

  bool busy = false;
  bool cancelling = false;
  int fileIndex = 0;
  int fileCount = 0;
  String currentName = '';
  String stage = '';
  int readBytes = 0;
  int totalBytes = 0;
  int inserted = 0;
  int invalidRows = 0;
  String? lastError;

  double? get fraction =>
      totalBytes > 0 ? (readBytes / totalBytes).clamp(0, 1) : null;

  void cancel() {
    if (!busy) return;
    cancelling = true;
    stage = 'در حال توقف ایمن...';
    notifyListeners();
  }

  Future<void> importDocuments(List<CsvDocument> documents) async {
    if (busy) throw StateError('An import is already active');
    busy = true;
    cancelling = false;
    fileCount = documents.length;
    totalBytes = documents.every((item) => item.size != null && item.size! > 0)
        ? documents.fold<int>(0, (sum, item) => sum + item.size!)
        : 0;
    readBytes = 0;
    inserted = 0;
    invalidRows = 0;
    lastError = null;
    notifyListeners();
    try {
      for (var i = 0; i < documents.length; i++) {
        if (cancelling) throw ImportCancelled();
        fileIndex = i + 1;
        currentName = documents[i].name;
        await _importOne(documents[i]);
      }
      stage = 'ایمپورت کامل شد';
    } on ImportCancelled {
      stage = 'ایمپورت لغو شد؛ داده ناقص حذف شد';
    } catch (error) {
      stage = 'ایمپورت متوقف شد';
      lastError = error.toString();
    } finally {
      busy = false;
      cancelling = false;
      notifyListeners();
    }
  }

  Stream<List<int>> _bytes(CsvDocument doc) async* {
    while (true) {
      if (cancelling) throw ImportCancelled();
      final Uint8List? chunk = await source.read();
      if (chunk == null) break;
      readBytes += chunk.length;
      // Unknown-length sources show an indeterminate progress indicator.
      if (readBytes % (1024 * 1024) < chunk.length) notifyListeners();
      yield chunk;
    }
  }

  Future<void> _importOne(CsvDocument doc) async {
    if (!doc.name.toLowerCase().endsWith('.csv')) {
      throw FormatException('فایل CSV نیست: ${doc.name}');
    }
    var fileId = 0;
    var rowNumber = 0;
    try {
      await source.open(doc);
      stage = 'خواندن و ذخیره فایل';
      notifyListeners();
      var header = <String>[];
      final buffer = <Map<String, Object?>>[];
      var bank = '';
      await for (final cells in const CsvStreamParser().parse(_bytes(doc))) {
        if (cancelling) throw ImportCancelled();
        if (header.isEmpty) {
          header = cells.map((e) => e.trim().toUpperCase()).toList();
          final melli = const [
            'NATIONAL_CODE', 'CARD_NO', 'FULL_NAME', 'BIRTH_DATE', 'MOBILE'
          ];
          final mellat = const [
            'NATIONAL_CODE', 'ACCOUNT_NUMBER', 'FULL_NAME', 'FATHER_NAME',
            'ID_NUMBER', 'BIRTH_DATE', 'CITY_NAME', 'PROVINCE_NAME',
            'BIRTH_CITY', 'BIRTH_PROVINCE', 'ADDRESS', 'CARD_NO', 'MOBILE',
          ];
          if (listEquals(header, melli)) {
            bank = 'ملی';
          } else if (listEquals(header, mellat)) {
            bank = 'ملت';
          } else {
            throw FormatException('ساختار CSV ناشناخته است: ${doc.name}');
          }
          // Actual bank is derived from the validated header, not filename.
          fileId = await database.beginFile(bank: bank);
          continue;
        }
        rowNumber++;
        if (cells.length != header.length) {
          invalidRows++;
          continue;
        }
        final values = <String, String?>{};
        for (var j = 0; j < header.length; j++) {
          values[header[j]] = TextNormalizer.cleaned(cells[j]);
        }
        final fullName = values['FULL_NAME'] ?? '';
        buffer.add({
          'file_id': fileId,
          'bank': bank,
          'part': '',
          'row_number': rowNumber,
          for (final field in UserInfoDatabase.allowedFields)
            field: values[field.toUpperCase()],
          'normalized_name': TextNormalizer.normalize(fullName),
          'normalized_father': TextNormalizer.normalize(values['FATHER_NAME'] ?? ''),
          'normalized_city': TextNormalizer.normalize(values['CITY_NAME'] ?? ''),
          'normalized_province': TextNormalizer.normalize(values['PROVINCE_NAME'] ?? ''),
        });
        if (buffer.length == 250) {
          await database.insertBatch(fileId, buffer);
          inserted += buffer.length;
          buffer.clear();
          notifyListeners();
        }
      }
      if (fileId == 0) throw const FormatException('CSV is empty');
      if (buffer.isNotEmpty) {
        await database.insertBatch(fileId, buffer);
        inserted += buffer.length;
      }
      if (cancelling) throw ImportCancelled();
      stage = 'نهایی‌سازی و ثبت فایل';
      notifyListeners();
      await database.finishFile(fileId);
    } catch (_) {
      if (fileId != 0) {
        await database.abandonFile(fileId);
      }
      rethrow;
    } finally {
      await source.close();
    }
  }
}
