import 'package:flutter/services.dart';
import '../core/performance_metrics.dart';

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

  Future<Uint8List?> read() async {
    if (!PerformanceMetrics.enabled) return _channel.invokeMethod<Uint8List>('read');
    return PerformanceMetrics.measure('saf_channel_read', () async {
      final result = await _channel.invokeMapMethod<String, dynamic>('readMeasured');
      if (result == null) return null;
      PerformanceMetrics.record('saf_native_read', (result['read_us'] as num).toInt());
      return result['bytes'] as Uint8List?;
    });
  }

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

  /// Android Storage Access Framework streams data directly between SQLite
  /// and the user-selected destination, without materializing it in Dart RAM.
  Future<int> exportDatabase(String sqlitePath) async =>
      (await _channel.invokeMethod<int>(
          'exportDatabase', {'path': sqlitePath})) ?? 0;

  /// Native progress events are posted from the Android copy thread at most
  /// about four times a second; unknown document sizes remain null.
  Stream<Map<dynamic, dynamic>> get restoreCopyProgress =>
      const EventChannel('userinfo/database_restore_progress')
          .receiveBroadcastStream()
          .map((event) => Map<dynamic, dynamic>.from(event as Map));

  Future<int> importDatabase(String stagingPath) async =>
      (await _channel.invokeMethod<int>(
          'importDatabase', {'path': stagingPath})) ?? 0;

  Future<int> freeBytes() async =>
      await _channel.invokeMethod<int>('freeBytes') ?? 0;

  Future<void> close() async => _channel.invokeMethod<void>('close');

  Future<Uint8List?> pdfFont() async =>
      _channel.invokeMethod<Uint8List>('pdfFont');
}
