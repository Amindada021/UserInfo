import 'dart:convert';
import 'performance_metrics.dart';

/// One logical CSV record. A malformed record has [error] instead of fields.
/// Only line/record numbers and safe reason codes should be logged.
class CsvParsedRecord {
  const CsvParsedRecord({
    required this.recordNumber,
    required this.physicalLine,
    this.fields,
    this.error,
  });

  final int recordNumber;
  final int physicalLine;
  final List<String>? fields;
  final String? error;

  bool get isValid => error == null && fields != null;
}

/// Streaming RFC-4180-compatible CSV reader supporting quoted commas, escaped
/// quotes, multiline fields, BOM and malformed-row recovery.
///
/// A corrupt CSV can be ambiguous (for example a missing terminating quote).
/// For an oversized record we resynchronize at the next physical newline.
/// This intentionally drops the corrupt record, without manufacturing data.
class CsvStreamParser {
  const CsvStreamParser({this.maxRecordCharacters = 1024 * 1024});

  final int maxRecordCharacters;

  Stream<List<String>> parse(Stream<List<int>> bytes) async* {
    await for (final row in parseWithErrors(bytes)) {
      if (row.isValid) yield row.fields!;
    }
  }

  Stream<CsvParsedRecord> parseWithErrors(Stream<List<int>> bytes) async* {
    await for (final batch in parseBatches(bytes)) {
      for (final row in batch) { yield row; }
    }
  }

  /// Amortize async stream scheduling while bounding both rows and chunk bytes.
  Stream<List<CsvParsedRecord>> parseBatches(Stream<List<int>> bytes) async* {
    var pending = <CsvParsedRecord>[];
    final watch = PerformanceMetrics.enabled ? Stopwatch() : null;
    var cells = <String>[];
    var cell = StringBuffer();
    var inQuotes = false;
    var quotePending = false;
    var quoteClosed = false;
    var started = false;
    var discard = false;
    String? error;
    var recordChars = 0;
    var recordNumber = 0;
    var physicalLine = 1;
    var startLine = 1;
    var firstChar = true;
    var afterCr = false;

    CsvParsedRecord finishRow() {
      recordNumber++;
      if (error == null && !discard) cells.add(cell.toString());
      final result = CsvParsedRecord(
        recordNumber: recordNumber,
        physicalLine: startLine,
        fields: error == null && !discard ? cells : null,
        error: error ?? (discard ? 'RECORD_TOO_LARGE' : null),
      );
      cells = <String>[];
      cell = StringBuffer();
      inQuotes = false;
      quotePending = false;
      quoteClosed = false;
      started = false;
      discard = false;
      error = null;
      recordChars = 0;
      return result;
    }

    // Replacement decoding permits continuing past a malformed UTF-8 byte.
    // A row containing U+FFFD is rejected instead of silently changing an ID.
    await for (final chunk in bytes.transform(
        const Utf8Decoder(allowMalformed: true))) {
      watch?.start();
      // Iterate lazily over characters: chunk.split('') allocates hundreds
      // of thousands of temporary String objects for every 256 KB chunk.
      for (var i = 0; i < chunk.length; i++) {
        final char = chunk[i];
        if (firstChar) {
          firstChar = false;
          if (char == '\uFEFF') continue;
        }
        if (afterCr) {
          afterCr = false;
          if (char == '\n') continue;
        }

        if (discard) {
          if (char == '\n' || char == '\r') {
            if (char == '\r') afterCr = true;
            physicalLine++;
            pending.add(finishRow());
            if (pending.length >= 512) {
              watch?.stop();
              yield pending;
              pending = <CsvParsedRecord>[];
              watch?.start();
            }
            startLine = physicalLine;
          }
          continue;
        }

        recordChars++;
        if (recordChars > maxRecordCharacters) {
          error = 'RECORD_TOO_LARGE';
          discard = true;
          cells.clear();
          cell = StringBuffer();
          continue;
        }

        if (char == '\uFFFD') error ??= 'INVALID_UTF8';
        if (quotePending) {
          quotePending = false;
          if (char == '"') {
            cell.write('"');
            continue;
          }
          inQuotes = false;
          quoteClosed = true;
        }

        if (inQuotes) {
          if (char == '"') {
            quotePending = true;
          } else {
            cell.write(char);
            if (char == '\n') physicalLine++;
            if (char == '\r') {
              physicalLine++;
              afterCr = true;
            }
          }
          continue;
        }

        if (char == '"' && !started) {
          inQuotes = true;
          started = true;
          continue;
        }

        if (char == ',') {
          cells.add(cell.toString());
          cell = StringBuffer();
          started = false;
          quoteClosed = false;
          continue;
        }
        if (char == '\n' || char == '\r') {
          if (char == '\r') afterCr = true;
          physicalLine++;
          pending.add(finishRow());
            if (pending.length >= 512) {
              watch?.stop();
              yield pending;
              pending = <CsvParsedRecord>[];
              watch?.start();
            }
          startLine = physicalLine;
          continue;
        }

        if (quoteClosed && char != ' ' && char != '\t') {
          error ??= 'TEXT_AFTER_QUOTE';
        }
        if (char == '"' && started && !quoteClosed) {
          error ??= 'QUOTE_IN_UNQUOTED_FIELD';
        }
        cell.write(char);
        started = true;
      }
      watch?.stop();
      if (watch != null) {
        PerformanceMetrics.record('csv_parse_cpu', watch.elapsedMicroseconds);
        watch.reset();
      }
      if (pending.isNotEmpty) {
        yield pending;
        pending = <CsvParsedRecord>[];
      }
    }

    if (discard) {
      pending.add(finishRow());
            if (pending.length >= 512) {
              watch?.stop();
              yield pending;
              pending = <CsvParsedRecord>[];
              watch?.start();
            }
    } else if (inQuotes && !quotePending) {
      error = 'UNCLOSED_QUOTE_AT_EOF';
      pending.add(finishRow());
            if (pending.length >= 512) {
              watch?.stop();
              yield pending;
              pending = <CsvParsedRecord>[];
              watch?.start();
            }
    } else if (cells.isNotEmpty || started || cell.isNotEmpty ||
        quotePending || error != null) {
      pending.add(finishRow());
            if (pending.length >= 512) {
              watch?.stop();
              yield pending;
              pending = <CsvParsedRecord>[];
              watch?.start();
            }
    }
    if (pending.isNotEmpty) yield pending;
  }
}
