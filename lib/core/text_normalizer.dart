import 'performance_metrics.dart';

class TextNormalizer {
  static final RegExp _diacritics = RegExp(r'[\u064B-\u065F\u0670\u06D6-\u06ED]');
  static final RegExp _spaces = RegExp(r'\s+');

  static String normalize(String value) {
    final watch = PerformanceMetrics.enabled ? (Stopwatch()..start()) : null;
    var normalized = value
        .replaceAll('ي', 'ی')
        .replaceAll('ى', 'ی')
        .replaceAll('ك', 'ک')
        .replaceAll('ة', 'ه')
        .replaceAll('ـ', '')
        .replaceAll(_diacritics, '')
        .replaceAll('\u200c', ' ')
        .replaceAll('\u00a0', ' ');
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    for (var i = 0; i < 10; i++) {
      normalized = normalized
          .replaceAll(persian[i], '$i')
          .replaceAll(arabic[i], '$i');
    }
    final result = normalized.replaceAll(_spaces, ' ').trim().toLowerCase();
    if (watch != null) PerformanceMetrics.record('normalization_cpu', watch.elapsedMicroseconds);
    return result;
  }

  static String? cleaned(String? value) {
    if (value == null) return null;
    final result = value.trim();
    if (result.isEmpty || result.toLowerCase() == 'none' ||
        result.toLowerCase() == 'null') {
      return null;
    }
    return result;
  }
}
