import 'dart:convert';

/// RFC-4180-style streaming parser: quoted commas, escaped quotes and multiline
/// cells are supported, including when a UTF-8 sequence crosses a chunk boundary.
/// Does not load the entire CSV in memory.
class CsvStreamParser {
  const CsvStreamParser();

  Stream<List<String>> parse(Stream<List<int>> bytes) async* {
    var cells = <String>[];
    var cell = StringBuffer();
    var inQuotes = false;
    var pendingQuote = false;
    var fieldStarted = false;
    var skipLf = false;
    var firstCharacter = true;

    await for (final chunk in bytes.transform(utf8.decoder)) {
      for (final originalChar in chunk.split('')) {
        var char = originalChar;
        if (firstCharacter) {
          firstCharacter = false;
          if (char == '\uFEFF') continue;
        }
        if (skipLf) {
          skipLf = false;
          if (char == '\n') continue;
        }
        if (pendingQuote) {
          pendingQuote = false;
          if (char == '"') {
            cell.write('"');
            continue;
          }
          inQuotes = false;
        }
        if (inQuotes) {
          if (char == '"') {
            pendingQuote = true;
          } else {
            cell.write(char);
          }
          continue;
        }
        if (char == '"' && !fieldStarted) {
          inQuotes = true;
          fieldStarted = true;
          continue;
        }
        if (char == ',') {
          cells.add(cell.toString());
          cell = StringBuffer();
          fieldStarted = false;
          continue;
        }
        if (char == '\r' || char == '\n') {
          cells.add(cell.toString());
          yield cells;
          cells = <String>[];
          cell = StringBuffer();
          fieldStarted = false;
          if (char == '\r') skipLf = true;
          continue;
        }
        cell.write(char);
        fieldStarted = true;
      }
    }
    if (inQuotes && !pendingQuote) {
      throw const FormatException('CSV has an unclosed quoted field');
    }
    if (cells.isNotEmpty || fieldStarted || cell.isNotEmpty || pendingQuote) {
      cells.add(cell.toString());
      yield cells;
    }
  }
}
