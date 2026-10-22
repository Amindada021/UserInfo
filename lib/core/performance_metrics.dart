import 'dart:io';

/// Opt-in, bounded aggregate measurements. Never accepts record values,
/// query text, filenames or SQL arguments as labels.
class PerformanceMetrics {
  static const enabled = bool.fromEnvironment('USERINFO_BENCHMARK');
  static final Map<String, _Samples> _stages = {};
  static int rows = 0;
  static int bytes = 0;

  static void record(String stage, int microseconds) {
    if (!enabled) return;
    (_stages[stage] ??= _Samples()).add(microseconds);
  }

  static Future<T> measure<T>(String stage, Future<T> Function() task) async {
    if (!enabled) return task();
    final watch = Stopwatch()..start();
    try {
      return await task();
    } finally {
      record(stage, watch.elapsedMicroseconds);
    }
  }

  static Map<String, Object> snapshot() => {
    'rows': rows,
    'bytes': bytes,
    'rss_bytes': ProcessInfo.currentRss,
    'max_rss_bytes': ProcessInfo.maxRss,
    if ((_stages['import_total']?.total ?? 0) > 0)
      'import_rows_sec': rows * 1000000 / _stages['import_total']!.total,
    if ((_stages['import_total']?.total ?? 0) > 0)
      'source_read_MB_sec': bytes / _stages['import_total']!.total,
    'stages': _stages.map((key, value) => MapEntry(key, value.snapshot())),
  };

  static void reset() {
    _stages.clear();
    rows = 0;
    bytes = 0;
  }
}

class _Samples {
  int count = 0;
  int total = 0;
  final List<int> recent = [];
  void add(int value) {
    total += value;
    if (recent.length < 512) {
      recent.add(value);
    } else {
      recent[count % 512] = value;
    }
    count++;
  }

  Map<String, Object> snapshot() {
    final sorted = [...recent]..sort();
    return {
      'count': count,
      'total_us': total,
      'mean_us': total / count,
      'recent_p50_us': sorted[(sorted.length * .50).ceil() - 1],
      'recent_p95_us': sorted[(sorted.length * .95).ceil() - 1],
      'percentile_window': sorted.length,
    };
  }
}
