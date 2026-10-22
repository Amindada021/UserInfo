import 'dart:typed_data';
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

  Future<void> close() async => _channel.invokeMethod<void>('close');

  Future<Uint8List?> pdfFont() async =>
      _channel.invokeMethod<Uint8List>('pdfFont');
}
