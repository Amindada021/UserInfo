import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

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
  int failedFiles = 0;
  String? lastError;
  String? logLocation;

  DateTime _lastNativeProgress = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLogWrite = DateTime.fromMillisecondsSinceEpoch(0);
  StringBuffer _pendingLog = StringBuffer();

  double? get fraction =>
      totalBytes > 0 ? (readBytes / totalBytes).clamp(0, 1) : null;

  /// Each corrupt record is logged with filename and position, not its raw
  /// PII fields. Writes are batched to avoid thousands of platform calls.
  Future<void> _log(String message, {bool force = false}) async {
    _pendingLog.writeln(message.replaceAll('\n', ' '));
    final now = DateTime.now();
    if (force || _pendingLog.length >= 4096 ||
        now.difference(_lastLogWrite) > const Duration(seconds: 5)) {
      await _flushLog();
    }
  }

  Future<void> _flushLog() async {
    if (_pendingLog.isEmpty) return;
    final text = _pendingLog.toString();
    // Keep pending data until Android confirms it was flushed.
    await source.appendImportLog(text);
    _pendingLog = StringBuffer();
    _lastLogWrite = DateTime.now();
  }

  Future<void> _notifyAndroidProgress() async {
    final now = DateTime.now();
    if (now.difference(_lastNativeProgress) < const Duration(seconds: 3)) {
      return;
    }
    _lastNativeProgress = now;
    try {
      await source.reportImportProgress(
        fileIndex: fileIndex,
        fileCount: fileCount,
        percent: fraction == null ? -1 : (fraction! * 100).round(),
      );
    } catch (_) {
      // A notification problem must never roll back SQLite data.
    }
  }

  void cancel() {
    if (!busy) return;
    cancelling = true;
    stage = 'در حال توقف ایمن؛ رکوردهای ثبت‌شده حفظ می‌شوند';
    notifyListeners();
  }

  Future<void> importDocuments(List<CsvDocument> documents) async {
    if (busy) throw StateError('An import is already active');
    busy = true;
    cancelling = false;
    fileCount = documents.length;
    fileIndex = 0;
    currentName = '';
    totalBytes = documents.every((d) => d.size != null && d.size! > 0)
        ? documents.fold<int>(0, (sum, d) => sum + d.size!)
        : 0;
    readBytes = 0;
    inserted = 0;
    invalidRows = 0;
    failedFiles = 0;
    lastError = null;
    logLocation = null;
    _pendingLog = StringBuffer();
    notifyListeners();

    var logOpen = false;
    var protectionStarted = false;
    try {
      // Create an actual Android Downloads TXT before processing data.
      // If this fails, we do not silently skip rows without a trace.
      logLocation = await source.openImportLog();
      logOpen = true;
      await _log('BEGIN files=${documents.length}', force: true);
      try {
        await source.protectImport(true);
        protectionStarted = true;
      } catch (error) {
        await _log('WARN foreground-service ${_safeReason(error)}',
            force: true);
      }

      for (var i = 0; i < documents.length; i++) {
        if (cancelling) throw ImportCancelled();
        fileIndex = i + 1;
        currentName = documents[i].name;
        stage = 'ایمپورت فایل ${i + 1} از ${documents.length}';
        notifyListeners();
        try {
          await _importOne(documents[i]);
        } on ImportCancelled {
          rethrow;
        } on DatabaseException catch (error) {
          failedFiles++;
          lastError = 'خطای ذخیره‌سازی؛ ادامه ایمپورت متوقف شد: ${_safeReason(error)}';
          await _log('FATAL file=${_safeName(currentName)} '
              'sqlite=${_safeReason(error)}', force: true);
          break;
        } catch (error) {
          failedFiles++;
          lastError = 'فایل ${_safeName(currentName)} ناقص ماند: '
              '${_safeReason(error)}';
          await _log('FILE_ERROR file=${_safeName(currentName)} '
              'reason=${_safeReason(error)}', force: true);
          // Continue with the other files; already committed rows are kept.
        }
      }

      stage = cancelling
          ? 'لغو شد؛ داده‌های ذخیره‌شده حفظ شدند'
          : failedFiles > 0
              ? 'پایان با ${failedFiles} فایل ناقص؛ داده‌ها حفظ شدند'
              : 'ایمپورت کامل شد؛ ${invalidRows} ردیف خراب رد شد';
      await _log('END inserted=$inserted skipped=$invalidRows '
          'failedFiles=$failedFiles', force: true);
    } on ImportCancelled {
      stage = 'ایمپورت لغو شد؛ رکوردهای ثبت‌شده حفظ شدند';
      if (logOpen) {
        await _log('CANCELLED inserted=$inserted', force: true);
      }
    } catch (error) {
      lastError = _safeReason(error);
      stage = 'ایمپورت متوقف شد؛ رکوردهای ثبت‌شده حفظ شدند';
    } finally {
      if (logOpen) {
        try {
          await _flushLog();
        } catch (error) {
          lastError = 'خطا در ذخیره گزارش: ${_safeReason(error)}';
        }
        try {
          await source.closeImportLog();
        } catch (error) {
          lastError = 'خطا در بستن گزارش: ${_safeReason(error)}';
        }
      }
      if (protectionStarted) {
        try {
          await source.protectImport(false);
        } catch (_) {
          // Android might have stopped the foreground service itself.
        }
      }
      busy = false;
      cancelling = false;
      notifyListeners();
    }
  }

  String _safeName(String name) => name
      .replaceAll(RegExp(r'[\r\n\t]'), ' ')
      .replaceAll(RegExp(r'[^a-zA-Z0-9 _.()-]'), '_');

  String _safeReason(Object error) {
    final raw = error.toString().replaceAll(RegExp(r'[\r\n\t]'), ' ');
    // Never print SQL bound arguments or any raw person fields into logs.
    final prefix = raw.split(RegExp(r'\[arguments:|\[parameters:')).first;
    return prefix.length > 240 ? prefix.substring(0, 240) : prefix;
  }

  Stream<List<int>> _bytes() async* {
    while (true) {
      if (cancelling) throw ImportCancelled();
      final Uint8List? chunk = await source.read();
      if (chunk == null) break;
      readBytes += chunk.length;
      if (readBytes % (1024 * 1024) < chunk.length) notifyListeners();
      await _notifyAndroidProgress();
      yield chunk;
    }
  }

  Future<void> _importOne(CsvDocument doc) async {
    if (!doc.name.toLowerCase().endsWith('.csv')) {
      throw FormatException('فایل انتخابی CSV نیست');
    }
    var fileId = 0;
    var rowNumber = 0;
    var rowsInFile = 0;
    var skippedInFile = 0;
    var opened = false;
    try {
      await source.open(doc);
      opened = true;
      stage = 'خواندن و ذخیره ${_safeName(doc.name)}';
      notifyListeners();
      var header = <String>[];
      final buffer = <Map<String, Object?>>[];
      var bank = '';
      await _log('FILE_BEGIN index=$fileIndex '
          'file=${_safeName(doc.name)}', force: true);

      await for (final record in const CsvStreamParser()
          .parseWithErrors(_bytes())) {
        if (cancelling) throw ImportCancelled();

        if (!record.isValid) {
          invalidRows++;
          skippedInFile++;
          await _log('SKIP file=${_safeName(doc.name)} '
              'csvRecord=${record.recordNumber} '
              'line=${record.physicalLine} '
              'reason=${record.error}');
          continue;
        }
        final cells = record.fields!;

        if (header.isEmpty) {
          header = cells.map((value) => value.trim().toUpperCase()).toList();
          const melli = [
            'NATIONAL_CODE', 'CARD_NO', 'FULL_NAME', 'BIRTH_DATE', 'MOBILE',
          ];
          const mellat = [
            'NATIONAL_CODE', 'ACCOUNT_NUMBER', 'FULL_NAME', 'FATHER_NAME',
            'ID_NUMBER', 'BIRTH_DATE', 'CITY_NAME', 'PROVINCE_NAME',
            'BIRTH_CITY', 'BIRTH_PROVINCE', 'ADDRESS', 'CARD_NO', 'MOBILE',
          ];
          if (listEquals(header, melli)) {
            bank = 'ملی';
          } else if (listEquals(header, mellat)) {
            bank = 'ملت';
          } else {
            throw const FormatException('هدر CSV شناسایی نشد');
          }
          fileId = await database.beginFile(bank: bank);
          continue;
        }

        rowNumber++;
        if (cells.length != header.length) {
          invalidRows++;
          skippedInFile++;
          await _log('SKIP file=${_safeName(doc.name)} '
              'dataRow=$rowNumber line=${record.physicalLine} '
              'reason=COLUMN_COUNT expected=${header.length} '
              'actual=${cells.length}');
          continue;
        }

        final values = <String, String?>{};
        for (var j = 0; j < header.length; j++) {
          values[header[j]] = TextNormalizer.cleaned(cells[j]);
        }
        buffer.add({
          'file_id': fileId,
          'bank': bank,
          'part': '',
          'row_number': rowNumber,
          for (final field in UserInfoDatabase.allowedFields)
            field: values[field.toUpperCase()],
          'normalized_name': TextNormalizer.normalize(values['FULL_NAME'] ?? ''),
          'normalized_father': TextNormalizer.normalize(values['FATHER_NAME'] ?? ''),
          'normalized_city': TextNormalizer.normalize(values['CITY_NAME'] ?? ''),
          'normalized_province': TextNormalizer.normalize(values['PROVINCE_NAME'] ?? ''),
        });

        if (buffer.length >= 250) {
          await database.insertBatch(fileId, buffer);
          inserted += buffer.length;
          rowsInFile += buffer.length;
          buffer.clear();
          notifyListeners();
        }
      }

      if (fileId == 0) {
        throw const FormatException('CSV معتبر بدون هدر یافت نشد');
      }
      if (buffer.isNotEmpty) {
        await database.insertBatch(fileId, buffer);
        inserted += buffer.length;
        rowsInFile += buffer.length;
        buffer.clear();
      }
      if (cancelling) throw ImportCancelled();
      await database.finishFile(fileId);
      await _log('FILE_DONE file=${_safeName(doc.name)} '
          'saved=$rowsInFile skipped=$skippedInFile', force: true);
      notifyListeners();
    } catch (error) {
      if (fileId != 0) {
        try {
          await database.markPartial(fileId);
        } catch (_) {
          // Keep the committed rows even if status update cannot be written.
        }
      }
      await _log('FILE_PARTIAL file=${_safeName(doc.name)} '
          'lineOrRow=$rowNumber saved=$rowsInFile '
          'reason=${_safeReason(error)}', force: true);
      rethrow;
    } finally {
      if (opened) {
        await source.close();
      }
    }
  }
}
