import 'package:flutter/services.dart';

class CsvDocument {
  const CsvDocument({required this.uri, required this.name, this.size});
  final String uri;
  final String name;
  final int? size;
  String get bank {
    final lower = name.toLowerCase();
    if (lower.contains('mellat')) return 'ملت';
    if (lower.contains('melli')) return 'ملی';
    return 'نامشخص';
  }
}

class CsvSource {
  static const MethodChannel _channel = MethodChannel('userinfo/csv_stream');

  Future<List<CsvDocument>> pick() async {
    final result = await _channel.invokeMethod<List<dynamic>>('pick');
    return (result ?? []).map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return CsvDocument(
        uri: map['uri'] as String,
        name: map['name'] as String,
        size: (map['size'] as num?)?.toInt(),
      );
    }).toList();
  }

  Future<void> open(CsvDocument document) async =>
      _channel.invokeMethod<void>('open', {'uri': document.uri});

  Future<Uint8List?> read() async =>
      _channel.invokeMethod<Uint8List>('read');


  /// Keep a foreground Android service active for long-running imports.
  /// This improves screen-off survival but is not a crash/reboot resume system.
  Future<void> protectImport(bool enabled) async =>
      _channel.invokeMethod<void>('protectImport', {'enabled': enabled});

  Future<void> reportImportProgress({
    required int fileIndex,
    required int fileCount,
    required int percent,
  }) async =>
      _channel.invokeMethod<void>('importProgress', {
        'fileIndex': fileIndex,
        'fileCount': fileCount,
        'percent': percent,
      });

  Future<String> openImportLog() async =>
      await _channel.invokeMethod<String>('openImportLog') ??
      'Downloads/UserInfo';

  Future<void> appendImportLog(String value) async =>
      _channel.invokeMethod<void>('appendImportLog', {'text': value});

  Future<void> closeImportLog() async =>
      _channel.invokeMethod<void>('closeImportLog');

  Future<void> close() async => _channel.invokeMethod<void>('close');

  Future<Uint8List?> pdfFont() async =>
      _channel.invokeMethod<Uint8List>('pdfFont');
}
